package shader_lab_checks

// 自动验收仅修改独立临时源码；不接触用户正在编辑的文件。
import "core:fmt"
import "core:os"
import "core:strings"

import foster "olib:foster"
import lab "olib:kit/tools/shader_lab"
import clay "olib:thirdparty/clay-odin"
import SDL "vendor:sdl3"

prepare_smoke :: proc(s: ^State) -> bool {
	root, err := os.make_directory_temp("", "olib_shader_lab_*", context.allocator)
	if err != nil {
		s.failed = true
		return false
	}
	s.temp_root = root
	// 纯 shot 额外带上 2D 材质效果，最后一步截它的材质预览；其他验证模式保持原来的两组 Shader。
	names := []string{"Preview2D.oshader", "Preview3D.oshader", "Palette.hlsli"}
	if s.shot && !s.smoke do names = {"Preview2D.oshader", "Preview3D.oshader", "Palette.hlsli", "SpriteShadow.oshader"}
	// features 额外带上 2D 材质效果 SpriteShadow（录制式自定义预览）和 instanced 模型 Swarm；它们排在两个预览之后，参数组下标不变。
	if s.features do names = {"Preview2D.oshader", "Preview3D.oshader", "Palette.hlsli", "SpriteShadow.oshader", "Swarm.oshader"}
	for name in names {
		bytes, err := os.read_entire_file(fmt.tprintf("%s/%s", s.source_root, name), context.temp_allocator)
		if err != nil || os.write_entire_file(fmt.tprintf("%s/%s", root, name), bytes) != nil do return false
	}
	s.source_root = s.temp_root
	return true
}

cleanup_smoke :: proc(s: ^State) {
	if s.temp_root == "" || s.failed do return
	for name in ([]string{"Preview2D.oshader", "Preview3D.oshader", "Trail2D.oshader", "Trail3D.oshader", "Palette.hlsli", "SpriteShadow.oshader", "Extra.oshader", "red.png", "feature-preset.json", "feature-bad.json", "feature.png"}) {
		_ = os.remove(fmt.tprintf("%s/%s", s.temp_root, name))
	}
	_ = os.remove(s.temp_root)
	delete(s.temp_root)
}

check :: proc(s: ^State, condition: bool, message: string) {
	if !condition {
		s.failed = true
		fmt.eprintln("FAIL:", message)
		report_failure(s, message)
	}
}

// 检出可能是 CRLF（core.autocrlf）；夹具按源码自身的换行改写。
fixture_newline :: proc(text: string) -> string {
	return strings.contains(text, "\r\n") ? "\r\n" : "\n"
}

// 锚点缺失立即失败，不拖到等待超时。
fixture_replace :: proc(s: ^State, text, anchor, replacement: string) -> string {
	newline := fixture_newline(text)
	from, _ := strings.replace_all(anchor, "\n", newline, context.temp_allocator)
	to, _ := strings.replace_all(replacement, "\n", newline, context.temp_allocator)
	check(s, strings.contains(text, from), fmt.tprintf("fixture contains %q", anchor))
	result, _ := strings.replace_all(text, from, to, context.temp_allocator)
	return result
}

// 候选包已提交，选中效果的目标与 Shader 已就绪并在最近一次渲染里画出。
preview_ready :: proc(s: ^State) -> bool {
	return s.program_count >= 2 && s.pending_bank == nil && s.selected_shader >= 0 && s.shaders[s.selected_shader].ready
}

scene_hash :: proc(s: ^State) -> u64 {
	texture := scene_texture(s)
	if texture == nil do return 0
	bytes := foster.TextureDownloadData(texture)
	defer delete(bytes)
	hash: u64 = 1469598103934665603
	for b in bytes do hash = (hash ~ u64(b))*1099511628211
	return hash
}

scene_texture :: proc(s: ^State) -> ^foster.Texture {
	if s.selected_shader >= 0 {
		e := &s.shaders[s.selected_shader]
		for p, i in e.desc.passes {
			if (s.preview_pass < 0 && p.output == e.desc.output) || s.preview_pass == i {
				target := &e.targets[i]
				return foster.TargetAttachment(&target.buffers[target.history ? e.current : 0])
			}
		}
	}
	return nil
}

select_parameter_shader :: proc(s: ^State, parameter: int) {
	for e, i in s.shaders {
		if len(e.desc.passes) != 1 || string(e.desc.passes[0].params) != s.parameters[parameter].name do continue
		lab.select_shader(s.tool, i)
		return
	}
	check(s, false, "parameter has a single-Pass shader")
}

capture :: proc(s: ^State, label: string) {
	bytes := foster.TextureDownloadData(foster.TargetAttachment(&s.output))
	defer delete(bytes)
	check(s, len(bytes) == s.output.Width*s.output.Height*4, "final output readback")
	if len(bytes) != s.output.Width*s.output.Height*4 do return
	image := foster.ImageMake(s.output.Width, s.output.Height)
	defer foster.ImageDispose(&image)
	for &pixel, i in image.Pixels do pixel = {bytes[i*4], bytes[i*4+1], bytes[i*4+2], bytes[i*4+3]}
	_ = os.make_directory_all(#directory + "/../../library/screenshots")
	path := fmt.tprintf("%s/../../library/screenshots/shader-lab-%s-%dx%d.png", #directory, label, image.Width, image.Height)
	check(s, foster.ImageWritePng(&image, path), "PNG write")
	fmt.println(path)
}

validate_frame :: proc(s: ^State, app: ^foster.App) {
	if s.render_serial == s.validated_serial do return
	s.validated_serial = s.render_serial
	if s.failed {
		foster.Exit(app)
		return
	}
	// 注入的输入要等一次渲染真正消费后再推进，后面的检查才看得到 UI 的结果。
	if waiting(s, !s.input_pending, "injected input reaches the UI") do return
	if s.targets {
		validate_targets(s, app)
		return
	}
	if s.hierarchy {
		validate_hierarchy(s, app)
		return
	}
	if s.multipass {
		validate_multipass(s, app)
		return
	}
	if s.features {
		validate_features(s, app)
		return
	}
	if s.color_smoke {
		validate_color_frame(s, app)
		return
	}
	if s.material_step > 0 {
		// shot 最后一步进行中：只等材质预览，不再走前面的模式截图。
		if shot_material_sprite(s) do finish(s, app)
		return
	}
	if s.smoke_step == 0 {
		if waiting(s, preview_ready(s), "bank committed and selected shader drawn") do return
		// 每个模式连续两帧，确保录下的确实是切换后的实际绘制。
		if s.capture_index%2 == 1 {
			names := [4]string{"fullscreen", "sprite", "sphere", "cube"}
			capture(s, names[s.mode])
			if s.mode == 0 do s.initial_2d_pixels = scene_hash(s)
			if s.mode < 3 do s.mode += 1
			select_parameter_shader(s, s.mode < 2 ? 0 : 1)
		}
		s.capture_index += 1
		if s.capture_index < 8 do return
		if !s.smoke {
			if shot_material_sprite(s) do finish(s, app)
			return
		}
		s.initial_pixels = scene_hash(s)
		for &program, i in s.programs[:2] {
			s.initial_resources[i] = rawptr(program.fragment.Resource)
			old_vertex := program.vertex.Resource
			old_fragment := program.fragment.Resource
			invalid_probe := [1]foster.DrawCommand{{}}
			ok, _ := foster.ShaderPairTryReplace(&program.vertex, &program.fragment,
				&app.GraphicsDevice, program.vertex.CreateInfo, program.fragment.CreateInfo, invalid_probe[:])
			check(s, !ok && program.vertex.Resource == old_vertex &&
				program.fragment.Resource == old_fragment, "failed pipeline keeps both stages")
		}
		check(s, os.write_entire_file(fmt.tprintf("%s/Palette.hlsli", s.temp_root),
			string("this is intentionally invalid HLSL;")) == nil, "write bad include")
		s.smoke_step = 1
	} else if s.smoke_step == 1 {
		if s.pending_bank == nil || s.bank_error == "" do return
		for &program, i in s.programs[:2] {
			check(s, program.revision == 1 && rawptr(program.fragment.Resource) == s.initial_resources[i],
				"compile failure retains previous shader")
		}
		check(s, scene_hash(s) == s.initial_pixels, "compile failure retains identical scene pixels")
		capture(s, "compile-error")
		fixed := "float3 palette(float phase) { return float3(0.1, 0.8, 0.35) + phase * 0.01; }"
		check(s, os.write_entire_file(fmt.tprintf("%s/Palette.hlsli", s.temp_root),
			transmute([]u8)fixed) == nil, "repair shared include")
		s.smoke_step = 2
	} else if s.smoke_step == 2 {
		if s.pending_bank != nil || s.programs[1].revision < 2 do return
		check(s, scene_hash(s) != s.initial_pixels, "valid include visibly updates scene")
		check(s, s.clock == 1 && s.yaw == 0.4 && lab.parameter_number(s.tool, 0, "hue") == 0.15 && lab.parameter_number(s.tool, 1, "hue") == 0.15,
			"reload preserves time, camera and parameters")
		capture(s, "recovered")
		select_parameter_shader(s, 0)
		s.mode = 0
		s.smoke_step = 20
	} else if s.smoke_step == 20 {
		if s.programs[0].revision < 2 do return
		check(s, scene_hash(s) != s.initial_2d_pixels, "valid include visibly updates 2D scene")
		capture(s, "recovered-2d")
		path := fmt.tprintf("%s/Preview2D.oshader", s.temp_root)
		bytes, _ := os.read_entire_file(path, context.temp_allocator)
		s.binding_source = strings.clone(string(bytes))
		modified := fixture_replace(s, string(bytes), "color *= lerp", "color *= Extra; color *= lerp")
		text := fixture_replace(s, modified, "HLSLPROGRAM", "HLSLPROGRAM\ncbuffer ExtraBlock : register(b2, space3) { float Extra; };")
		check(s, os.write_entire_file(path, transmute([]u8)text) == nil, "change binding contract")
		s.smoke_step = 3
	} else if s.smoke_step == 3 {
		if s.pending_bank == nil || s.bank_error == "" do return
		check(s, s.programs[0].revision == 2 && strings.contains(s.bank_error, "bindings changed"),
			"binding changes rejected before GPU replacement")
		check(s, os.write_entire_file(fmt.tprintf("%s/Preview2D.oshader", s.source_root), s.binding_source) == nil, "restore binding contract")
		s.smoke_step = 4
		s.capture_index = 0
		lab.select_workspace(s.tool, 0)
		s.shader_menu = true
	} else if s.smoke_step == 4 {
		if s.pending_bank != nil || s.elapsed < s.feature_next do return
		s.feature_next = s.elapsed+0.06
		switch s.capture_index {
		case 0:
			press_widget(s, app, "shader:Preview2D", 0.5)
		case 2, 6:
			release_pointer(s, app)
		case 4:
			check(s, s.mode == 0, "Shader selection uses real UI input")
			press_widget(s, app, "Preview2D_main:strength", 0.9)
		case 8:
			check(s, lab.parameter_number(s.tool, 0, "strength") > 0.8 && lab.parameter_number(s.tool, 1, "strength") == 0.65 && s.yaw == 0.4,
				"slider changes only active preview and does not orbit camera")
			resize_window(s, app, {1100, 825})
		case 12:
			if waiting(s, resized(s, app), "window resize applied") do return
			check(s, s.output.Width == 1100 && s.output.Height == 825, "resize uses native output pixels")
			capture(s, "resized")
			select_parameter_shader(s, 1)
			s.mode = 3
			s.smoke_step = 5
			s.capture_index = -1
		}
		s.capture_index += 1
	} else if s.smoke_step == 5 {
		if s.pending_bank != nil do return
		// 切到 Preview3D 后下一次渲染才按新尺寸分配目标并画出；ready 即表示那次渲染已画出。
		drawn := s.selected_shader >= 0 && s.shaders[s.selected_shader].desc.name == "Preview3D" && s.shaders[s.selected_shader].ready
		if waiting(s, drawn, "Preview3D drawn at the resized output") do return
		s.initial_pixels = scene_hash(s)
		s.parameter_revision = s.programs[1].revision
		path := fmt.tprintf("%s/Preview3D.oshader", s.source_root)
		bytes, _ := os.read_entire_file(path, context.temp_allocator)
		s.parameter_source = strings.clone(string(bytes))
		bad := fixture_replace(s, s.parameter_source, "Range(0,5)", "Range(0,invalid)")
		check(s, os.write_entire_file(path, bad) == nil, "write bad property declaration")
		s.smoke_step = 6
	} else if s.smoke_step == 6 {
		if s.parameter_watch.status != .Error do return
		check(s, s.programs[1].revision == s.parameter_revision && scene_hash(s) == s.initial_pixels,
			"invalid property declaration keeps both schema and GPU pixels")
		capture(s, "parameter-error")
		text := fixture_replace(s, s.parameter_source, "Properties\n    {", "Properties\n    {\n        _gain (\"亮度\", Range(0,1)) = 0.5")
		text = fixture_replace(s, text, "return float4(color * light", "return float4(color * _gain * light")
		check(s, os.write_entire_file(fmt.tprintf("%s/Preview3D.oshader", s.source_root), text) == nil, "add property and consume it in HLSL atomically")
		s.smoke_step = 7
	} else if s.smoke_step == 7 {
		// 这次写入之后只有新声明的候选包；它编译失败就不会再出现 gain，直接报告而不是等到超时。
		if s.pending_bank != nil && s.pending_bank.candidate_failed {
			check(s, false, fmt.tprintf("candidate with the new property compiles: %s", s.bank_error))
			return
		}
		if s.parameters[1].has_pending || lab.parameter_number(s.tool, 1, "gain") != 0.5 do return
		check(s, s.programs[1].revision > s.parameter_revision && scene_hash(s) != s.initial_pixels,
			"new generated layout and default visibly update 3D")
		check(s, lab.parameter_number(s.tool, 1, "strength") == 0.65 && lab.parameter_number(s.tool, 1, "hue") == 0.15,
			"field reorder retains values by stable ID")
		capture(s, "parameter-recovered")
		p := &s.parameters[1]
		for f, i in p.live.fields {
			if f.kind != .Texture do continue
			lab.parameter_texture_set(s.tool, 1, i, "missing-image.png")
			check(s, p.values[i].texture == "" && p.textures[0].Resource == nil, "failed texture keeps previous binding")
			img := foster.ImageMake(4, 4)
			for &pixel in img.Pixels do pixel = {255, 0, 0, 255}
			check(s, foster.ImageWritePng(&img, fmt.tprintf("%s/red.png", s.temp_root)), "write test texture")
			foster.ImageDispose(&img)
			lab.parameter_texture_set(s.tool, 1, i, "red.png")
			check(s, p.values[i].texture == "red.png" && p.textures[0].Resource != nil, "texture replacement succeeds")
		}
		s.initial_pixels = scene_hash(s)
		s.parameter_revision = s.programs[1].revision
		s.smoke_step = 8
	} else if s.smoke_step == 8 {
		check(s, scene_hash(s) != s.initial_pixels && s.programs[1].revision == s.parameter_revision,
			"texture changes pixels without recompiling")
		text := `Shader "Extra" {
Properties { _amount ("Amount", Range(0,1)) = 0.75 }
Pass "main" {
Draw Preview_Model
HLSLPROGRAM
struct I {float2 p:TEXCOORD0; float2 uv:TEXCOORD1;};
struct O {float4 p:SV_Position;};
O vertex_main(I v) {O o; o.p=float4(v.p,0,1); return o;}
float4 fragment_main(O v):SV_Target0 {return float4(_amount,0.2,0.3,1);}
ENDHLSL
}}
`
		check(s, os.write_entire_file(fmt.tprintf("%s/Extra.oshader", s.source_root), text) == nil, "add third shader")
		s.smoke_step = 9
	} else if s.smoke_step == 9 {
		extra := lab.bank_index(s.bank, "Extra_main")
		if extra < 0 || s.pending_bank != nil do return
		check(s, s.parameters[extra].available, "discovers third shader without restarting")
		select_parameter_shader(s, extra)
		s.mode = 0
		s.smoke_step = 11
	} else if s.smoke_step == 11 {
		if !s.shaders[s.selected_shader].ready do return
		texture := scene_texture(s)
		pixels := foster.TextureDownloadData(texture)
		defer delete(pixels)
		pixel := (texture.Height/2*texture.Width+texture.Width/2)*4
		check(s, len(pixels) > pixel+3 && pixels[pixel] >= 189 && pixels[pixel] <= 193,
			"b1 parameter binds correctly even when b0 is unused")
		capture(s, "third-shader")
		check(s, os.remove(fmt.tprintf("%s/Extra.oshader", s.source_root)) == nil, "remove shader declaration")
		s.smoke_step = 10
	} else if s.smoke_step == 10 {
		if lab.bank_index(s.bank, "Extra_main") >= 0 do return
		capture(s, "parameter-texture")
		delete(s.parameter_source)
		s.parameter_source = ""
		finish(s, app, "PASS: 2D/3D reload, oshader parsing rollback/recovery, layout migration, textures, discovery, UI, resize")
	}
}

// 走完最后一步才算完成；没走到这里就退出（例如窗口被关掉）由 dispose 判为失败，不当作通过。
finish :: proc(s: ^State, app: ^foster.App, pass := "") {
	if !s.failed && pass != "" do fmt.println(pass)
	s.done = true
	foster.Exit(app)
}

press_widget :: proc(s: ^State, app: ^foster.App, id: string, fraction: f32) {
	data := clay.GetElementData(clay.ID(id))
	check(s, data.found, "widget exists")
	box := data.boundingBox
	size := foster.Size(&app.Window)
	pixels := foster.SizeInPixels(&app.Window)
	position := foster.Vec2f{(s.region.X + (box.x + box.width*fraction)*s.ui_scale)*f32(size.X)/f32(pixels.X),
		(s.region.Y + (box.y + box.height*0.5)*s.ui_scale)*f32(size.Y)/f32(pixels.Y)}
	inject_move(s, app, position)
	inject_button(s, app, true)
	log_event(s, "press %s", id)
}

release_pointer :: proc(s: ^State, app: ^foster.App) {
	inject_button(s, app, false)
}

// 验证只认注入的输入：真实鼠标键盘一直屏蔽，否则窗口弹出抢到焦点后桌面上的操作会混进自动点击。
// 指针先移到界面外，截图不随启动时的光标位置出现悬停高亮。
isolate_input :: proc(s: ^State, app: ^foster.App) {
	inject_move(s, app, {-1, -1})
	inject_button(s, app, false)
}

inject_move :: proc(s: ^State, app: ^foster.App, position: foster.Vec2f) {
	app.Input.Enabled = foster.InputEnabledAll
	foster.InputMouseMove(&app.Input, position, {}, app.Time.Elapsed)
	input_sent(s, app, fmt.tprintf("pointer %.1f,%.1f", position.X, position.Y))
}

inject_button :: proc(s: ^State, app: ^foster.App, down: bool) {
	app.Input.Enabled = foster.InputEnabledAll
	foster.InputMouseButton(&app.Input, .Left, down, app.Time.Elapsed)
	input_sent(s, app, down ? "left down" : "left up")
}

inject_key :: proc(s: ^State, app: ^foster.App, key: foster.Keys, down: bool) {
	app.Input.Enabled = foster.InputEnabledAll
	foster.InputKey(&app.Input, key, down, app.Time.Elapsed)
	input_sent(s, app, fmt.tprintf("key %v %s", key, down ? "down" : "up"))
	s.input_key_edge = down
	s.input_key = key
}

// 注入后继续屏蔽真实设备，并记下注入所在的 Update，input_track 据此判断何时被渲染消费。
@(private="file")
input_sent :: proc(s: ^State, app: ^foster.App, what: string) {
	app.Input.Enabled = foster.InputEnabledNone
	s.input_pending = true
	s.input_update = s.update_count
	s.input_applied = -1
	s.input_key_edge = false
	log_event(s, "inject %s", what)
}

// 每次 Update 开头调用。注入在下一次 Update 的 InputStep 进入 State，之后的渲染把它交给 UI；
// 一次渲染前可能跑多次 Update，所以不能按帧数推测。鼠标是电平，晚一帧也不会丢；
// 按键按下是边沿，只在进入 State 的那次 Update 内有效，渲染前又跑了一次 Update 就丢了，需要重发。
input_track :: proc(s: ^State, app: ^foster.App) {
	if !s.input_pending || s.update_count <= s.input_update do return
	if s.input_applied < 0 {
		s.input_applied = s.render_serial
	} else if s.render_serial > s.input_applied {
		s.input_pending = false
		log_event(s, "injected input consumed")
	} else if s.input_key_edge {
		inject_key(s, app, s.input_key, true)
	}
}

// 新尺寸在下一次渲染才用于输出、布局和 Pass 目标。
resize_window :: proc(s: ^State, app: ^foster.App, size: foster.Point2) {
	s.resize_to = size
	window_restore(s, app)
	foster.SetWindowSize(&app.Window, size)
	s.resize_serial = foster.Size(&app.Window) == size ? s.render_serial : -1
	log_event(s, "request window %dx%d", size.X, size.Y)
}

// 窗口达到请求尺寸后再经过一次渲染才算生效。
resized :: proc(s: ^State, app: ^foster.App) -> bool {
	if foster.Size(&app.Window) != s.resize_to {
		s.resize_serial = -1
		if window_restore(s, app) do foster.SetWindowSize(&app.Window, s.resize_to)
		return false
	}
	if s.resize_serial < 0 do s.resize_serial = s.render_serial
	return s.render_serial > s.resize_serial
}

// SDL 只在窗口处于普通状态时应用尺寸；检查运行时有人在用这台机器，弹出的窗口可能被最小化或最大化。
@(private="file")
window_restore :: proc(s: ^State, app: ^foster.App) -> bool {
	flags := SDL.GetWindowFlags(app.Window.Handle) & SDL.WindowFlags{.MINIMIZED, .MAXIMIZED}
	if flags == {} do return false
	_ = SDL.RestoreWindow(app.Window.Handle)
	log_event(s, "restore window from %v to apply the requested size", flags)
	return true
}

// Clay 元素哈希表保留历史布局；控件是否仍存在应看刚完成这一帧的交互列表。
widget_present :: proc(s: ^State, id: string) -> bool {
	key := clay.ID(id).id
	for widget in s.ctx.previous_widgets {
		if widget.id == key do return true
	}
	return false
}

// shot 的最后一步：切到 2D 材质效果 SpriteShadow（两个 Pass、带 [Instance] 字段），等它的 Shader 编译生效后截图，
// 确认材质预览（与游戏一样走 Render2D，字段走顶点 storage buffer）能编译、绑定并画出。返回 true 表示完成。
shot_material_sprite :: proc(s: ^State) -> bool {
	if s.material_step == 0 {
		index := -1
		for e, i in s.shaders {
			if e.desc.name == "SpriteShadow" do index = i
		}
		check(s, index >= 0, "SpriteShadow shader exists")
		if index < 0 do return true
		lab.select_shader(s.tool, index)
		s.material_step = 1
	}
	for p, i in s.parameters[:s.program_count] {
		if !strings.has_prefix(p.name, "SpriteShadow_") do continue
		check(s, s.programs[i].status != .Error, fmt.tprintf("%s compiles: %s", p.name, s.programs[i].diagnostic))
	}
	if s.failed do return true
	// 选中后的下一次渲染才分配目标、提交两个 Shader；ready 表示所用 Shader 已生效且那次渲染画出了预览。
	if waiting(s, s.shaders[s.selected_shader].ready, "SpriteShadow material preview drawn") do return false
	check(s, s.bank_error == "", fmt.tprintf("material preview binds: %s", s.bank_error))
	capture(s, "material-sprite")
	return true
}
