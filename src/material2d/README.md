# 2D 多 Pass 材质

```sh
odin run src/material2d -collection:olib=../olib -out:build/material2d.exe
```

12 个精灵共用 Shader/Effect，左右两组各用一个独立 Material。本例默认先画全部阴影，再画全部本体。
空格切换为逐对象画全部 Pass；两种方式都在 `sprite_begin/end` 中，Renderer 自动合并相邻兼容请求。
控制台在模式或批次数变化时报告实际 Draw 次数：默认参数下分阶段为 **24 个 Pass → 3 Draw**
（阴影 1 次，左右本体各 1 次），逐对象为 **24 Draw**。按 Pass 分组也改变阴影覆盖本体的顺序，
重叠处可观察区别；库不会替业务排序。
修改 `material.json` 的 hue 后按 R，只更新左侧组；右侧保留自己的 hue，位置动画继续。
解析或加载失败保留旧材质。Esc 退出。没有自动截图、输入模拟或冒烟模式。

ShaderLab 的 2D 工作区选择“精灵材质 / 阴影 + 本体”，使用同一组 Shader、Effect 和
Sprite 绘制器预览，可修改参数、切换 Pass 并保存整材质 JSON。游戏的帧贴图来自精灵对象。
示例 Shader 默认支持原生 Vulkan、D3D12、Metal；Web 需单独适配 GLSL。

参数和 Shader 唯一来源在 `src/shader_lab`。修改源码后生成发布字节码：

```sh
odin run tools/shader_lab_assets -collection:olib=../olib -out:build/shader_lab_assets.exe
```

业务调用为 `rendering.material_load` + `rendering.sprite_draw`（全部）或 `sprite_draw_pass`（指定 ID），初始化时登记效果并创建一个
`Sprite_Renderer` 即可。和 3D 共用同一个 `Material_Library` 与加载、修改、重载接口。
插入其他渲染器绘制或清屏前调用 `sprite_flush`；本帧结束、重载或释放资源前调用 `sprite_end`。
