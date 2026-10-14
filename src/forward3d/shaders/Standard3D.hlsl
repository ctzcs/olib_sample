#include "Standard3DCommon.hlsli"
struct VsInput
{
    float3 Position : TEXCOORD0;
    float3 Normal : TEXCOORD1;
    float2 Uv : TEXCOORD2;
    float4 Tangent : TEXCOORD3;
};

VsOutput vertex_main(VsInput input)
{
    VsOutput output;
    output.Position = mul(float4(input.Position, 1.0), WorldViewProjection);
    output.Normal = normalize(mul(input.Normal, (float3x3)World));
    output.Tangent = float4(normalize(mul(input.Tangent.xyz, (float3x3)World)), input.Tangent.w);
    output.Uv = input.Uv;
    float3 worldPosition = mul(float4(input.Position, 1.0), World).xyz;
    output.WorldPosition = worldPosition;
    output.ShadowPosition = mul(float4(worldPosition, 1.0), LightViewProjection);
    return output;
}
