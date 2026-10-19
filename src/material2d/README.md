# 2D 多 Pass 材质

```sh
odin run src/material2d -collection:olib=../olib -out:build/material2d.exe
```

12 个精灵共用一个 Material；右侧通过 Instance_Values 将 hue 覆盖成 0.7，不创建第二个材质。
默认用 pass_id 分两轮记录阴影和本体；空格切换为逐个记录全部 Pass，由 Render2D 自动按 Pass 分组。
两种方式都在最后 submit，均为 **12 个精灵 × 2 Pass → 2 Draw**，不同 hue 和 tint 不拆批。
只有相邻且材质、参数、纹理与状态兼容的记录才合并，不跨材质排序。

R 重载 material.json，失败保留旧材质；Esc 退出。shot 在固定帧截图到 library/screenshots。
业务入口是 material_load、r2d.image/texture、r2d.submit；初始化一个 Render2D 即可，
与 3D 共用 Material_Library。清屏、其他渲染、重载或释放资源之前先提交。

Shader Lab 的 2D 工作区选择“精灵材质 / 阴影 + 本体”，可修改独立 Pass 参数并保存整材质。
Shader 唯一来源在 src/shader_lab，发布普通批量与常驻缓冲两种顶点变体：

```sh
odin run tools/shader_lab_assets -collection:olib=../olib -out:build/shader_lab_assets.exe
```

本例使用实例 storage buffer，支持原生 Vulkan、D3D12、Metal，不支持 Web。
Web 可用的内置精灵/MSDF 效果见 olib 的 Render2D README。

## 百万精灵（Swarm）

I 或启动参数 swarm 切换，count=N 指定数量，默认 1,000,000。
一个 Sprite_Buffer，变换、tint、hue、opacity 初始化时上传；每帧记录 buffer 并 submit，只有 1 Draw。
运行 `swarm shot` 输出 material2d_swarm.png 和平均帧/CPU 时间；immediate 关闭垂直同步并不限帧。
本次验收 100 万精灵约 0.05–0.07 ms render CPU，实际耗时取决于设备与运行环境。
所有精灵共用一张图，没有剔除；游戏可分成多个空间块，只记录可见块。
