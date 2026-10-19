package main

// 两个模型共用 Shader/Effect，分别持有 Material 实例。无 shaderdev 或 Shader Lab 依赖。
import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:time"
import SDL "vendor:sdl3"
import dasset "olib:core/dasset"
import foster "olib:foster"
import r3d "olib:kit/rendering/3d"
import mat "olib:kit/rendering/material"
import world "olib:kit/world"

State :: struct {
	resources: foster.StorageContainer,
	materials: mat.Material_Library,
	models: [2]r3d.Model,
	mesh: foster.Mesh,
	target: foster.Target,
	batch: foster.Batcher,
	camera: world.Camera3D,
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
	delta_sum: f64, // shot 模式下统计平均帧时间
	cpu_sum: f64, // shot 模式下 render 过程的 CPU 耗时之和（秒）
	// 性能对比参数：immediate 不限帧并关闭垂直同步（测真实 GPU 耗时）；back 把远处实例排在前面（最差情况）；
	// rings= / segments= 球体精度；samples=1|2|4 MSAA。
	immediate, back: bool,
	rings, segments: int,
	samples: foster.SampleCount,
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
	for arg in os.args[1:] {
		switch {
		case arg == "swarm": s.swarm_on = true
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
			if ok && value > 0 do s.swarm_count = value
		case: s.path = arg
		}
	}
	absolute, path_error := filepath.abs(s.path)
	if path_error != nil do os.exit(1)
	defer delete(absolute)
	s.resources.Root = filepath.dir(absolute)
	s.path = filepath.base(absolute)
	app: foster.App
	config := foster.DefaultAppConfig("Material3D | G: grouped/object passes | Space: outline | I: swarm | R: reload left | Esc: exit", 1100, 720)
	if s.immediate do config.UpdateMode = foster.UnlockedStep() // 不限帧，配合 immediate 测真实 GPU 耗时
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
	if reason := register_materials(&s.materials); reason != "" {
		fail(app, reason)
		return
	}
	if reason := register_swarm(&s.materials); reason != "" {
		fail(app, reason)
		return
	}
	for &model in s.models {
		reason: string
		model.mesh = &s.mesh
		model.material, reason = mat.material_load(&s.materials, s.path)
		if reason != "" {
			fail(app, reason)
			return
		}
	}
	_ = mat.material_set_number(s.models[1].material, "Outlined_body", "hue", {0.7, 0, 0, 0})
	primitive := sphere()
	defer delete(primitive.vertices)
	defer delete(primitive.indices)
	if !r3d.mesh3d_upload(&s.mesh, device, &primitive) {
		fail(app, "Cannot upload model")
		return
	}
	if s.immediate { _ = SDL.SetGPUSwapchainParameters(device.Device, app.Window.Handle, .SDR, .IMMEDIATE) }
	foster.BatcherInit(&s.batch, device)
	world.camera3d_init(&s.camera, 1100, 720)
	world.camera3d_set_position(&s.camera, {0, 1.2, 6})
	if s.swarm_on {
		if reason := swarm_init(s, device, s.swarm_count); reason != "" {
			fail(app, reason)
			return
		}
		fmt.printf("Swarm: %d instances\n", s.swarm.count)
	}
}

update :: proc(app: ^foster.App) {
	s := foster.AppGetUserDataAs(app, State)
	s.time += f32(app.Time.Delta)
	if s.shot && s.frame > 10 do s.delta_sum += f64(app.Time.Delta)
	keys := &app.Input.State.Keyboard
	if foster.KeyboardPressed(keys, .Escape) do foster.Exit(app)
	if foster.KeyboardPressed(keys, .Space) do s.outline = !s.outline
	if foster.KeyboardPressed(keys, .G) do s.grouped = !s.grouped
	if foster.KeyboardPressed(keys, .I) {
		s.swarm_on = !s.swarm_on
		if s.swarm_on && !s.swarm.ready {
			if reason := swarm_init(s, &app.GraphicsDevice, s.swarm_count); reason != "" {
				fail(app, reason)
				return
			}
			fmt.printf("Swarm: %d instances\n", s.swarm.count)
		}
	}
	if foster.KeyboardPressed(keys, .R) {
		if reason := mat.material_reload(&s.materials, s.models[0].material); reason != "" {
			fmt.eprintln(reason)
		}
	}
}

render :: proc(app: ^foster.App) {
	s := foster.AppGetUserDataAs(app, State)
	if s.failed do return
	start := time.tick_now()
	defer if s.shot && s.frame > 10 do s.cpu_sum += time.duration_seconds(time.tick_diff(start, time.tick_now()))
	device := &app.GraphicsDevice
	window := foster.DrawableTargetFromWindow(&app.Window)
	w, h := window.WidthInPixels, window.HeightInPixels
	if s.target.Width != w || s.target.Height != h {
		foster.TargetDispose(&s.target)
		foster.TargetInit(&s.target, device, w, h, []foster.TargetAttachmentSpec{{.Color, s.samples}, {.Depth32, s.samples}}, "model material")
	}
	target := foster.DrawableTargetFromTarget(&s.target)
	colors := [1]foster.Color{{31,38,51,255}}
	foster.GraphicsDeviceClear(device, target, colors[:], 1, 0, foster.ClearMask.Color | foster.ClearMask.Depth)
	world.camera3d_set_viewport(&s.camera, w, h)
	view := r3d.Model_View{target = target, view_projection = world.camera3d_view_projection(&s.camera),
		time = s.time}
	if s.swarm_on {
		// 100 万实例只有一次 Draw；相机退到能看到整块阵列的位置。
		world.camera3d_set_position(&s.camera, {0, 25, 85})
		view.view_projection = world.camera3d_view_projection(&s.camera)
		if error := r3d.model_draw_buffer(s.swarm.model, &s.swarm.instances, s.swarm.count, view); error != .None {
			fail(app, mat.draw_error_text(error))
		}
	} else {
		world.camera3d_set_position(&s.camera, {0, 1.2, 6})
		view.view_projection = world.camera3d_view_projection(&s.camera)
	}
	for model, i in s.models {
		if s.swarm_on do break
		transform := world.matrix4_translation(i == 0 ? -1.25 : 1.25, 0, 0)
		pass_id := s.grouped || !s.outline ? mat.Pass_Id("body") : ""
		error := r3d.model_draw(model, transform, view, pass_id)
		if error != .None {
			fail(app, mat.draw_error_text(error))
		}
	}
	if s.grouped && s.outline && !s.swarm_on {
		for model, i in s.models {
			transform := world.matrix4_translation(i == 0 ? -1.25 : 1.25, 0, 0)
			if error := r3d.model_draw(model, transform, view, "outline"); error != .None {
				fail(app, mat.draw_error_text(error))
			}
		}
	}
	foster.BatcherClear(&s.batch)
	foster.BatcherQuadTexture(&s.batch, foster.TargetAttachment(&s.target), {0,0}, {f32(w),0}, {f32(w),f32(h)}, {0,f32(h)}, {0,0},{1,0},{1,1},{0,1}, foster.White)
	foster.BatcherRender(&s.batch, window)
	if s.shot {
		s.frame += 1
		if s.frame == (s.swarm_on ? 130 : 12) {
			if s.swarm_on {
				fmt.printf("Average frame time: %.2f ms, render CPU: %.2f ms (%d frames)\n", s.delta_sum*1000/119, s.cpu_sum*1000/119, 119)
			}
			save_capture(s)
			foster.Exit(app)
		}
	}
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
	name := s.swarm_on ? "material3d_swarm.png" : "material3d.png"
	fmt.println(name, foster.ImageWritePng(&image, fmt.tprintf("%s/%s", directory, name)))
}

shutdown :: proc(app: ^foster.App) {
	s := foster.AppGetUserDataAs(app, State)
	swarm_dispose(s)
	mat.material_library_dispose(&s.materials)
	foster.MeshDispose(&s.mesh)
	foster.TargetDispose(&s.target)
	foster.BatcherDispose(&s.batch)
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
