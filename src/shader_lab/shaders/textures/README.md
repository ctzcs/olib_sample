# 预览贴图

把 PNG、JPEG 或 QOI 图片放在这个目录。Shader Lab 的 Texture 按钮会列出它们，
选择后立即加载；加载失败保留旧纹理。空路径使用内置棋盘纹理。

Odin 默认值中的图片路径相对于 `shaders/`（或命令行指定的 `source` 目录），
例如 `image = "textures/noise.png"`。面板选择仅用于本次预览，不修改 Odin 源文件。
