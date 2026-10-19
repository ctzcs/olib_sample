# 从 Shader Lab 到游戏模型

在 olib_sample 根目录运行 `run.bat material3d`。左球读取这里的 `material.json`，右球是独立实例；
两者共用 Effect 和 GPU Shader。空格切换描边，R 重新读取左球的材质，Esc 退出。
默认先画所有本体再画所有描边，G 切换为逐模型画全部 Pass；不需要描边时只选 `body`。
示例使用静态网格和原生像素 4x MSAA，不包含编辑器或热重载依赖。

业务接入只需加载材质并绘制：

```odin
material, reason := mat.material_load(&materials, "material.json")
err := r3d.model_draw(material, &mesh, transform, view) // .None 为成功；mat.draw_error_text(err) 给出失败原因
// 或只画一个 Pass，顺序由调用者组织：
err = r3d.model_draw(material, &mesh, transform, view, "outline")
```

`shaders.odin` 在资源初始化时登记一次效果和预编译代码；库负责创建 Shader、加载贴图、
组装 Pass 绑定及统一释放。两个模型分别 load 同一文件，参数独立、Shader 和贴图共享。
数值可用 `material_set_number` 修改；R 使用 `material_reload`，成功后材质指针不变。
`model_draw` 逐个网格提交，不自动合并；按 Pass 分组可减少程序/状态来回切换，大批量同一网格用下面的 `Model_Buffer`。
资源文件通过 `foster.StorageContainer` 读取，本例把所选材质文件所在目录作为根。
同路径贴图保持缓存；R 不重编 Shader、不刷新贴图内容。

1. `run.bat shader_lab`，切到 3D，选择“模型材质 / 本体 + 描边”。
2. 分别调整本体和描边的颜色，点“保存”导出整份材质 JSON。
3. `run.bat material3d <导出的文件路径>`，或覆盖本例 material.json 后在运行窗口按 R。
   重新载入失败保留旧材质；只更新左球，右球不受影响。

文件保存参数和贴图路径，不保存 Shader 字节码；效果定义位于
`../shader_lab/shaders/Outlined.oshader`；运行时读取编译后的清单和字节码。
运行端静态引用定义、嵌入 Compiled 字节码；不 import Shader Lab 或 shader/dev。

修改 HLSL / 参数布局后，先重新生成发布 Shader，再重建示例：

```sh
odin run tools/shader_lab_assets -collection:olib=../olib -out:build/shader_lab_assets.exe
run.bat material3d
```

构建需要 Odin 和 shadercross。工具调用 olib/tools/shaders，从 .oshader 生成材质清单及 SPIR-V、DXIL、MSL 到源码旁 Compiled。这些正式编译资源应随源码提交。
运行时不需要 shadercross；贴图和材质 JSON 属于外部资产，发布时需打包并传入材质文件路径。

第一版是静态模型的几何描边。宽度在 Outlined.oshader 的 outline Pass 中，颜色在材质里；不提供蒙皮、
屏幕空间描边、逐模型模糊/反馈或自动 Web GLSL 转换。球面展示平滑法线外扩；硬边模型需作者处理接缝。

## 百万实例（Swarm）

`I` 键切换（或启动参数 `swarm`，可加 `count=N`，默认 1,000,000）：一个低模球体 + 一个
`Model_Buffer`，每个 Pass **只有 1 次 Draw**。实例的世界矩阵、tint、hue 在加载时一次性上传，
之后每帧零 CPU 开销；颜色动画在着色器里按 Clock 计算。着色器在 `src/shader_lab/shaders/Swarm.oshader`。
参数 `shot` 在固定帧写一张截图到 `library/screenshots/` 后退出（swarm 模式文件名为 `material3d_swarm.png`），
swarm 模式还会打印平均帧时间和 render 过程的 CPU 耗时。这里没有视锥剔除；真实游戏把实例分块放进多个缓冲，只画可见的块。

性能对比参数（加在 `swarm shot` 后）：`immediate` 不限帧并关闭垂直同步，测真实 GPU 耗时；
`rings=N segments=N` 球体精度（默认 2×4，共 16 个三角形）；`back` 远处实例先画（最差的深度测试顺序）；`samples=1|2|4`。
在作者的机器上（100 万实例、1100×720，不限帧）：

| 配置 | 平均帧时间 |
| --- | --- |
| 6×8 球（96 三角形），远处先画，4×MSAA | 约 25 ms |
| 6×8 球，近处先画 | 约 20 ms |
| 2×4 球（16 三角形），近处先画（默认） | 约 6 ms |
| 同上，关闭 MSAA | 约 6 ms |

CPU 侧 `render` 只有约 0.1 ms（一次 Draw）。成本几乎全在 GPU 的三角形数上：每个实例只有几个像素，
没必要用 96 个三角形；按距离选 LOD、剔除看不见的实例才是进一步提速的办法，不是实例化本身。
