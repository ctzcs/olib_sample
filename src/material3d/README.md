# 从 Shader Lab 到游戏模型

在 olib_sample 根目录运行 `run.bat material3d`。左球读取这里的 `material.json`，右球是独立实例；
两者共用 Effect 和 GPU Shader。空格切换描边，R 重新读取左球的材质，Esc 退出。
示例使用静态网格和原生像素 4x MSAA，不包含编辑器或热重载依赖。

业务接入现在只需加载、赋给模型和绘制：

```odin
model.material, reason = rendering.material_load(&materials, "material.json")
ok := r3d.model_draw(model, transform, view)
```

`shaders.odin` 在资源初始化时登记一次效果和预编译代码；库负责创建 Shader、加载贴图、
组装 Pass 绑定及统一释放。两个模型分别 load 同一文件，参数独立、Shader 和贴图共享。
数值可用 `material_set_number` 修改；R 使用 `material_reload`，成功后模型槽指针不变。
资源文件通过 `foster.StorageContainer` 读取，本例把所选材质文件所在目录作为根。
同路径贴图保持缓存；R 不重编 Shader、不刷新贴图内容。

1. `run.bat shader_lab`，切到 3D，选择“模型材质 / 本体 + 描边”。
2. 分别调整本体和描边的颜色，点“保存”导出整份材质 JSON。
3. `run.bat material3d <导出的文件路径>`，或覆盖本例 material.json 后在运行窗口按 R。
   重新载入失败保留旧材质；只更新左球，右球不受影响。

文件保存参数和贴图路径，不保存 Shader 字节码；效果定义位于
`../shader_lab/shader_params/outline.odin`，HLSL 唯一来源是 `../shader_lab/shaders`。
运行端静态引用定义、嵌入 Compiled 字节码；不 import Shader Lab 或 shaderdev。

修改 HLSL / 参数布局后，先重新生成发布 Shader，再重建示例：

```sh
odin run tools/shader_lab_assets -collection:olib=../olib -out:build/shader_lab_assets.exe
run.bat material3d
```

构建需要 Odin 和 shadercross。工具先按实际 Odin 定义生成 library/shader_dev 中的头文件，
再调用 olib/tools/shaders 生成 SPIR-V、DXIL、MSL 到源码旁 Compiled。这些正式编译资源应随源码提交。
运行时不需要 shadercross；贴图和材质 JSON 属于外部资产，发布时需打包并传入材质文件路径。

第一版是静态模型的几何描边。宽度在 Outline.hlsl 中，颜色在材质里；不提供蒙皮、
屏幕空间描边、逐模型模糊/反馈或自动 Web GLSL 转换。球面展示平滑法线外扩；硬边模型需作者处理接缝。
