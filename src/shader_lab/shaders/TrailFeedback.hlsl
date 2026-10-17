#include "../../../library/shader_dev/TrailFeedback/params.generated.hlsli"
cbuffer ViewBlock : register(b0, space1) { float4 View; };
cbuffer PreviewBlock : register(b0, space3) {
    float4 Clock; // time, delta time, frame index, sprite flag
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
    float3 current = _source.Sample(_sourceSampler, v.Uv).rgb;
    float2 historyUV = (v.Uv - 0.5) * 0.995 + 0.5;
    float3 history = _history.Sample(_historySampler, historyUV).rgb;
    return float4(lerp(current, history, _retention), 1);
}
