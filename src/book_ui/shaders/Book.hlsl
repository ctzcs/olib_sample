cbuffer Matrices : register(b0, space1)
{
    float4x4 WorldViewProjection;
    float4x4 World;
};
Texture2D FrontPage : register(t0, space2);
SamplerState FrontSampler : register(s0, space2);
Texture2D BackPage : register(t1, space2);
SamplerState BackSampler : register(s1, space2);
struct VertexInput
{
    float3 Position : TEXCOORD0;
    float3 Normal : TEXCOORD1;
    float2 Uv : TEXCOORD2;
    float4 Color : TEXCOORD3;
};
struct PixelInput
{
    float4 Position : SV_Position;
    float3 Normal : TEXCOORD0;
    float2 Uv : TEXCOORD1;
    float4 Color : TEXCOORD2;
};
PixelInput vertex_main(VertexInput input)
{
    PixelInput output;
    // kit/world uses row vectors; its column-packed matrices are passed as-is.
    output.Position = mul(float4(input.Position, 1), WorldViewProjection);
    output.Normal = mul(input.Normal, (float3x3)World);
    output.Uv = input.Uv;
    output.Color = input.Color;
    return output;
}
float4 fragment_main(PixelInput input, bool front : SV_IsFrontFace) : SV_Target0
{
    float4 paper = front ? FrontPage.Sample(FrontSampler, input.Uv)
        : BackPage.Sample(BackSampler, float2(1 - input.Uv.x, input.Uv.y));
    float light = 0.78 + 0.22 * abs(dot(normalize(input.Normal), normalize(float3(-0.3, 0.4, 1))));
    return float4(paper.rgb * input.Color.rgb * light, paper.a * input.Color.a);
}
