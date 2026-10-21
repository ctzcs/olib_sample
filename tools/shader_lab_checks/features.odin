package shader_lab_checks

// 本轮功能的单次集中检查，不重复运行 Shader 故障注入整套回归。
import "core:fmt"
import "core:os"

import foster "olib:foster"
import r2d "olib:kit/rendering/2d"
import r3d "olib:kit/rendering/3d"
import mat "olib:kit/rendering/material"
import lab "olib:kit/tools/shader_lab"

feature_image :: proc(s: ^State, color: foster.Color) {
	image := foster.ImageMake(8, 8, color)
	defer foster.ImageDispose(&image)
	check(s, foster.ImageWritePng(&image, fmt.tprintf("%s/feature.png", s.temp_root)), "write feature image")
}

// 录制式自定义预览：宿主用游戏同一套 API 记录自己的几何（左上角的小精灵代替居中预览），Shader Lab 负责提交。
feature_record :: proc(data: rawptr, frame: lab.Preview_Frame, material: ^mat.Material,
	sprites: ^r2d.Render2D, _: ^r3d.Render3D) -> bool {
	s := cast(^State)data
	s.feature_record += 1
	if sprites == nil do return false
	texture := &s.sprite_texture
	return r2d.image(sprites, foster.SubtextureFromTexture(texture), {0.25, 0, 0, 0.25, 32, 32},
		material = material, pass_id = mat.Pass_Id(frame.pass)) == .None
}

validate_features :: proc(s: ^State, app: ^foster.App) {
	if waiting(s, preview_ready(s), "bank committed and selected shader drawn") do return
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
		_ = os.write_entire_file(bad, `{"version":1,"group":"Preview2D_main","fields":[{"id":"image","kind":"Texture","texture":"missing.png"}]}`)
		check(s, !lab.load_preset(s.tool, 0, bad) && old_texture == p.textures[0].Resource &&
			lab.parameter_number(s.tool, 0, "strength") == 0.82, "invalid preset texture rolls back whole import")
		check(s, lab.reset_defaults(s.tool, 0, 0), "reset one field")
		check(s, p.textures[0].Resource != nil, "single-field reset retains other fields")
		feature_image(s, foster.Blue)
		select_parameter_shader(s, 1)
		s.mode = 2
		s.parameter_revision = s.programs[1].revision
		s.parameter_watch.has_attempted = false
		s.smoke_step = 1
		s.elapsed = 0
		return
	}
	if s.smoke_step == 1 {
		if waiting(s, s.programs[1].revision > s.parameter_revision, "Preview3D recompiled after retry") do return
		// 改写的图片由轮询或候选包提交重新载入；等 GPU 上确实是新内容，不按经过的时间推测。
		pixels := foster.TextureDownloadData(&p.textures[0])
		defer delete(pixels)
		if waiting(s, len(pixels) >= 4 && pixels[0] == 0 && pixels[2] == 255, "texture file refresh reaches GPU") do return
		// 接着检查录制式自定义预览：先记下材质效果 SpriteShadow 的内置预览，再让宿主记录自己的几何。
		for e, i in s.shaders {
			if e.desc.name == "SpriteShadow" do lab.select_shader(s.tool, i)
		}
		check(s, s.selected_shader >= 0 && s.shaders[s.selected_shader].desc.name == "SpriteShadow",
			"SpriteShadow material shader selected")
		s.smoke_step = 5
		return
	}
	if s.smoke_step == 5 {
		if waiting(s, preview_ready(s), "SpriteShadow built-in preview drawn") do return
		s.feature_builtin = scene_hash(s)
		s.preview_hooks = {s, feature_record}
		s.custom_preview = true
		s.smoke_step = 6
		return
	}
	if s.smoke_step == 6 {
		if waiting(s, s.feature_record > 0 && scene_hash(s) != s.feature_builtin, "host record callback replaces the built-in sprite") do return
		check(s, s.bank_error == "", fmt.tprintf("host-recorded preview draws: %s", s.bank_error))
		capture(s, "features-host")
		s.custom_preview = false
		// instanced 模型：管线探测与 Render3D 一样带实例缓冲，预览由 Render3D 自动实例化。
		for e, i in s.shaders {
			if e.desc.name == "Swarm" do lab.select_shader(s.tool, i)
		}
		check(s, s.selected_shader >= 0 && s.shaders[s.selected_shader].desc.name == "Swarm", "Swarm instanced shader selected")
		s.smoke_step = 7
		return
	}
	if s.smoke_step == 7 {
		ready := preview_ready(s) && s.shaders[s.selected_shader].ready && s.bank_error == ""
		if waiting(s, ready, "Swarm instanced model preview drawn") do return
		capture(s, "features-swarm")
		s.feature_template = 0
		s.smoke_step = 8
		return
	}
	// 新建着色器：每种模板写进隔离源码目录，等它编译、通过管线探测并被自动选中。
	if s.smoke_step == 8 {
		template := lab.Shader_Template(s.feature_template)
		_, base, _ := lab.template_source(template)
		if s.feature_template_written != s.feature_template + 1 {
			_, reason := lab.new_shader(s.tool, template)
			check(s, reason == "", fmt.tprintf("new %v shader written: %s", template, reason))
			s.feature_template_written = s.feature_template + 1
			return
		}
		e := s.selected_shader
		ready := e >= 0 && s.shaders[e].desc.name == base && s.shaders[e].ready && preview_ready(s) && s.bank_error == ""
		if waiting(s, ready, fmt.tprintf("new %v shader compiled and selected", template)) do return
		s.feature_template += 1
		if s.feature_template < len(lab.Shader_Template) do return
		capture(s, "features-new-shader")
		// 打开效果菜单看新建按钮（下一帧的输出里才有菜单）。
		s.shader_menu = true
		s.smoke_step = 9
		return
	}
	if s.smoke_step == 9 || s.smoke_step == 10 {
		s.smoke_step += 1
		return
	}
	if s.smoke_step == 11 {
		capture(s, "features-shader-menu")
		s.shader_menu = false
		// 新建的模板排在两个预览之前，参数组下标变了：按名字回到 Preview3D 再检查分隔条与紧凑布局。
		for e, i in s.shaders {
			if e.desc.name == "Preview3D" do lab.select_shader(s.tool, i)
		}
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
		inject_move(s, app, {
			(s.region.X+380)*f32(logical.X)/f32(pixels.X),
			(s.region.Y+160)*f32(logical.Y)/f32(pixels.Y)})
	case 4:
		release_pointer(s, app)
	case 6:
		check(s, s.sidebar_width > 340 && scene_texture(s).Width == int(s.viewport.Width), "splitter updates viewport and Pass target")
		press_widget(s, app, "toggle-sidebar", 0.5)
	case 8:
		release_pointer(s, app)
	case 12:
		check(s, s.sidebar_collapsed && s.viewport.X == 8, "collapsed inspector expands preview")
		resize_window(s, app, {540, 640})
	case 16:
		// 按钮位置取自最近一次布局，必须是新尺寸下的布局。
		if waiting(s, resized(s, app), "window resize applied") {
			s.capture_index -= 1
			return
		}
		press_widget(s, app, "toggle-sidebar", 0.5)
	case 18:
		release_pointer(s, app)
	case 22:
		check(s, s.compact && !s.sidebar_collapsed && s.viewport.X == 8, "small panel uses overlay inspector")
		capture(s, "features-compact")
		finish(s, app, "PASS: presets/defaults/rollback, stale file request, texture reload, custom preview, splitter/collapse/compact")
	}
}
