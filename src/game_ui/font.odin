package main

import ui "olib:kit/ui"
import fonts "../../shared/msdf_font"

// 默认嵌入真正的离线 MSDF；font 参数指定 PNG/JSON 的共同前缀。
load_font :: proc() -> bool {
	loaded, texture, ok := fonts.load(&game.GraphicsDevice, font_path)
	if !ok do return false
	font = loaded
	font_texture = texture
	ui.ui_register_font(&ctx, &font, texture, .MSDF)
	return true
}
