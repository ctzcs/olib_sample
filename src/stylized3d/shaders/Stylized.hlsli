// stylized3d 的 Model Pass 共用声明：宿主帧块、视图块与卡通光照。
// 顶点 b0：WVP、World、Clock、CameraPosition；instanced 效果里前两项是 ViewProjection 与单位矩阵。
cbuffer MatrixBlock : register(b0, space1) { float4x4 Wvp; float4x4 World; float4 VertexClock; float4 VertexCamera; };
// 片元 b0：Clock、Pointer、Tint、CameraPosition。
cbuffer FrameBlock : register(b0, space3) { float4 Clock; float4 Pointer; float4 Tint; float4 CameraPosition; };

// 视图块：顶点 b1 与片元 b2 是同一份字节，布局与 main.odin 的 Scene_View 一致（全 float4，无补齐）。
// 每个视图各自提交一份，所以主相机与小地图的太阳、雾和 billboard 朝向互不影响。
struct SceneView {
    float4 sun_direction; // xyz：光线前进方向（从太阳射向地面）
    float4 sun_color;     // a = 1 表示宿主提供了视图块；Shader Lab 预览提交全零
    float4 ambient;
    float4 fog_color;
    float4 fog;           // x 起点、y 终点（到相机的距离），z 强度
    float4 camera_right;  // billboard 展开用的相机轴（世界空间）
    float4 camera_up;
};
cbuffer VertexViewBlock : register(b1, space1) { SceneView VertexView; };
cbuffer FragmentViewBlock : register(b2, space3) { SceneView FragmentView; };

// 视图块全零（Shader Lab 预览）时换成默认值，同一份 Shader 不改就能预览。
SceneView scene_view(SceneView s)
{
    if (s.sun_color.a == 0) {
        s.sun_direction = float4(normalize(float3(-0.45, -0.8, -0.4)), 0);
        s.sun_color = float4(0.95, 0.88, 0.75, 1);
        s.ambient = float4(0.32, 0.36, 0.52, 1);
        s.fog = float4(0, 1, 0, 0);
        s.camera_right = float4(1, 0, 0, 0);
        s.camera_up = float4(0, 1, 0, 0);
    }
    return s;
}

// 网格属性按静态顶点格式依次声明；只用前几个时，后面未用的属性不影响各后端的属性编号。
struct MeshInput {
    float3 Position : TEXCOORD0;
    float3 Normal : TEXCOORD1;
    float2 Uv : TEXCOORD2;
    float4 Tangent : TEXCOORD3;
};

// 两阶卡通光 + 距离雾。
float3 stylized_shade(float3 albedo, float3 normal, float3 world_position)
{
    SceneView view = scene_view(FragmentView);
    float lit = smoothstep(-0.08, 0.08, dot(normalize(normal), -view.sun_direction.xyz));
    float3 color = albedo * (view.ambient.rgb + view.sun_color.rgb * lit);
    float distance = length(world_position - CameraPosition.xyz);
    float fog = saturate((distance - view.fog.x) / max(view.fog.y - view.fog.x, 0.001));
    return lerp(color, view.fog_color.rgb, fog * view.fog.z);
}
