// EXE 与 DLL 的共享宿主协议。改这里须同时重建宿主并增加 HOST_VERSION。
package contract

import foster "olib:foster"
import ui "olib:kit/ui"

HOST_VERSION :: u64(2)

Input :: struct {
	move: [2]f32,
	toggle_pause: bool,
	mouse: foster.Vec2,
	mouse_down: bool,
	wheel: foster.Vec2,
	navigation: ui.UI_Navigation,
}

// 宿主拥有 font/texture/device；模块只借用，卸载前释放引用它们的 UI 与 Batcher。
Services :: struct {
	app: ^foster.App,
	font: ^foster.MsdfFont,
	font_texture: foster.Texture,
	scale: f32,
	input: Input,
}
