#include "../../../library/shader_dev/TrailBlur/params.generated.hlsli"
cbuffer ViewBlock : register(b0, space1) { float4 View; };
cbuffer PreviewBlock : register(b0, space3) {
    float4 Clock;
    float4 Pointer;
    float4 Tint;
};
struct Input { float2 Position : TEXCOORD0; float2 Uv : TEXCOORD1; };
struct Output { float4 Position : SV_Position; float2 Uv : TEXCOORD0; };
Output vertex_main(Input v) {
    Output o;
    o.Position = float4(v.Position * View.xy, 0, 1);
    o.Uv = v.Uv;
    return o;
}
float4 fragment_main(Output v) : SV_Target0 {
    uint width, height;
    _source.GetDimensions(width, height);
    float2 offset = _direction * _radius / float2(max(width, 1), max(height, 1));
    return _source.Sample(_sourceSampler, v.Uv) * 0.4
         + _source.Sample(_sourceSampler, v.Uv + offset) * 0.24
         + _source.Sample(_sourceSampler, v.Uv - offset) * 0.24
         + _source.Sample(_sourceSampler, v.Uv + offset * 2) * 0.06
         + _source.Sample(_sourceSampler, v.Uv - offset * 2) * 0.06;
}
