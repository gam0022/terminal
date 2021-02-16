// The original retro pixel shader
Texture2D shaderTexture;
SamplerState samplerState;

cbuffer PixelShaderSettings {
  float  Time;
  float  Scale;
  float2 Resolution;
  float4 Background;
};

static const float2 _BallAlbedoHue = float2(0.1, -2.36);
static const float _BallRepeat = 4;
static const float3 _FloorAlbedoA = float3(0, 0, 0);
static const float3 _FloorAlbedoB = float3(0.8396226, 0.8396226, 0.8396226);
static const float3 _SkyTopColor = float3(0.41509432, 0.21342114, 0.38110238);
static const float3 _SkyBottomColor = float3(0, 0, 0);
static const float3 light = normalize(float3(1, 2, 1));// 平行光源の方向ベクトル

float mod(float x, float y)
{
    return x - y * floor(x / y);
}

float2 mod(float2 x, float2 y)
{
    return x - y * floor(x / y);
}

float3 hsvToRgb(float3 c)
{
    float4 K = float4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
    float3 p = abs(frac(c.xxx + K.xyz) * 6.0 - K.www);
    return c.z * lerp(K.xxx, saturate(p - K.xxx), c.y);
}

float sdSphere(float3 p, float r)
{
    return length(p) - r;
}

float sdPlane(float3 p, float3 n, float h)
{
    // nは正規化された法線
    // hは原点からの距離
    return dot(p, n) + h;
}

float2 opRep(float2 p, float2 interval)
{
    return mod(p, interval) - interval * 0.5;
}

float dBalls(float3 p)
{
    p.xz = opRep(p.xz, _BallRepeat);
    return sdSphere(p - float3(0, 1, 0), 1);
}

float dFloor(float3 p)
{
    return sdPlane(p, float3(0, 1, 0), 0);
}

float map(float3 p)
{
    float d = dBalls(p);
    d = min(d, dFloor(p));
    return d;
}

// 偏微分から法線を計算します
float3 calcNormal(float3 p)
{
    float eps = 0.001;
    
    return normalize(float3(
        map(p + float3(eps, 0.0, 0.0)) - map(p + float3(-eps, 0.0, 0.0)),
        map(p + float3(0.0, eps, 0.0)) - map(p + float3(0.0, -eps, 0.0)),
        map(p + float3(0.0, 0.0, eps)) - map(p + float3(0.0, 0.0, -eps))
    ));
}

float calcAO(float3 pos, float3 nor)
{
    float occ = 0.0;
    float sca = 1.0;
    for (int i = 0; i < 5; i++)
    {
        float h = 0.01 + 0.12 * float(i) / 4.0;
        float d = map(pos + h * nor).x;
        occ += (h - d) * sca;
        sca *= 0.95;
        if (occ > 0.35) break;
    }
    return clamp(1.0 - 3.0 * occ, 0.0, 1.0) * (0.5 + 0.5 * nor.y);
}

// http://iquilezles.org/www/articles/rmshadows/rmshadows.htm
float calcSoftshadow(float3 ro, float3 rd, float mint, float tmax)
{
    // bounding volume
    float tp = (0.8 - ro.y) / rd.y;
    if (tp > 0.0) tmax = min(tmax, tp);
    
    float res = 1.0;
    float t = mint;
    for (int i = 0; i < 24; i++)
    {
        float h = map(ro + rd * t).x;
        float s = clamp(8.0 * h / t, 0.0, 1.0);
        res = min(res, s * s * (3.0 - 2.0 * s));
        t += clamp(h, 0.02, 0.2);
        if (res < 0.004 || t > tmax) break;
    }
    return clamp(res, 0.0, 1.0);
}

float3 acesFilm(float3 x)
{
    const float a = 2.51;
    const float b = 0.03;
    const float c = 2.43;
    const float d = 0.59;
    const float e = 0.14;
    return saturate((x * (a * x + b)) / (x * (c * x + d) + e));
}

// フレネル項のSchlick近似
float fresnelSchlick(float f0, float cosTheta)
{
    return f0 + (1.0 - f0) * pow((1.0 - cosTheta), 5.0);
}

float3 raymarching(inout float3 origin, inout float3 ray, inout bool hit, inout float3 reflectionAttenuation)
{
    float3 col = float3(0.0, 0.0, 0.0);
    
    // レイマーチング
    hit = false;
    float t = 0.0;// レイの進んだ距離
    float3 p = origin;// レイの先端の座標
    int i = 0;// レイマーチングのループカウンター
    
    for (i = 0; i < 500; i++)
    {
        float d = map(p);// 最短距離を計算します
        
        // 最短距離を0に近似できるなら、オブジェクトに衝突したとみなして、ループを抜けます
        if (d < 0.0001)
        {
            hit = true;
            break;
        }
        
        t += d;// 最短距離だけレイを進めます
        p = origin + ray * t;// レイの先端の座標を更新します
    }
    
    if (hit)
    {
        // ライティングのパラメーター
        float3 normal = calcNormal(p);// 法線
        float3 ref = reflect(ray, normal);// レイの反射ベクトル
        float f0 = 1;// フレネル反射率F0
        
        // マテリアルのパラメーター
        float3 albedo = float3(1, 1, 1);// アルベド
        float metalness = 0.5;// メタルネス（金属の度合い）
        
        // ボールのマテリアルを設定
        if (dBalls(p) < 0.0001)
        {
            float2 grid = floor(p.xz / _BallRepeat);
            albedo = hsvToRgb(float3(dot(grid, _BallAlbedoHue), 1.0, 1.0));
            metalness = 0.8;
            f0 = 0.8;
        }
        
        // 床のマテリアルを設定
        if (dFloor(p) < 0.0001)
        {
            float checker = mod(floor(p.x) + floor(p.z), 2.0);
            albedo = lerp(_FloorAlbedoA, _FloorAlbedoB, checker);
            metalness = 0.1;
            f0 = 0.4;
        }
        
        // ライティング計算
        float diffuse = saturate(dot(normal, light));// 拡散反射
        float specular = pow(saturate(dot(reflect(light, normal), ray)), 10.0);// 鏡面反射
        float ao = calcAO(p, normal);// AO
        float shadow = calcSoftshadow(p, light, 0.25, 5);// シャドウ
        
        // ライティング結果の合成
        col += albedo * diffuse * shadow * (1 - metalness);// 直接光の拡散反射
        col += albedo * specular * shadow * metalness;// 直接光の鏡面反射
        col += albedo * ao * lerp(_SkyBottomColor, _SkyTopColor, 0.3);// 環境光

        // 遠景のフォグ
        float invFog = exp(-0.02 * t);
        col = lerp(_SkyBottomColor, col, invFog);
        
        // 反射の減衰率を更新。シェーダーでは再帰が使えないため、呼び出し側で結果を合成
        reflectionAttenuation *= albedo * fresnelSchlick(f0, dot(ref, normal)) * invFog;

        // レイを反射用に更新
        origin = p + 0.01 * normal;
        ray = ref;
    }
    else
    {
        // 空
        col = lerp(_SkyBottomColor, _SkyTopColor, ray.y);
    }

    return col;
}

float3 mainRaymarching(float2 pos)
{
    float3 col = float3(0.0, 0.0, 0.0);
    
    // UVを -1～1 の範囲に変換します
    float2 uv = (2 * pos - Resolution) / Resolution.y;
    uv.y = 1 - uv.y;
    
    // カメラの情報
    float3 cameraOrigin = float3(0, 5, -3 + Time);// カメラの位置
    float3 cameraTarget = cameraOrigin + float3(0, -2, 3);// カメラのターゲット
    float3 cameraUp = float3(0, 1, 0);// カメラのUPベクトル
    float cameraFov = 60;// カメラのFOV
    
    // UVに対応するレイを計算
    float3 forward = normalize(cameraTarget - cameraOrigin);
    float3 right = normalize(cross(forward, cameraUp));
    float3 up = normalize(cross(right, forward));
    
    float PI = 3.14159265359;
    float3 ray = normalize(
        right * uv.x +
        up * uv.y +
        forward / tan(cameraFov / 360 * PI)
    );

    bool hit = false;// オブジェクトに衝突したかどうか
    float3 reflectionAttenuation = float3(1, 1, 1);// 反射の減衰率

    // レイは最大3回まで反射します
    for (int i = 0; i < 3; i++)
    {
        col += reflectionAttenuation * raymarching(cameraOrigin, ray, hit, reflectionAttenuation);

        if (!hit) break;
    }
    
    // トーンマッピング
    col = acesFilm(col * 0.8);
    
    // ガンマ補正
    col = pow(col, 1 / 2.2);
    
    return col;
}

float4 main(float4 pos : SV_POSITION, float2 tex : TEXCOORD) : SV_TARGET
{
    Texture2D input = shaderTexture;

    // TODO:GH#3930 Make these configurable in some way.
    float4 color = input.Sample(samplerState, tex);
    color.rgb += mainRaymarching(pos.xy);

    return color;
}
