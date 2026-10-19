package main

// 先画所有阴影，再画所有本体；空格切换逐对象绘制，控制台报告真实 Draw 次数。
// 12 个精灵共用一个 Material；右侧一组用 Instance_Values 把 hue 设为 0.7，仍合成同一次 Draw。
import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:time"
import SDL "vendor:sdl3"
import foster "olib:foster"
import r2d "olib:kit/rendering/2d"
import mat "olib:kit/rendering/material"

State :: struct {
	resources: foster.StorageContainer,
	materials: mat.Material_Library,
	renderer: r2d.Sprite_Renderer,
	material: ^mat.Material, // 12 个精灵共用一个材质、一张图
	cool: mat.Instance_Values, // 右侧一组的实例字段：只改 hue，不创建新的 Material
	shot: bool, // 参数 shot：离屏渲染固定时间的画面，写 PNG 后退出（验收用）
	capture: foster.Target,
	frame: int,
	// 百万精灵演示：参数 swarm（可加 count=N）启动即开，按 I 切换；immediate 不限帧并关闭垂直同步，测真实耗时。
	swarm: Swarm,
	swarm_on, immediate: bool,
	swarm_count: int,
	delta_sum, cpu_sum: f64,
	texture: foster.Texture,
	time: f32,
	failed: bool,
	grouped: bool,
	reported: bool,
	last_grouped: bool,
	last_draw_calls: int,
}

main :: proc() {
	s := new(State)
	defer free(s)
	s.grouped = true
	s.swarm_count = SWARM_DEFAULT_COUNT
	for arg in os.args[1:] {
		switch {
		case arg == "swarm": s.swarm_on = true
		case arg == "immediate": s.immediate = true
		case len(arg) > 6 && arg[:6] == "count=":
			value, ok := strconv.parse_int(arg[6:])
			if ok && value > 0 do s.swarm_count = value
		}
	}
	app: foster.App
	config := foster.DefaultAppConfig("Material2D | Space: grouped/object passes | I: swarm | R: reload material | Esc: exit", 1000, 640)
	if s.immediate do config.UpdateMode = foster.UnlockedStep()
	foster.InitApp(&app, config)
	foster.AppSetUserData(&app, s)
	app.StartupProc = startup
	app.UpdateProc = update
	app.RenderProc = render
	app.ShutdownProc = shutdown
	foster.Run(&app)
	foster.Dispose(&app)
	delete(app.GraphicsDevice.WindowRenderTarget.Attachments)
}

startup :: proc(app: ^foster.App) {
	s := foster.AppGetUserDataAs(app, State)
	s.resources.Root = #directory
	for arg in os.args do s.shot = s.shot || arg == "shot"
	if s.shot do foster.TargetInit(&s.capture, &app.GraphicsDevice, 1000, 640)
	s.materials = {device = &app.GraphicsDevice, storage = &s.resources}
	if reason := register_materials(&s.materials); reason != "" {
		fail(app, reason)
		return
	}
	if s.immediate { _ = SDL.SetGPUSwapchainParameters(app.GraphicsDevice.Device, app.Window.Handle, .SDR, .IMMEDIATE) }
	r2d.sprite_renderer_init(&s.renderer, &app.GraphicsDevice)
	image := foster.ImageMake(256, 256)
	defer foster.ImageDispose(&image)
	for y in 0..<256 {
		for x in 0..<256 {
			dx, dy := f32(x)-127.5, f32(y)-127.5
			alpha := math.clamp(104-math.sqrt(dx*dx+dy*dy), 0, 1)
			value := (x/32+y/32)%2 == 0 ? u8(255) : u8(150)
			foster.ImageSetPixel(&image, x, y, {value, value, value, u8(alpha*255)})
		}
	}
	foster.ImagePremultiply(&image)
	s.texture = foster.TextureFromImage(&app.GraphicsDevice, &image, "sprite frame")
	material, reason := mat.material_load(&s.materials, "material.json")
	if reason != "" {
		fail(app, reason)
		return
	}
	hue := mat.instance_slot(material, "hue") // 名字只解析一次，之后按槽位设值
	_ = mat.instance_values_set(&s.cool, hue, {0.7, 0, 0, 0})
	s.material = material
}

SPRITE_COUNT :: 12

// 右侧一组（后 6 个）用 cool 实例值，其余沿用材质里的 hue。
sprite_values :: proc(s: ^State, i: int) -> ^mat.Instance_Values {
	return i >= SPRITE_COUNT/2 ? &s.cool : nil
}

fail :: proc(app: ^foster.App, reason: string) {
	fmt.eprintln(reason)
	foster.AppGetUserDataAs(app, State).failed = true
	foster.Exit(app)
}

update :: proc(app: ^foster.App) {
	s := foster.AppGetUserDataAs(app, State)
	s.time += f32(app.Time.Delta)
	keys := &app.Input.State.Keyboard
	if foster.KeyboardPressed(keys, .Escape) do foster.Exit(app)
	if foster.KeyboardPressed(keys, .Space) do s.grouped = !s.grouped
	if s.shot && s.frame > 10 do s.delta_sum += f64(app.Time.Delta)
	if foster.KeyboardPressed(keys, .I) do s.swarm_on = !s.swarm_on
	if foster.KeyboardPressed(keys, .R) {
		if reason := mat.material_reload(&s.materials, s.material); reason != "" {
			fmt.eprintln(reason)
		}
	}
}

render :: proc(app: ^foster.App) {
	s := foster.AppGetUserDataAs(app, State)
	if s.failed do return
	start := time.tick_now()
	defer if s.shot && s.frame > 10 do s.cpu_sum += time.duration_seconds(time.tick_diff(start, time.tick_now()))
	target := s.shot ? foster.DrawableTargetFromTarget(&s.capture) : foster.DrawableTargetFromWindow(&app.Window)
	foster.GraphicsDeviceClear(&app.GraphicsDevice, target, foster.Color{31, 38, 51, 255})
	view := r2d.Sprite_View{target = target, time = s.time}
	if s.swarm_on {
		if !s.swarm.ready {
			if reason := swarm_init(s, &app.GraphicsDevice, s.swarm_count, f32(target.WidthInPixels), f32(target.HeightInPixels)); reason != "" {
				fail(app, reason)
				return
			}
			fmt.printf("Swarm: %d sprites, 1 draw\n", s.swarm.count)
		}
		if error := r2d.sprite_draw_buffer(&s.renderer, s.material, &s.swarm.buffer, s.swarm.count,
			&s.texture, view, "body"); error != .None {
			fail(app, mat.draw_error_text(error))
		}
		finish_shot(s, app)
		return
	}
	transforms: [SPRITE_COUNT]foster.Matrix3x2
	for &transform, i in transforms {
		x := f32(target.WidthInPixels)/2 + (f32(i/3)-1.5)*125
		y := f32(target.HeightInPixels)/2 + (f32(i%3)-1)*125 + math.sin(s.time+f32(i))*12
		transform = {0.75, 0, 0, 0.75, x, y}
	}
	frame := foster.SubtextureFromTexture(&s.texture)
	if !r2d.sprite_begin(&s.renderer) {
		fail(app, "Cannot begin sprite rendering")
		return
	}
	if s.grouped {
		// 顺序由使用者选择；Renderer 只合并相邻兼容绘制。
		for i in 0..<SPRITE_COUNT {
			error := r2d.sprite_draw(&s.renderer, s.material, frame, transforms[i], view,
				origin = {128, 128}, values = sprite_values(s, i), pass_id = "shadow")
			if error != .None do fail(app, mat.draw_error_text(error))
		}
	}
	for i in 0..<SPRITE_COUNT {
		pass_id := s.grouped ? mat.Pass_Id("body") : ""
		error := r2d.sprite_draw(&s.renderer, s.material, frame, transforms[i], view,
			origin = {128, 128}, values = sprite_values(s, i), pass_id = pass_id)
		if error != .None {
			fail(app, mat.draw_error_text(error))
		}
	}
	r2d.sprite_end(&s.renderer)
	if !s.reported || s.last_grouped != s.grouped || s.last_draw_calls != s.renderer.draw_calls {
		fmt.printf("%s: %d sprite passes -> %d draws\n",
			s.grouped ? "All shadows, then all bodies" : "All passes per object",
			s.renderer.sprite_passes, s.renderer.draw_calls)
		s.reported = true
		s.last_grouped = s.grouped
		s.last_draw_calls = s.renderer.draw_calls
	}
	finish_shot(s, app)
}

// shot 模式：固定帧数后读回离屏目标写 PNG 并退出；swarm 模式多跑一些帧并打印平均耗时。
finish_shot :: proc(s: ^State, app: ^foster.App) {
	if !s.shot do return
	s.frame += 1
	s.time = 0.5 // 固定时间，画面可重复
	if s.frame == (s.swarm_on ? 130 : 12) {
		if s.swarm_on {
			fmt.printf("Average frame time: %.2f ms, render CPU: %.2f ms (%d frames)\n", s.delta_sum*1000/119, s.cpu_sum*1000/119, 119)
		}
		save_capture(s)
		foster.Exit(app)
	}
}

// 读回离屏目标并写到 library/screenshots/material2d.png（相对示例仓库根）。
save_capture :: proc(s: ^State) {
	bytes := foster.TextureDownloadData(foster.TargetAttachment(&s.capture, 0))
	defer delete(bytes)
	w, h := s.capture.Width, s.capture.Height
	image := foster.ImageMake(w, h)
	defer foster.ImageDispose(&image)
	if len(bytes) < w*h*4 {
		fmt.eprintln("Capture readback failed")
		return
	}
	for &pixel, i in image.Pixels do pixel = {bytes[i*4], bytes[i*4+1], bytes[i*4+2], bytes[i*4+3]}
	directory :: #directory + "../../library/screenshots"
	_ = os.make_directory_all(directory)
	name := s.swarm_on ? "material2d_swarm.png" : "material2d.png"
	fmt.println(name, foster.ImageWritePng(&image, fmt.tprintf("%s/%s", directory, name)))
}

shutdown :: proc(app: ^foster.App) {
	s := foster.AppGetUserDataAs(app, State)
	swarm_dispose(s)
	if s.shot do foster.TargetDispose(&s.capture)
	mat.material_library_dispose(&s.materials)
	r2d.sprite_renderer_dispose(&s.renderer)
	foster.TextureDispose(&s.texture)
}
