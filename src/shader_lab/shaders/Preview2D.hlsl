#include "Palette.hlsli"
#include "../../../library/shader_dev/Preview2D/params.generated.hlsli"
// Vertex b0: view. Fragment b0: engine inputs; b1/textures: generated parameters.
cbuffer ViewBlock : register(b0, space1) { float4 View; };
cbuffer PreviewBlock : register(b0, space3) {
    float4 Clock; // time, unused, unused, sprite mode
    float4 Pointer; // mouse UV, viewport pixels
    float4 Tint;
};
struct Input { float2 Position : TEXCOORD0; float2 Uv : TEXCOORD1; };
struct Output { float4 Position : SV_Position; float2 Uv : TEXCOORD0; };
Output vertex_main(Input v)
{
    Output o;
    o.Position = float4(v.Position * View.xy, 0, 1);
    o.Uv = v.Uv;
    return o;
}
float4 fragment_main(Output v) : SV_Target0
{
    float2 p = (v.Uv - 0.5) * float2(Pointer.z / max(Pointer.w, 1), 1);
    float wave = sin(length(p) * 26 - Clock.x * _speed);
    float3 color = palette(length(p) * 2 + _hue + wave * _strength * 0.15);
    float4 tex = _image.Sample(_imageSampler, v.Uv);
    color *= lerp(1.0, tex.rgb, Clock.w) * _tint.rgb;
    float alpha = lerp(1.0, tex.a, Clock.w) * _tint.a;
    return float4(color * alpha, alpha);
}
