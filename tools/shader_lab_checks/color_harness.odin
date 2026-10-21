package shader_lab_checks

// 调色板实际输入验收；复用隔离的 Shader Lab 源码和最终输出截图。
// ImGui ColorPicker4 的色相与透明度条是竖条：色相自上而下 0→1，透明度自上而下 1→0。
import foster "olib:foster"
import lab "olib:kit/tools/shader_lab"
import imgui "olib:thirdparty/odin-imgui"

color_test_value :: proc(s: ^State, group: int) -> [4]f32 {
	p := &s.parameters[group]
	for field, i in p.live.fields {
		if field.id == "tint" do return p.values[i].number
	}
	return {}
}

color_test_move :: proc(s: ^State, app: ^foster.App, id: string, x, y: f32, down: bool) {
	rect, found := lab.widget_rect(s.tool, id)
	check(s, found, "color control exists")
	inject_move(s, app, widget_point(rect, x, y))
	inject_button(s, app, down)
}

validate_color_frame :: proc(s: ^State, app: ^foster.App) {
	if waiting(s, preview_ready(s), "bank committed and selected shader drawn") do return
	step := s.capture_index
	switch step {
	case 0:
		select_parameter_shader(s, 1)
		s.mode = 2
	case 2:
		s.initial_pixels = scene_hash(s)
		s.parameter_revision = s.programs[1].revision
		press_widget(s, app, "Preview3D_main:tint:color", 0.5)
	case 4, 8, 12, 17, 22, 26, 30, 34, 40, 45, 49, 55, 59, 63, 69, 73, 81, 85:
		release_pointer(s, app)
	case 6:
		check(s, s.color_picker.open, "Tint swatch opens palette")
		press_widget_at(s, app, "color-hue", 0.5, 0.58)
	case 10:
		color_test_move(s, app, "color-sv", 0.8, 0.25, true)
	case 14:
		check(s, color_test_value(s, 1)[2] > color_test_value(s, 1)[0], "hue and SV select blue")
		check(s, scene_hash(s) != s.initial_pixels, "palette updates scene immediately")
		check(s, color_test_value(s, 0) == [4]f32{1, 1, 1, 1} && s.yaw == 0.4, "palette isolates shader and camera")
		capture(s, "palette")
	case 15:
		press_widget_at(s, app, "color-alpha", 0.5, 0.6)
	case 19:
		check(s, color_test_value(s, 1)[3] > 0.35 && color_test_value(s, 1)[3] < 0.45, "opacity control updates alpha")
		capture(s, "palette-alpha")
	case 20:
		press_widget(s, app, "color-cancel", 0.5)
	case 24:
		check(s, !s.color_picker.open && color_test_value(s, 1) == [4]f32{1, 1, 1, 1}, "cancel restores original color")
		check(s, scene_hash(s) == s.initial_pixels, "cancel restores exact preview pixels")
		press_widget(s, app, "Preview3D_main:tint:color", 0.5)
	case 28:
		press_widget(s, app, "color-preset:2", 0.5)
	case 32:
		press_widget(s, app, "color-apply", 0.5)
	case 36:
		value := color_test_value(s, 1)
		check(s, !s.color_picker.open && value[0] > 0.95 && value[1] < 0.25 && value[3] == 1, "apply keeps chosen preset")
		check(s, s.programs[1].revision == s.parameter_revision, "color edits do not compile shaders")
	case 38:
		press_widget(s, app, "Preview3D_main:tint:color", 0.5)
	case 42:
		color_test_move(s, app, "color-sv", 0.5, 0.5, true)
	case 43:
		color_test_move(s, app, "color-sv", 1.5, -0.5, true)
	case 47:
		hsv := lab.color_rgb_to_hsv({s.color_picker.color[0], s.color_picker.color[1], s.color_picker.color[2]})
		check(s, !imgui.IsAnyItemActive() && hsv[1] > 0.999 && hsv[2] > 0.999,
			"drag outside clamps and releases capture")
		press_widget(s, app, "color-cancel", 0.5)
	case 51:
		value := color_test_value(s, 1)
		check(s, !s.color_picker.open && value[0] > 0.95 && value[1] > 0.15 && value[1] < 0.25,
			"second cancel restores accepted color")
		capture(s, "palette-applied")
		select_parameter_shader(s, 0)
		s.mode = 1
	case 53:
		s.initial_2d_pixels = scene_hash(s)
		press_widget(s, app, "Preview2D_main:tint:color", 0.5)
	case 57:
		press_widget(s, app, "color-preset:5", 0.5)
	case 61:
		press_widget(s, app, "color-apply", 0.5)
	case 65:
		value := color_test_value(s, 0)
		check(s, value[2] == 1 && value[0] < 0.15 && color_test_value(s, 1)[0] > 0.95,
			"2D and 3D colors remain independent")
		check(s, scene_hash(s) != s.initial_2d_pixels, "palette visibly updates 2D sprite")
		capture(s, "palette-sprite")
	case 67, 79:
		press_widget(s, app, "Preview2D_main:tint:color", 0.5)
	case 71, 83:
		press_widget(s, app, "color-preset:3", 0.5)
	case 75:
		inject_key(s, app, .Escape, true)
	case 77:
		inject_key(s, app, .Escape, false)
		check(s, !s.color_picker.open && color_test_value(s, 0)[2] == 1, "Escape cancels palette without quitting")
	case 87:
		s.color_test_blur = true
	case 89:
		check(s, !s.color_picker.open && color_test_value(s, 0)[2] == 1, "focus loss cancels and restores color")
		s.color_test_blur = false
		finish(s, app, "PASS: palette hue/SV/alpha/presets, live 2D/3D, cancel/apply/Escape/blur, drag capture, isolated values")
	}
	s.capture_index += 1
}
