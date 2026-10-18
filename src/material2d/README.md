# 2D 多 Pass 材质

```sh
odin run src/material2d -collection:olib=../olib -out:build/material2d.exe
```

两个精灵共用 Shader/Effect，各有独立的 Material 参数。本例先画偏移阴影，再画本体。
修改 `material.json` 的 hue 后按 R，只更新左侧；右侧保留自己的 hue，位置动画继续。
解析或加载失败保留旧材质。Esc 退出。没有自动截图、输入模拟或冒烟模式。

ShaderLab 的 2D 工作区选择“精灵材质 / 阴影 + 本体”，使用同一组 Shader、Effect 和
Sprite 绘制器预览，可修改参数、切换 Pass 并保存整材质 JSON。游戏的帧贴图来自精灵对象。
示例 Shader 默认支持原生 Vulkan、D3D12、Metal；Web 需单独适配 GLSL。

参数和 Shader 唯一来源在 `src/shader_lab`。修改源码后生成发布字节码：

```sh
odin run tools/shader_lab_assets -collection:olib=../olib -out:build/shader_lab_assets.exe
```

业务调用为 `rendering.material_load` + `rendering.sprite_draw`，初始化时登记效果并创建一个
`Sprite_Renderer` 即可。和 3D 共用同一个 `Material_Library` 与加载、修改、重载接口。
