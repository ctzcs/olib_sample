package main

// 两个模型共用 Shader/Effect，分别持有 Material 实例。无 shaderdev 或 Shader Lab 依赖。
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:time"
import SDL "vendor:sdl3"
import dasset "olib:core/dasset"
import foster "olib:foster"
import profiler "olib:core/profiler"
import r2d "olib:kit/rendering/2d"
import r3d "olib:kit/rendering/3d"
import mat "olib:kit/rendering/material"
import perf "olib:kit/tools/perf_overlay"
import world "olib:kit/world"

import fonts "../../shared/msdf_font"

State :: struct {
	resources: foster.StorageContainer,
	materials: mat.Material_Library,
	materials_shown: [2]^mat.Material, // 同一网格、同一材质文件的两份实例：右边改了 hue
	mesh: foster.Mesh,
	target, inset: foster.Target,
	renderer: r3d.Render3D,
	views, automatic: bool,
	submit_sum: f64,
	measured_frames, draw_calls, submitted_instances: int,
	batch: r2d.Render2D,
	camera: world.Camera3D,
	// 轨道相机：左键拖动旋转，右键/中键拖动平移，滚轮缩放，F 复位；切换 swarm 时按场景尺度复位。
	yaw, pitch, distance: f32,
	focus: [3]f32,
	mouse_last: [2]f32,
	time: f32,
	outline: bool,
	grouped: bool,
	path: string,
	failed: bool,
	// 实例化演示：参数 swarm（可加 count=N）启动即开，按 I 切换；参数 shot 写一张截图后退出。
	swarm: Swarm,
	swarm_on: bool,
	swarm_count: int,
	shot: bool,
	frame: int,
	delta_sum: f64, // shot 模式下统计平均帧时间，含帧率限制
	cpu_sum: f64, // shot 模式下 render 过程的 CPU 耗时之和（秒）
	// 性能对比参数：immediate 不限帧并关闭垂直同步（帧时间仍不是 GPU 时间）；back 把远处实例排在前面（最差情况）；
	// rings= / segments= 球体精度；samples=1|2|4 MSAA。
	immediate, back: bool,
	rings, segments: int,
	samples: foster.SampleCount,
	perf: perf.Overlay, // olib 悬浮性能面板，P 切换；只画到窗口，不进 shot 截图
	font: foster.MsdfFont, // 面板借用的 MSDF 字体
	font_texture: foster.Texture,
}

main :: proc() {
	s := new(State)
	defer free(s)
	s.outline = true
	s.grouped = true
	// 从 Shader Lab “保存材质”得到的文件；R 重新载入到左侧模型，右侧保持独立。
	s.path = #directory + "/material.json"
	s.swarm_count = SWARM_DEFAULT_COUNT
	s.rings, s.segments, s.samples = 2, 4, .Four // 百万个只有几像素的球体：低模足够
	count_requested := false
	for arg in os.args[1:] {
		switch {
		case arg == "swarm": s.swarm_on = true
		case arg == "models":
			s.swarm_on = true
			s.automatic = true
		case arg == "views": s.views = true
		case arg == "shot": s.shot = true
		case arg == "immediate": s.immediate = true
		case arg == "back": s.back = true
		case len(arg) > 6 && arg[:6] == "rings=":
			value, ok := strconv.parse_int(arg[6:])
			if ok && value > 0 do s.rings = value
		case len(arg) > 9 && arg[:9] == "segments=":
			value, ok := strconv.parse_int(arg[9:])
			if ok && value > 2 do s.segments = value
		case len(arg) > 8 && arg[:8] == "samples=":
			value, ok := strconv.parse_int(arg[8:])
			if ok do s.samples = value == 1 ? .One : value == 2 ? .Two : .Four
		case len(arg) > 6 && arg[:6] == "count=":
			value, ok := strconv.parse_int(arg[6:])
			if ok && value > 0 {
				s.swarm_count = value
				count_requested = true
			}
		case: s.path = arg
		}
	}
	if s.automatic && !count_requested do s.swarm_count = 4096
	absolute, path_error := filepath.abs(s.path)
	if path_error != nil do os.exit(1)
	defer delete(absolute)
	s.resources.Root = filepath.dir(absolute)
	s.path = filepath.base(absolute)
	app: foster.App
	config := foster.DefaultAppConfig("Material3D | Drag: orbit/pan | Wheel: zoom | F: reset view | P: perf | G: passes | Space: outline | I: swarm | V: second view | R: reload left | Esc", 1100, 720)
	if s.immediate do config.UpdateMode = foster.UnlockedStep() // 不限帧；GPU 耗时需要单独的时间戳测量
	foster.InitApp(&app, config)
	foster.AppSetUserData(&app, s)
	app.StartupProc, app.UpdateProc, app.RenderProc, app.ShutdownProc = startup, update, render, shutdown
	foster.Run(&app)
	foster.Dispose(&app)
	delete(app.GraphicsDevice.WindowRenderTarget.Attachments)
	if s.failed do os.exit(1)
}

fail :: proc(app: ^foster.App, reason: string) {
	fmt.eprintln(reason)
	foster.AppGetUserDataAs(app, State).failed = true
	foster.Exit(app)
}

startup :: proc(app: ^foster.App) {
	s := foster.AppGetUserDataAs(app, State)
	device := &app.GraphicsDevice
	s.materials = {device = device, storage = &s.resources}
	// 登记 Shader Lab 产物目录里的材质效果（本例用 Outlined 与 Swarm）；只供预览的效果自动跳过。
	if reason := mat.material_register_directory(&s.materials, #load_directory("../shader_lab/shaders/Compiled")); reason != "" {
		fail(app, reason)
		return
	}
	for &material in s.materials_shown {
		reason: string
		material, reason = mat.material_load(&s.materials, s.path)
		if reason != "" {
			fail(app, reason)
			return
		}
	}
	_ = mat.material_set_number(s.materials_shown[1], "Outlined_body", "hue", {0.7, 0, 0, 0})
	primitive := sphere()
	defer delete(primitive.vertices)
	defer delete(primitive.indices)
	if !r3d.mesh_upload(&s.mesh, device, &primitive) {
		fail(app, "Cannot upload model")
		return
	}
	if s.immediate { _ = SDL.SetGPUSwapchainParameters(device.Device, app.Window.Handle, .SDR, .IMMEDIATE) }
	assert(r2d.init(&s.batch, &s.materials) == "")
	profiler.profile_init() // update / render 等作用域会列在面板里
	if font, texture, ok := fonts.load(device); ok {
		s.font, s.font_texture = font, texture
		s.perf.corner = .Top_Right
		s.perf.visible = perf.init(&s.perf, device, &s.font, s.font_texture)
	}
	assert(r3d.init(&s.renderer, &s.materials) == "")
	world.camera3d_init(&s.camera, 1100, 720)
	if s.swarm_on {
		if reason := swarm_init(s, device, s.swarm_count); reason != "" {
			fail(app, reason)
			return
		}
		fmt.printf("Swarm: %d instances\n", s.swarm.count)
	}
	camera_reset(s)
}

// 默认视角：两个球体从 (0, 1.2, 6) 看向原点；swarm 按立方体边长等比后退。
camera_reset :: proc(s: ^State) {
	height, back := f32(1.2), f32(6)
	if s.swarm_on {
		factor := max(0.04, math.ceil(math.pow(f32(s.swarm.count), 1.0/3.0)) / 100)
		height, back = 25*factor, 85*factor
	}
	s.yaw, s.pitch = 0, math.atan2(height, back)
	s.distance = math.sqrt(height*height + back*back)
	s.focus = {}
}

camera_input :: proc(s: ^State, mouse: ^foster.MouseState) {
	position := [2]f32{mouse.Position.X, mouse.Position.Y}
	delta := position - s.mouse_last // 自己求差：一帧多个移动事件时 Mouse.Delta 只保留最后一个
	s.mouse_last = position
	if foster.MouseLeftDown(mouse) {
		s.yaw -= delta.x * 0.006
		s.pitch = math.clamp(s.pitch + delta.y*0.006, -1.5, 1.5)
	}
	if foster.MouseRightDown(mouse) || foster.MouseMiddleDown(mouse) {
		// 沿屏幕方向平移焦点，速度随距离缩放。
		forward := world.camera3d_forward(&s.camera)
		right := world.camera3d_right(&s.camera)
		up := linalg.cross(right, forward)
		s.focus += (up*delta.y - right*delta.x) * (s.distance * 0.0015)
	}
	if mouse.Wheel.Y != 0 do s.distance = math.clamp(s.distance*math.pow(f32(0.88), mouse.Wheel.Y), 0.3, 2000)
}

update :: proc(app: ^foster.App) {
	profiler.profile_scope("update")
	s := foster.AppGetUserDataAs(app, State)
	s.time += f32(app.Time.Delta)
	keys := &app.Input.State.Keyboard
	if foster.KeyboardPressed(keys, .Escape) do foster.Exit(app)
	if foster.KeyboardPressed(keys, .Space) do s.outline = !s.outline
	if foster.KeyboardPressed(keys, .G) do s.grouped = !s.grouped
	if foster.KeyboardPressed(keys, .V) do s.views = !s.views
	if foster.KeyboardPressed(keys, .F) do camera_reset(s)
	if foster.KeyboardPressed(keys, .P) do s.perf.visible = !s.perf.visible
	perf.frame(&s.perf, f32(app.Time.Delta)) // 隐藏时也记录，打开时历史完整
	camera_input(s, &app.Input.State.Mouse)
	if foster.KeyboardPressed(keys, .I) {
		s.swarm_on = !s.swarm_on
		if s.swarm_on && !s.swarm.ready {
			if reason := swarm_init(s, &app.GraphicsDevice, s.swarm_count); reason != "" {
				fail(app, reason)
				return
			}
			fmt.printf("Swarm: %d instances\n", s.swarm.count)
		}
		camera_reset(s)
	}
	if foster.KeyboardPressed(keys, .R) {
		r3d.clear(&s.renderer) // 重载前释放对材质资源的借用
		if reason := mat.material_reload(&s.materials, s.materials_shown[0]); reason != "" {
			fmt.eprintln(reason)
		}
	}
}

render :: proc(app: ^foster.App) {
	profiler.profile_scope("render")
	s := foster.AppGetUserDataAs(app, State)
	if s.failed do return
	start := time.tick_now()
	device := &app.GraphicsDevice
	window := foster.DrawableTargetFromWindow(&app.Window)
	w, h := window.WidthInPixels, window.HeightInPixels
	if s.target.Width != w || s.target.Height != h {
		foster.TargetDispose(&s.target)
		foster.TargetInit(&s.target, device, w, h,
			[]foster.TargetAttachmentSpec{{.Color, s.samples}, {.Depth32, s.samples}}, "model material")
	}
	target := foster.DrawableTargetFromTarget(&s.target)
	colors := [1]foster.Color{{31,38,51,255}}
	foster.GraphicsDeviceClear(device, target, colors[:], 1, 0, foster.ClearMask.Color | foster.ClearMask.Depth)
	world.camera3d_set_viewport(&s.camera, w, h)
	orbit := [3]f32{math.sin(s.yaw)*math.cos(s.pitch), math.sin(s.pitch), math.cos(s.yaw)*math.cos(s.pitch)}
	world.camera3d_set_target(&s.camera, s.focus)
	world.camera3d_set_position(&s.camera, s.focus + orbit*s.distance)
	world.camera3d_set_far_clip(&s.camera, max(250, s.distance*3)) // 拉远时整群仍在远裁剪面内
	view := r3d.View{target = target, view_projection = world.camera3d_view_projection(&s.camera),
		view_matrix = world.camera3d_view(&s.camera), time = s.shot ? 0.8 : s.time}
	r3d.clear(&s.renderer)
	s.draw_calls = 0
	s.submitted_instances = 0
	if s.swarm_on {
		error: mat.Draw_Error
		if s.automatic {
			// model 与 models 共用同一 instanced 材质，也会合成一批。
			// 平铺数组每个实例连续 slots 个 float4（hue、motion）；首个实例单独用 model 记录。
			slots := mat.instance_slot_count(s.swarm.material)
			values := mat.Instance_Values{count = slots, set = 1 << u32(slots) - 1}
			copy(values.numbers[:slots], s.swarm.values[:slots])
			error = r3d.model(&s.renderer, &s.swarm.mesh, s.swarm.material,
				s.swarm.items[0].world, &s.swarm.local_bounds, &values)
			if error == .None {
				error = r3d.models(&s.renderer, &s.swarm.mesh, s.swarm.material,
					s.swarm.items[1:], &s.swarm.local_bounds, s.swarm.values[slots:])
			}
		} else {
			error = r3d.buffer(&s.renderer, &s.swarm.mesh, s.swarm.material,
				&s.swarm.instances, s.swarm.count, &s.swarm.bounds)
		}
		if error != .None {
			fail(app, mat.draw_error_text(error))
			return
		}
	} else {
		bounds := dasset.Dasset_Bounds{min = {-1.1, -1.1, -1.1}, max = {1.1, 1.1, 1.1}} // 含描边扩张
		for material, i in s.materials_shown {
			transform := world.matrix4_translation(i == 0 ? -1.25 : 1.25, 0, 0)
			if error := r3d.model(&s.renderer, &s.mesh, material, transform, &bounds); error != .None {
				fail(app, mat.draw_error_text(error))
				return
			}
		}
	}
	if s.views && !s.swarm_on {
		r3d.grid(&s.renderer, 4, 1, {0.6, 0.7, 0.8, 0.4})
		if s.inset.Width != w/3 || s.inset.Height != h/3 {
			foster.TargetDispose(&s.inset)
			foster.TargetInit(&s.inset, device, w/3, h/3,
				[]foster.TargetAttachmentSpec{{.Color, s.samples}, {.Depth32, s.samples}}, "second view")
		}
		secondary := s.camera
		world.camera3d_set_viewport(&secondary, w/3, h/3)
		world.camera3d_set_position(&secondary, {-3, 1.5, 3})
		other := r3d.View{target = foster.DrawableTargetFromTarget(&s.inset),
			view_projection = world.camera3d_view_projection(&secondary),
			view_matrix = world.camera3d_view(&secondary), time = view.time, draw_debug = false}
		foster.GraphicsDeviceClear(device, other.target, colors[:], 1, 0, foster.ClearMask.Color | foster.ClearMask.Depth)
		// 同一份记录先提交不同相机的 body，再提交主视图的 body/outline。
		if !submit_scene(app, other, "body") do return
	}
	pass_id := s.grouped || !s.outline || s.swarm_on ? mat.Pass_Id("body") : ""
	view.draw_debug = !(s.grouped && s.outline && !s.swarm_on)
	if !submit_scene(app, view, pass_id) do return
	if s.grouped && s.outline && !s.swarm_on {
		view.draw_debug = true
		if !submit_scene(app, view, "outline") do return
	}
	// 合成在最终像素尺寸进行；截图包含最终合成结果。
	if s.views && !s.swarm_on {
		iw, ih := f32(s.inset.Width), f32(s.inset.Height)
		r2d.quad_texture(&s.batch, foster.TargetAttachment(&s.inset),
			{16,16}, {16+iw,16}, {16+iw,16+ih}, {16,16+ih},
			{0,0}, {1,0}, {1,1}, {0,1}, foster.White)
		r2d.submit(&s.batch, {target = target})
	}
	r2d.quad_texture(&s.batch, foster.TargetAttachment(&s.target),
		{0,0}, {f32(w),0}, {f32(w),f32(h)}, {0,f32(h)}, {0,0},{1,0},{1,1},{0,1}, foster.White)
	r2d.submit(&s.batch, {target = window})
	// 面板只画到窗口，不进 shot 截图（截图读的是离屏目标）。
	perf.draw(&s.perf, window, f32(w)/f32(max(1, foster.Size(&app.Window).X)))
	if s.shot && s.frame >= 10 {
		s.cpu_sum += time.duration_seconds(time.tick_diff(start, time.tick_now()))
		s.delta_sum += f64(app.Time.Delta)
		s.measured_frames += 1
	}
	if s.shot {
		s.frame += 1
		if s.frame == 130 {
			n := f64(s.measured_frames)
			fmt.printf("Model draws: %d, submitted instances (all passes): %d; frame %.3f ms, render CPU %.3f ms, submit CPU %.3f ms (%d frames); GPU not measured\n",
				s.draw_calls, s.submitted_instances, s.delta_sum*1000/n, s.cpu_sum*1000/n, s.submit_sum*1000/n, s.measured_frames)
			save_capture(s)
			foster.Exit(app)
		}
	}
}

submit_scene :: proc(app: ^foster.App, view: r3d.View, pass_id: mat.Pass_Id) -> bool {
	profiler.profile_scope("r3d.submit")
	s := foster.AppGetUserDataAs(app, State)
	start := time.tick_now()
	error := r3d.submit(&s.renderer, view, pass_id)
	if s.shot && s.frame >= 10 do s.submit_sum += time.duration_seconds(time.tick_diff(start, time.tick_now()))
	if error != .None {
		fail(app, mat.draw_error_text(error))
		return false
	}
	s.draw_calls += s.renderer.draw_calls
	s.submitted_instances += s.renderer.instances
	return true
}

// 读回离屏目标并写到 library/screenshots（相对示例仓库根）。
save_capture :: proc(s: ^State) {
	bytes := foster.TextureDownloadData(foster.TargetAttachment(&s.target, 0))
	defer delete(bytes)
	w, h := s.target.Width, s.target.Height
	image := foster.ImageMake(w, h)
	defer foster.ImageDispose(&image)
	if len(bytes) < w*h*4 {
		fmt.eprintln("Capture readback failed")
		return
	}
	for &pixel, i in image.Pixels do pixel = {bytes[i*4], bytes[i*4+1], bytes[i*4+2], bytes[i*4+3]}
	directory :: #directory + "../../library/screenshots"
	_ = os.make_directory_all(directory)
	name := s.automatic ? "material3d_models.png" : s.swarm_on ? "material3d_swarm.png" : s.views ? "material3d_views.png" : "material3d.png"
	fmt.println(name, foster.ImageWritePng(&image, fmt.tprintf("%s/%s", directory, name)))
}

shutdown :: proc(app: ^foster.App) {
	s := foster.AppGetUserDataAs(app, State)
	r3d.dispose(&s.renderer)
	swarm_dispose(s)
	perf.dispose(&s.perf) // 先释放面板，再释放它借用的字体
	if s.font_texture.Resource != nil do foster.TextureDispose(&s.font_texture)
	foster.MsdfFontDispose(&s.font)
	delete(profiler.profile_stats)
	r2d.dispose(&s.batch)
	mat.material_library_dispose(&s.materials)
	foster.MeshDispose(&s.mesh)
	foster.TargetDispose(&s.target)
	foster.TargetDispose(&s.inset)
}

sphere :: proc(rings := 48, segments := 64) -> dasset.Dasset_Primitive {
	p := dasset.Dasset_Primitive{vertices = make([]dasset.Dasset_Vertex, (rings+1)*(segments+1)), indices = make([]u32, rings*segments*6)}
	for r in 0..=rings do for n in 0..=segments {
		theta, phi := f32(r)/f32(rings)*math.PI, f32(n)/f32(segments)*2*math.PI
		normal := [3]f32{math.sin(theta)*math.cos(phi), math.cos(theta), math.sin(theta)*math.sin(phi)}
		p.vertices[r*(segments+1)+n] = {position = normal, normal = normal, uv = {f32(n)/f32(segments),f32(r)/f32(rings)}, tangent = {-math.sin(phi),0,math.cos(phi),1}}
	}
	for r in 0..<rings do for n in 0..<segments {
		a := u32(r*(segments+1)+n)
		seg := u32(segments)
		copy(p.indices[(r*segments+n)*6:], []u32{a,a+1,a+seg+2,a,a+seg+2,a+seg+1})
	}
	return p
}
