# 风格化 3D：视图块、剪影与深度描边

在 olib_sample 根目录运行 `run.bat stylized3d`。按 [Celeste64](https://github.com/ExOK/Celeste64) 一帧的结构，
用 Render3D 验收三项机制。几何是程序生成的方块和球，资产与代码都不取自 Celeste64。
光照、雾和描边的外观都在 `shaders/` 里，属于本示例；olib 只提供下面这些机制。

- 空格：暂停；E：开关深度描边；Esc：退出。
- `shot` 用固定时间画一帧，把最终合成（含 UI）写到 `library/screenshots/stylized3d.png` 后退出；
  `shot flat` 关掉描边，写 `stylized3d_flat.png` 便于对比。`SDL_GPU_DRIVER=vulkan` / `direct3d12` 选后端。

## 一帧

1. 640×360 场景 Target（颜色 + 单采样 Depth32），整数倍最近邻放大。
2. 同一份记录按 Pass id 分阶段提交：`sky` → `scene` → `silhouette` → `body`。
   剪影（`ZTest Greater`、不写深度）要在遮挡物写完深度之后、角色本体写深度之前画，
   否则会叠到角色自己被挡住的部位上。场景材质与角色用不同的 Pass id，才能把两者拆开提交。
3. 深度描边：Render2D 用 DepthEdge 材质把场景颜色画到 post，材质里的 `_depth` 由
   `material_set_texture` 绑定场景的深度附件。深度附件不能在仍是当前深度目标时采样，
   所以先画到另一张 Target，再拷回场景，场景深度留给后面的半透明面片。
4. `transparent`：金币面片沿视图块里的相机轴展开，读场景深度、不写深度。
5. 小地图：同一份记录提交给俯视相机，视图块不同（不加雾、相机轴不同），面片朝向俯视相机。
6. 合成在最终窗口像素尺寸进行；小地图与 HUD 不随低分辨率场景放大。

## 视图块

`View.globals` 是游戏按 std140 打包的字节，Model Pass 从顶点 b1 / 片元 b2 读取，最多 1024 字节，不足补零。
本示例的布局是 `main.odin` 的 `Scene_View`，与 `shaders/Stylized.hlsli` 的 `SceneView` 一一对应：

```odin
globals := scene_view(&camera, fog = 0.85) // 太阳、雾、相机轴
view := r3d.View{target = scene, view_projection = world.camera3d_view_projection(&camera),
	view_matrix = world.camera3d_view(&camera), globals = mem.ptr_to_bytes(&globals)}
err := r3d.submit(&renderer, view, "scene")
```

太阳与雾放在视图块里，所有材质都能读到，不必逐个材质 `material_set_number`；
相机轴必须逐视图，不能放在材质参数里（同一份记录会提交给多个视图）。
Shader Lab 预览提交全零，`scene_view()` 据 `sun_color.a == 0` 换成默认值，同一份 Shader 不改就能预览。

## Shader

改了 `shaders/` 下的源码后，在 olib_sample 根目录重新生成 `Compiled/`（需要 PATH 上的 SDL_shadercross）：

```sh
odin run ../olib/tools/shaders -- -dir:src/stylized3d/shaders
```

Shader Lab 可直接预览和热重载这些 Shader：`run.bat shader_lab source <绝对路径>/src/stylized3d/shaders`。
