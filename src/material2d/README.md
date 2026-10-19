# 2D 多 Pass 材质

```sh
odin run src/material2d -collection:olib=../olib -out:build/material2d.exe
```

12 个精灵共用一个 Material；右侧一组通过 `Instance_Values`（`instance_slot` 解析 hue 槽位）把 hue 设为 0.7，不创建第二个 Material，仍合成同一次 Draw。
本例默认先画全部阴影，再画全部本体。
空格切换为逐对象画全部 Pass；两种方式都在 `sprite_begin/end` 中，Renderer 自动合并相邻兼容请求。
`SpriteShadow.oshader` 把 `hue`、`opacity` 标为 `[Instance]`：它们随每个精灵的顶点传入，
取值不同的精灵仍可合批。控制台在模式或批次数变化时报告实际 Draw 次数：默认参数下分阶段为
**24 个 Pass → 2 Draw**（阴影 1 次，本体 1 次，左右两组不同 hue 不再拆批），逐对象仍为 **24 Draw**。按 Pass 分组也改变阴影覆盖本体的顺序，
重叠处可观察区别；库不会替业务排序。
修改 `material.json` 的 hue 后按 R，重载整份材质；右侧一组的 hue 覆盖仍然生效，位置动画继续。
解析或加载失败保留旧材质。Esc 退出。没有自动截图、输入模拟或冒烟模式。

ShaderLab 的 2D 工作区选择“精灵材质 / 阴影 + 本体”，使用同一组 Shader、Effect 和
Sprite 绘制器预览，可修改参数、切换 Pass 并保存整材质 JSON。游戏的帧贴图来自精灵对象。
示例 Shader 默认支持原生 Vulkan、D3D12、Metal；Web 需单独适配 GLSL。

参数和 Shader 唯一来源在 `src/shader_lab`。修改源码后生成发布字节码：

```sh
odin run tools/shader_lab_assets -collection:olib=../olib -out:build/shader_lab_assets.exe
```

业务调用为 `mat.material_load` + `r2d.sprite_draw`（`pass_id` 为空画全部，设置后只画指定 ID）；整张贴图当一帧时用 `sprite_draw_texture`，初始化时登记效果并创建一个
`Sprite_Renderer` 即可。和 3D 共用同一个 `Material_Library` 与加载、修改、重载接口。
插入其他渲染器绘制或清屏前调用 `sprite_flush`；本帧结束、重载或释放资源前调用 `sprite_end`。

## 百万精灵（Swarm）

`I` 键切换（或启动参数 `swarm`，可加 `count=N`，默认 1,000,000）：一个 `Sprite_Buffer`，
100 万个精灵**只有 1 次 Draw**，变换、tint、hue、opacity 加载时一次性上传，之后每帧零 CPU 开销。
参数 `shot` 在固定帧写截图到 `library/screenshots/`（swarm 模式为 `material2d_swarm.png`）并打印平均帧时间；
`immediate` 不限帧并关闭垂直同步，测真实耗时。作者的机器上 100 万个精灵约 1.2 ms/帧，`render` 的 CPU 约 0.02 ms。
这里所有精灵共用一张图，没有剔除；真实游戏把可见的精灵分块放进多个缓冲。
