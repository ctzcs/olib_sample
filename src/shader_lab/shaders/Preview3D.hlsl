#include "Palette.hlsli"
#include "../../../library/shader_dev/Preview3D/params.generated.hlsli"
// Vertex b0: matrices. Fragment b0: engine inputs; b1/textures: generated parameters.
cbuffer MatrixBlock : register(b0, space1) { float4x4 Wvp; float4x4 World; };
cbuffer PreviewBlock : register(b0, space3) {
    float4 Clock;
    float4 Pointer;
    float4 Tint;
};
struct Input {
    float3 Position : TEXCOORD0;
    float3 Normal : TEXCOORD1;
    float2 Uv : TEXCOORD2;
    float4 Tangent : TEXCOORD3;
};
struct Output {
    float4 Position : SV_Position;
    float3 Normal : TEXCOORD0;
    float2 Uv : TEXCOORD1;
};
Output vertex_main(Input v)
{
    Output o;
    o.Position = mul(float4(v.Position, 1), Wvp);
    o.Normal = mul(v.Normal, (float3x3)World);
    o.Uv = v.Uv;
    return o;
}
float4 fragment_main(Output v) : SV_Target0
{
    float light = 0.18 + 0.82 * saturate(dot(normalize(v.Normal), normalize(float3(-0.5, 0.8, 0.6))));
    float ripple = sin(v.Uv.y * 28 + Clock.x * _speed) * _strength * 0.1;
    float3 color = palette(v.Uv.y + _hue + ripple) * _tint.rgb;
    float3 tex = _image.Sample(_imageSampler, v.Uv).rgb;
    return float4(color * light * lerp(float3(1, 1, 1), tex, 0.2) * _tint.a, _tint.a);
}
