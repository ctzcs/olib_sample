package shader_lab_checks

// 本轮功能的单次集中检查，不重复运行 Shader 故障注入整套回归。
import "core:fmt"
import "core:os"

import foster "olib:foster"
import lab "olib:kit/tools/shader_lab"
import dev "olib:kit/shaderdev"

feature_image :: proc(s: ^State, color: foster.Color) {
	image := foster.ImageMake(8, 8, color)
	defer foster.ImageDispose(&image)
	check(s, foster.ImageWritePng(&image, fmt.tprintf("%s/feature.png", s.temp_root)), "write feature image")
}

feature_prepare :: proc(data: rawptr, frame: lab.Preview_Frame, command: ^foster.DrawCommand) -> bool {
	s := cast(^State)data
	s.feature_prepare += 1
	if frame.dimension != "3d" do return false
	foster.DrawCommandFromMesh(command, frame.target, &s.meshes[2], frame.material)
	command.DepthTestEnabled = true
	command.DepthWriteEnabled = true
	command.CullMode = .Back
	return true
}

feature_draw :: proc(data: rawptr, frame: lab.Preview_Frame, command: ^foster.DrawCommand) {
	s := cast(^State)data
	s.feature_draw += 1
	foster.GraphicsDeviceDraw(frame.device, command)
}

validate_features :: proc(s: ^State, app: ^foster.App) {
	if s.shader_count < 2 || s.pending_bank != nil || s.selected_effect < 0 || !s.effects[s.selected_effect].ready do return
	preset := fmt.tprintf("%s/feature-preset.json", s.temp_root)
	image_path := fmt.tprintf("%s/feature.png", s.temp_root)
	p := &s.parameters[0]
	if s.smoke_step == 0 {
		s.feature_texture = -1
		for f, i in p.live.fields {
			if f.kind == .Texture do s.feature_texture = i
		}
		check(s, s.feature_texture >= 0, "texture field discovered")
		feature_image(s, foster.Red)
		lab.parameter_texture_set(s.tool, 0, s.feature_texture, image_path)
		p.values[0].number[0] = 0.82
		check(s, lab.save_preset(s.tool, 0, preset), "save preset")
		check(s, lab.reset_defaults(s.tool, 0), "reset entire group")
		check(s, lab.parameter_number(s.tool, 0, "strength") == 0.65, "default values restored")
		check(s, lab.load_preset(s.tool, 0, preset), "reload saved preset with relative texture")
		check(s, lab.parameter_number(s.tool, 0, "strength") == 0.82 && p.textures[0].Resource != nil,
			"preset round-trip preserves values and texture")
		lab.request_file(s.tool, 0, .Texture, "image")
		request := lab.file_request(s.tool)
		check(s, lab.file_reply(s.tool, request.id, ""), "cancelled file selection is harmless")
		lab.request_file(s.tool, 0, .Texture, "image")
		request = lab.file_request(s.tool)
		p.generation += 1
		check(s, !lab.file_reply(s.tool, request.id, image_path), "stale async selection rejected")
		old_texture := p.textures[0].Resource
		bad := fmt.tprintf("%s/feature-bad.json", s.temp_root)
		_ = os.write_entire_file(bad, `{"version":1,"group":"Preview2D","fields":[{"id":"image","kind":"Texture","texture":"missing.png"}]}`)
		check(s, !lab.load_preset(s.tool, 0, bad) && old_texture == p.textures[0].Resource &&
			lab.parameter_number(s.tool, 0, "strength") == 0.82, "invalid preset texture rolls back whole import")
		check(s, lab.reset_defaults(s.tool, 0, 0), "reset one field")
		check(s, p.textures[0].Resource != nil, "single-field reset retains other fields")
		feature_image(s, foster.Blue)
		select_parameter_effect(s, 1)
		s.mode = 2
		s.preview_hooks = {s, feature_prepare, feature_draw}
		s.custom_preview = true
		s.parameter_revision = s.shaders[1].revision
		dev.retry(&s.shaders[1])
		s.smoke_step = 1
		s.elapsed = 0
		return
	}
	if s.smoke_step == 1 {
		if s.elapsed < 0.8 || s.shaders[1].revision <= s.parameter_revision do return
		pixels := foster.TextureDownloadData(&p.textures[0])
		defer delete(pixels)
		check(s, len(pixels) >= 4 && pixels[0] == 0 && pixels[2] == 255, "texture file refresh reaches GPU")
		check(s, s.feature_prepare > 0 && s.feature_draw > 0, "host prepare/probe and draw callbacks used")
		capture(s, "features-host")
		press_widget(s, app, "sidebar-splitter", 0.5)
		s.smoke_step = 2
		s.capture_index = 0
		return
	}
	// 输入在固定 Update 消费；不能假设每个渲染帧都推进了输入状态。
	if s.elapsed < s.feature_next do return
	s.feature_next = s.elapsed+0.04
	s.capture_index += 1
	switch s.capture_index {
	case 2:
		pixels := foster.SizeInPixels(&app.Window)
		logical := foster.Size(&app.Window)
		foster.InputMouseMove(&app.Input, {
			(s.region.X+380)*f32(logical.X)/f32(pixels.X),
			(s.region.Y+160)*f32(logical.Y)/f32(pixels.Y)}, {}, app.Time.Elapsed)
	case 4:
		foster.InputMouseButton(&app.Input, .Left, false, app.Time.Elapsed)
	case 6:
		check(s, s.sidebar_width > 340 && scene_texture(s).Width == int(s.viewport.Width), "splitter updates viewport and Pass target")
		press_widget(s, app, "toggle-sidebar", 0.5)
	case 8:
		foster.InputMouseButton(&app.Input, .Left, false, app.Time.Elapsed)
	case 12:
		check(s, s.sidebar_collapsed && s.viewport.X == 8, "collapsed inspector expands preview")
		foster.SetWindowSize(&app.Window, {540, 640})
	case 16:
		press_widget(s, app, "toggle-sidebar", 0.5)
	case 18:
		foster.InputMouseButton(&app.Input, .Left, false, app.Time.Elapsed)
	case 22:
		check(s, s.compact && !s.sidebar_collapsed && s.viewport.X == 8, "small panel uses overlay inspector")
		capture(s, "features-compact")
		if !s.failed do fmt.println("PASS: presets/defaults/rollback, stale file request, texture reload, custom preview, splitter/collapse/compact")
		foster.Exit(app)
	}
}
