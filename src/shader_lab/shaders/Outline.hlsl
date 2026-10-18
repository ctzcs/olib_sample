#include "../../../library/shader_dev/Outline/params.generated.hlsli"
cbuffer MatrixBlock : register(b0, space1) { float4x4 Wvp; float4x4 World; };
struct Input {
    float3 Position : TEXCOORD0;
    float3 Normal : TEXCOORD1;
    float2 Uv : TEXCOORD2;
    float4 Tangent : TEXCOORD3;
};
float4 vertex_main(Input v) : SV_Position
{
    // Object-space thickness; edit this constant live in Shader Lab.
    return mul(float4(v.Position + v.Normal * 0.055, 1), Wvp);
}
float4 fragment_main() : SV_Target0 { return _color; }
