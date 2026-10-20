# 从 Shader Lab 到 Render3D

在 olib_sample 根目录运行 `run.bat material3d`。左球读取这里的 material.json，右球是独立材质实例；
两者共用 Effect 和 GPU Shader。示例使用静态网格、最终像素尺寸的 4x MSAA，运行端没有编辑器依赖。

- 空格：切换描边；G：先全部 body 再全部 outline / 逐模型全部 Pass。
- V：第二视图。先把同一份记录的 body 提交到侧面相机（关闭调试线），再提交主视图的 body/outline。
  主视图网格线仍保留；第二视图按原生像素合成到左上角。
- I：切换常驻实例阵列；R：clear 记录后重新载入左球材质，右球保持独立；Esc：退出。
- 相机：左键拖动环绕，右键/中键拖动平移，滚轮缩放，F 复位；按 I 切换时按场景尺度复位。
- P：右上角 olib 性能面板（kit/tools/perf_overlay）：FPS、帧时间曲线，以及 update / render / r3d.submit 的 profiler 作用域耗时。帧时间含垂直同步，配合 immediate 看真实上限；不测 GPU 与 Draw 数，不进 shot 截图。
- 启动参数 `views`、`models`、`swarm` 可直接进入对应演示。

## 业务调用

```odin
material, reason := mat.material_load(&materials, "material.json")
reason = r3d.init(&renderer, &materials) // renderer: r3d.Render3D

r3d.clear(&renderer)
err := r3d.model(&renderer, &mesh, material, transform, bounds = &bounds)
err = r3d.submit(&renderer, view, "body")
err = r3d.submit(&renderer, view, "outline") // 同一记录再次提交
// 检查 reason / err；.None 成功，mat.draw_error_text(err) 给出原因。
```

View 使用原有 Camera3D 的 view_projection 和 view_matrix；Render3D 不修改相机 viewport。
记录复制参数/贴图绑定，submit 不清空；重载或销毁借用资源前必须 clear，退出时先 dispose renderer。
多 Pass、剔除与排序规则见 [Render3D README](../../../olib/kit/rendering/3d/README.md)。

shaders.odin 初始化时登记一次效果和预编译代码，库负责 Shader、贴图、绑定和统一释放。
material_set_number 影响之后的记录。R 不重编 Shader、不刷新缓存贴图；失败保留原材质。

## 自动实例化与常驻实例

`run.bat material3d models count=4096` 使用一个 model 加一组 models，自动合成一次 Draw。
CPU 数组直接沿用 Model_Item 和平铺 `[][4]f32`，不创建业务 GPU 缓冲。
每帧记录 CPU 数据，submit 逐实例剔除、排序并紧凑上传；`count=1` 也能运行。

`run.bat material3d swarm` 默认 1,000,000 个实例，可加 `count=N`。
这个模式使用常驻 Model_Buffer，加载时上传一次，之后通过 `r3d.buffer` 记录引用，每 Pass 一次 Draw。
只有整块世界 bounds 剔除与排序，没有逐实例剔除、读回或重排；真实场景可以按空间分块。
**每个实例每帧都在动，但缓冲加载后不再改写**：实例里存的是不变的运动参数（`_motion`：相位、角速度、环绕半径），
顶点着色器用顶点 b0 的 Clock 算出当前位置，片元着色器用 Clock 变色，CPU 每帧只传时间。
大量物体按规律运动（粒子、草、鱼群）都适合这样做；需要逐帧积累状态的模拟才需要 CPU 改数据或 compute shader。
每实例 112 字节（矩阵 64 + tint 16 + hue 16 + motion 16），100 万实例约 112 MB 显存（容量按 2 的幂取整）。
bounds 按最大环绕半径外扩，否则运动出盒的部分会被剔除。
常驻实例的字段值来自缓冲，自动 models 则支持每 Pass 的独立覆盖。

两种模式均使用低模球（默认 rings=2、segments=4），相机按阵列规模调整。
`rings=N segments=N` 改网格精度，`samples=1|2|4` 改 MSAA，`back` 将远处常驻实例放在前面比较深度测试成本。

## 截图与计时

加 `shot` 固定动画时间，预热 10 帧、统计 120 帧，保存最终合成图到 library/screenshots 后退出：
material3d.png、material3d_views.png、material3d_models.png 或 material3d_swarm.png。
输出模型 Draw 数、按所有 Pass 累计的实例数、整个 render 的 CPU 时间和仅 Render3D submit 的 CPU 时间。
`immediate` 关闭垂直同步和固定步长；帧时间仍不等于 GPU 时间，当前没有 GPU 时间戳测量。

2026-10-20 本机 D3D12、1100×720、4x MSAA，tools/check 默认构建的验收结果（毫秒，非性能保证）：

| 模式 | 模型 Draw | 累计实例 | render CPU | submit CPU |
| --- | ---: | ---: | ---: | ---: |
| 默认双球 body + outline | 4 | 4 | 0.150 | 0.046 |
| 第二视图 body + 主视图 body/outline | 6 | 6 | 0.207 | 0.080 |
| models，4096 实例 | 1 | 4096 | 2.935 | 0.891 |
| 常驻 swarm，100 万实例 | 1 | 1000000 | 0.118 | 0.030 |

models 的 render CPU 包含每帧记录、bounds 转换；submit 包含剔除、排序和上传。
常驻 swarm 无这些逐实例工作，因此不能只按实例数量直接比较两条路径。
上述运行被限到约 16.667 ms/帧；**GPU 时间未测**。

## 从 Shader Lab 保存材质

1. `run.bat shader_lab`，切到 3D，选择“模型材质 / 本体 + 描边”。
2. 调整本体和描边颜色，保存整份材质 JSON。
3. `run.bat material3d <导出路径>`，或覆盖本例 material.json 后按 R。

资源通过 foster.StorageContainer 读取，根目录为所选材质文件所在目录。
效果源码在 `../shader_lab/shaders/Outlined.oshader` 和 `Swarm.oshader`，运行时只读取编译后的清单和字节码。
修改 HLSL / 参数布局后，在示例仓库根重新生成 Shader 并重建：

```sh
odin run tools/shader_lab_assets -collection:olib=../olib -out:build/shader_lab_assets.exe
run.bat material3d
```

生成需要 Odin 和 shadercross，Compiled 资源随源码提交；运行时不需要 shadercross。
描边沿球面法线外扩，bounds 已包含外扩范围。蒙皮、硬边接缝、完整阴影管线与后处理不在本例范围内。
