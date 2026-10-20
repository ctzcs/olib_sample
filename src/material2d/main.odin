package main

// 12 个精灵共用一个两 Pass 材质（阴影 + 本体）；Render2D 提交时对同一材质的连续一段先画完全部阴影、再画全部本体。
// 空格切换为用 pass_id 手动分两轮记录，结果相同。控制台报告真实 Draw 次数。
// 右侧一组用 Instance_Values 把 hue 设为 0.7，值走 storage buffer，仍合成同一次 Draw。
import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:time"
import SDL "vendor:sdl3"
import profiler "olib:core/profiler"
import foster "olib:foster"
import r2d "olib:kit/rendering/2d"
import mat "olib:kit/rendering/material"
import perf "olib:kit/tools/perf_overlay"

import fonts "../../shared/msdf_font"

State :: struct {
	resources: foster.StorageContainer,
	materials: mat.Material_Library,
	renderer: r2d.Render2D,
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
	// 2D 相机（像素空间）：拖动平移，滚轮以光标为中心缩放，F 复位。
	zoom: f32,
	offset, mouse_last: [2]f32,
	perf: perf.Overlay, // olib 悬浮性能面板，P 切换；shot 时不创建
	font: foster.MsdfFont, // 面板借用的 MSDF 字体
	font_texture: foster.Texture,
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
	s.zoom = 1
	s.swarm_count = SWARM_DEFAULT_COUNT
	for arg in os.args[1:] {
		switch {
		case arg == "swarm": s.swarm_on = true
		case arg == "immediate": s.immediate = true
		case arg == "auto": s.grouped = false // 不用 pass_id，由 Render2D 按 Pass 自动分组（与空格切换相同）
		case len(arg) > 6 && arg[:6] == "count=":
			value, ok := strconv.parse_int(arg[6:])
			if ok && value > 0 do s.swarm_count = value
		}
	}
	app: foster.App
	config := foster.DefaultAppConfig("Material2D | Drag: pan | Wheel: zoom | F: reset view | P: perf | Space: grouped/object passes | I: swarm | R: reload material | Esc: exit", 1000, 640)
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
	if reason := r2d.init(&s.renderer, &s.materials); reason != "" {
		fail(app, reason)
		return
	}
	if !s.shot {
		profiler.profile_init() // update / render 等作用域会列在面板里
		if font, texture, ok := fonts.load(&app.GraphicsDevice); ok {
			s.font, s.font_texture = font, texture
			s.perf.corner = .Top_Right
			s.perf.visible = perf.init(&s.perf, &app.GraphicsDevice, &s.font, s.font_texture)
		}
}
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
	profiler.profile_scope("update")
	s := foster.AppGetUserDataAs(app, State)
	s.time += f32(app.Time.Delta)
	keys := &app.Input.State.Keyboard
	if foster.KeyboardPressed(keys, .Escape) do foster.Exit(app)
	if foster.KeyboardPressed(keys, .Space) do s.grouped = !s.grouped
	if s.shot && s.frame > 10 do s.delta_sum += f64(app.Time.Delta)
	if foster.KeyboardPressed(keys, .I) do s.swarm_on = !s.swarm_on
	if foster.KeyboardPressed(keys, .F) || foster.KeyboardPressed(keys, .I) {
		s.zoom, s.offset = 1, {}
	}
	if foster.KeyboardPressed(keys, .P) do s.perf.visible = !s.perf.visible
	perf.frame(&s.perf, f32(app.Time.Delta)) // 隐藏时也记录，打开时历史完整
	camera_input(s, app)
	if foster.KeyboardPressed(keys, .R) {
		if reason := mat.material_reload(&s.materials, s.material); reason != "" {
			fmt.eprintln(reason)
		}
	}
}

// 屏幕像素 = 场景像素 * zoom + offset；缩放时保持光标下的场景点不动。
camera_input :: proc(s: ^State, app: ^foster.App) {
	mouse := &app.Input.State.Mouse
	size, pixels := foster.Size(&app.Window), foster.SizeInPixels(&app.Window)
	position := [2]f32{mouse.Position.X*f32(pixels.X)/f32(max(1, size.X)), mouse.Position.Y*f32(pixels.Y)/f32(max(1, size.Y))}
	delta := position - s.mouse_last
	s.mouse_last = position
	if foster.MouseLeftDown(mouse) || foster.MouseRightDown(mouse) || foster.MouseMiddleDown(mouse) do s.offset += delta
	if mouse.Wheel.Y != 0 {
		zoom := math.clamp(s.zoom*math.pow(f32(1.15), mouse.Wheel.Y), 0.1, 200)
		s.offset = position - (position-s.offset)*(zoom/s.zoom)
		s.zoom = zoom
	}
}

render :: proc(app: ^foster.App) {
	profiler.profile_scope("render")
	s := foster.AppGetUserDataAs(app, State)
	if s.failed do return
	start := time.tick_now()
	defer if s.shot && s.frame > 10 do s.cpu_sum += time.duration_seconds(time.tick_diff(start, time.tick_now()))
	target := s.shot ? foster.DrawableTargetFromTarget(&s.capture) : foster.DrawableTargetFromWindow(&app.Window)
	foster.GraphicsDeviceClear(&app.GraphicsDevice, target, foster.Color{31, 38, 51, 255})
	view := r2d.View{target = target, time = s.time}
	r2d.push_matrix(&s.renderer, {s.zoom, 0, 0, s.zoom, s.offset.x, s.offset.y}) // submit 后自动恢复
	if s.swarm_on {
		if !s.swarm.ready {
			if reason := swarm_init(s, s.swarm_count, f32(target.WidthInPixels), f32(target.HeightInPixels)); reason != "" {
				fail(app, reason)
				return
			}
			fmt.printf("Swarm: %d sprites, 1 draw\n", s.swarm.count)
		}
		if error := r2d.buffer(&s.renderer, s.material, &s.swarm.buffer, s.swarm.count, &s.texture); error != .None {
			fail(app, mat.draw_error_text(error))
		}
		if error := r2d.submit(&s.renderer, view); error != .None do fail(app, mat.draw_error_text(error))
		draw_panel(s, app, target)
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
	// 精灵按 0.75 缩放：帧贴图用线性采样（Render2D 与 foster Batcher 一样默认最近邻）。
	r2d.push_sampler(&s.renderer, foster.TextureSamplerMake(.Linear, .Clamp))
	if s.grouped {
		// 手动分两轮：先用 pass_id 记录全部阴影，再记录全部本体。
		for i in 0..<SPRITE_COUNT {
			error := r2d.image(&s.renderer, frame, transforms[i], origin = {128, 128}, material = s.material,
				values = sprite_values(s, i), pass_id = "shadow")
			if error != .None do fail(app, mat.draw_error_text(error))
		}
	}
	for i in 0..<SPRITE_COUNT {
		pass_id := s.grouped ? mat.Pass_Id("body") : ""
		error := r2d.image(&s.renderer, frame, transforms[i], origin = {128, 128}, material = s.material,
			values = sprite_values(s, i), pass_id = pass_id)
		if error != .None {
			fail(app, mat.draw_error_text(error))
		}
	}
	if error := r2d.submit(&s.renderer, view); error != .None do fail(app, mat.draw_error_text(error))
	if !s.reported || s.last_grouped != s.grouped || s.last_draw_calls != s.renderer.draw_calls {
		fmt.printf("%s: %d sprites x 2 passes -> %d draws\n",
			s.grouped ? "Recorded with pass_id" : "All passes, grouped by Render2D",
			SPRITE_COUNT, s.renderer.draw_calls)
		s.reported = true
		s.last_grouped = s.grouped
		s.last_draw_calls = s.renderer.draw_calls
	}
	draw_panel(s, app, target)
	finish_shot(s, app)
}

// 场景提交之后叠加 olib 性能面板：它自带 Render2D 单独提交，不计入场景 Draw，也不受相机矩阵影响。
draw_panel :: proc(s: ^State, app: ^foster.App, target: foster.DrawableTarget) {
	perf.draw(&s.perf, target, f32(target.WidthInPixels)/f32(max(1, foster.Size(&app.Window).X)))
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
	perf.dispose(&s.perf) // 先释放面板，再释放它借用的字体
	if s.font_texture.Resource != nil do foster.TextureDispose(&s.font_texture)
	foster.MsdfFontDispose(&s.font)
	delete(profiler.profile_stats)
	if s.shot do foster.TargetDispose(&s.capture)
	r2d.dispose(&s.renderer)
	mat.material_library_dispose(&s.materials)
	foster.TextureDispose(&s.texture)
}
