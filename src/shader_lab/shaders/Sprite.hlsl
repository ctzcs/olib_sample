#include "Palette.hlsli"
#ifdef SPRITE_SHADOW
#include "../../../library/shader_dev/SpriteShade/params.generated.hlsli"
#else
#include "../../../library/shader_dev/Sprite/params.generated.hlsli"
#endif

// Sprite vertex: position in final target pixels + frame UV (including atlas region).
cbuffer ViewBlock : register(b0, space1) { float4x4 Projection; };
cbuffer FrameBlock : register(b0, space3) {
    float4 Clock;
    float4 Pointer;
    float4 Tint;
};
struct Input { float2 Position : TEXCOORD0; float2 Uv : TEXCOORD1; };
struct Output { float4 Position : SV_Position; float2 Uv : TEXCOORD0; };
Output vertex_main(Input v)
{
    Output o;
    o.Position = mul(Projection, float4(v.Position, 0, 1));
    o.Uv = v.Uv;
    // Shadow geometry shares the frame UV, so atlas neighbours cannot bleed in.
#ifdef SPRITE_SHADOW
    o.Position.xy += float2(Projection[0][0], Projection[1][1]) * 12;
#endif
    return o;
}
float4 fragment_main(Output v) : SV_Target0
{
    float4 tex = _image.Sample(_imageSampler, v.Uv);
    float opacity = _opacity * Tint.a;
    float3 rgb = tex.rgb * palette(_hue) * Tint.rgb;
#ifdef SPRITE_SHADOW
    return float4(float3(0.02, 0.03, 0.06) * tex.a * opacity * 0.65, tex.a * opacity * 0.65);
#else
    return float4(rgb * opacity, tex.a * opacity);
#endif
}
