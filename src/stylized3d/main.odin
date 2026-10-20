package main

// stylized3d：按 Celeste64 一帧的结构验收 Render3D 的三项机制——
//   View.globals 视图级数据（太阳、雾、billboard 的相机轴，每个视图一份）、
//   ZTest Greater 剪影（角色被墙挡住的部分）、
//   读场景深度附件的描边后处理（material_set_texture 绑定单采样深度附件）。
// 光照、雾与描边的外观都写在本示例的 Shader 里，库只提供机制。
// 一帧：低分辨率场景 → 天空 → 场景 → 剪影 → 角色本体 → 深度描边 → 半透明面片 → 小地图 → 最终像素尺寸合成与 UI。
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:os"
import "core:time"
import dasset "olib:core/dasset"
import foster "olib:foster"
import r2d "olib:kit/rendering/2d"
import r3d "olib:kit/rendering/3d"
import mat "olib:kit/rendering/material"
import world "olib:kit/world"

// 场景按 640×360 渲染、整数倍放大；UI 与小地图在最终窗口像素尺寸绘制。
LOW_W :: 640
LOW_H :: 360
MAP_SIZE :: 200
NEAR :: 0.1
FAR :: 120
COIN_COUNT :: 9
SHOT_TIME :: 4.9 // shot 模式固定时间：角色身体在墙后、头露在墙上

// 与 shaders/Stylized.hlsli 的 SceneView 一致：全是 float4，std140 不需要补齐。
Scene_View :: struct {
	sun_direction, sun_color, ambient, fog_color, fog, camera_right, camera_up: [4]f32,
}

State :: struct {
	materials: mat.Material_Library,
	toon, hero, sky, coin, edge: ^mat.Material,
	cube, ball, card: foster.Mesh,
	scene, post, minimap, final: foster.Target,
	renderer: r3d.Render3D,
	batch: r2d.Render2D,
	camera, map_camera: world.Camera3D,
	blocks: [dynamic]r3d.Model_Item,
	coins: [COIN_COUNT]r3d.Model_Item,
	time: f32,
	paused, flat, shot, failed: bool, // flat：关掉深度描边对比
	frame, measured_frames, draw_calls: int,
	submit_sum: f64,
}

main :: proc() {
	s := new(State)
	defer free(s)
	for arg in os.args[1:] {
		switch arg {
		case "shot": s.shot = true
		case "flat": s.flat = true
		}
	}
	app: foster.App
	config := foster.DefaultAppConfig("Stylized3D | Space: pause | E: edge post | Esc: exit", 1280, 720)
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
	s.materials = {device = device}
	if reason := register_effects(&s.materials); reason != "" {
		fail(app, reason)
		return
	}
	names := [?]string{"Toon", "Hero", "Sky", "Billboard", "DepthEdge"}
	slots := [?]^^mat.Material{&s.toon, &s.hero, &s.sky, &s.coin, &s.edge}
	for name, i in names {
		material, reason := mat.material_create(&s.materials, name)
		if reason != "" {
			fail(app, reason)
			return
		}
		slots[i]^ = material
	}
	// 场景深度用单采样 Depth32：只有单采样深度附件可以当贴图采样（foster L-018）。
	attachments := [2]foster.TargetAttachmentSpec{{Format = .Color}, {Format = .Depth32}}
	foster.TargetInit(&s.scene, device, LOW_W, LOW_H, attachments[:], "stylized scene")
	foster.TargetInit(&s.post, device, LOW_W, LOW_H, "stylized post")
	foster.TargetInit(&s.minimap, device, MAP_SIZE, MAP_SIZE, attachments[:], "stylized minimap")
	if !mat.material_set_texture(s.edge, "DepthEdge_edge", "depth", foster.TargetAttachment(&s.scene, 1)) {
		fail(app, "Scene depth attachment cannot be sampled on this device")
		return
	}
	_ = mat.material_set_number(s.edge, "DepthEdge_edge", "texel", {1.0 / LOW_W, 1.0 / LOW_H, 0, 0})
	_ = mat.material_set_number(s.edge, "DepthEdge_edge", "clip", {NEAR, FAR, 0, 0})
	primitives := [3]dasset.Dasset_Primitive{cube(), sphere(), quad()}
	defer for &primitive in primitives do primitive_dispose(&primitive)
	meshes := [3]^foster.Mesh{&s.cube, &s.ball, &s.card}
	for &primitive, i in primitives {
		if !r3d.mesh_upload(meshes[i], device, &primitive) {
			fail(app, "Cannot upload mesh")
			return
		}
	}
	if reason := r3d.init(&s.renderer, &s.materials); reason != "" {
		fail(app, reason)
		return
	}
	if reason := r2d.init(&s.batch, &s.materials); reason != "" {
		fail(app, reason)
		return
	}
	world.camera3d_init(&s.camera, LOW_W, LOW_H)
	world.camera3d_set_position(&s.camera, {0, 5.2, 11})
	world.camera3d_set_target(&s.camera, {0, 0.9, 0})
	world.camera3d_set_near_clip(&s.camera, NEAR)
	world.camera3d_set_far_clip(&s.camera, FAR)
	// 小地图从正上方俯视；视线与默认 up 平行，所以 up 改成 -Z。
	world.camera3d_init(&s.map_camera, MAP_SIZE, MAP_SIZE)
	world.camera3d_set_position(&s.map_camera, {0, 20, 0.01})
	world.camera3d_set_target(&s.map_camera, {0, 0, 0})
	world.camera3d_set_up(&s.map_camera, {0, 0, -1})
	world.camera3d_set_near_clip(&s.map_camera, NEAR)
	world.camera3d_set_far_clip(&s.map_camera, FAR)
	build_level(s)
}

// 关卡：地面、一堵挡住角色身体的墙、几根柱子与台阶，颜色走每项 tint，共用一个 Toon 材质。
build_level :: proc(s: ^State) {
	block :: proc(s: ^State, center, size: [3]f32, color: [4]f32) {
		transform := world.matrix4_multiply(world.matrix4_scaling(size[0], size[1], size[2]),
			world.matrix4_translation(center[0], center[1], center[2]))
		append(&s.blocks, r3d.Model_Item{transform, color})
	}
	block(s, {0, -0.25, 0}, {24, 0.5, 24}, {0.52, 0.74, 0.42, 1}) // 地面
	block(s, {-1.0, 0.9, 1.2}, {5.5, 1.8, 0.6}, {0.78, 0.70, 0.62, 1}) // 墙：挡住走到它后面的角色
	block(s, {-5.5, 1.5, -3.0}, {1.2, 3.0, 1.2}, {0.62, 0.66, 0.80, 1})
	block(s, {5.0, 1.0, -2.0}, {1.2, 2.0, 1.2}, {0.62, 0.66, 0.80, 1})
	block(s, {3.5, 0.25, 3.5}, {2.0, 0.5, 2.0}, {0.90, 0.80, 0.55, 1})
	block(s, {3.5, 0.75, 3.5}, {1.0, 0.5, 1.0}, {0.90, 0.80, 0.55, 1})
	block(s, {-3.5, 0.4, 4.5}, {1.6, 0.8, 1.6}, {0.70, 0.52, 0.68, 1})
	for &coin, i in s.coins {
		x := -4.8 + f32(i) * 1.2
		z: f32 = i % 3 == 0 ? -2.2 : 3.0 // 每三个有一个在墙后，被墙按深度遮住
		coin = {world.matrix4_multiply(world.matrix4_scaling(0.55, 0.55, 0.55), world.matrix4_translation(x, 1.1, z)),
			{1.0, 0.80, 0.25, 0.92}}
	}
}

update :: proc(app: ^foster.App) {
	s := foster.AppGetUserDataAs(app, State)
	keys := &app.Input.State.Keyboard
	if foster.KeyboardPressed(keys, .Escape) do foster.Exit(app)
	if foster.KeyboardPressed(keys, .Space) do s.paused = !s.paused
	if foster.KeyboardPressed(keys, .E) do s.flat = !s.flat
	if !s.paused && !s.shot do s.time += f32(app.Time.Delta)
}

// 每个视图自己的视图块：相机轴来自该视图的相机，太阳与雾按视图需要各给一份。
scene_view :: proc(camera: ^world.Camera3D, fog: f32) -> Scene_View {
	right := world.camera3d_right(camera)
	up := linalg.cross(right, world.camera3d_forward(camera))
	sun := linalg.normalize([3]f32{-0.45, -0.8, -0.4})
	return {
		sun_direction = {sun[0], sun[1], sun[2], 0},
		sun_color = {0.95, 0.88, 0.75, 1}, // a = 1：视图块有效
		ambient = {0.32, 0.36, 0.52, 1},
		fog_color = {0.80, 0.87, 0.96, 1},
		fog = {12, 40, fog, 0},
		camera_right = {right[0], right[1], right[2], 0},
		camera_up = {up[0], up[1], up[2], 0},
	}
}

render :: proc(app: ^foster.App) {
	s := foster.AppGetUserDataAs(app, State)
	if s.failed do return
	device := &app.GraphicsDevice
	window := foster.DrawableTargetFromWindow(&app.Window)
	w, h := window.WidthInPixels, window.HeightInPixels
	if w <= 0 || h <= 0 do return
	if s.final.Width != w || s.final.Height != h {
		foster.TargetDispose(&s.final)
		foster.TargetInit(&s.final, device, w, h, "stylized final")
	}
	t := s.shot ? SHOT_TIME : s.time
	s.draw_calls = 0

	// 记录一次，提交给主视图的各阶段和小地图。
	r3d.clear(&s.renderer)
	if !record(s, t) {
		fail(app, "Cannot record scene")
		return
	}

	// 主视图：天空 → 场景 → 剪影 → 角色本体。
	scene := foster.DrawableTargetFromTarget(&s.scene)
	colors := [1]foster.Color{{0, 0, 0, 255}}
	foster.GraphicsDeviceClear(device, scene, colors[:], 1, 0, foster.ClearMask.Color | foster.ClearMask.Depth)
	main_globals := scene_view(&s.camera, 0.85)
	main_view := r3d.View{target = scene, view_projection = world.camera3d_view_projection(&s.camera),
		view_matrix = world.camera3d_view(&s.camera), time = t, globals = mem.ptr_to_bytes(&main_globals)}
	for pass in ([?]mat.Pass_Id{"sky", "scene", "silhouette", "body"}) {
		if !submit(app, main_view, pass) do return
	}

	// 深度描边：读场景颜色与深度画到 post，再拷回场景（深度保留给后面的半透明面片）。
	if !s.flat {
		post := foster.DrawableTargetFromTarget(&s.post)
		if error := r2d.texture(&s.batch, foster.TargetAttachment(&s.scene, 0), foster.Matrix3x2Identity, material = s.edge); error != .None {
			fail(app, mat.draw_error_text(error))
			return
		}
		r2d.submit(&s.batch, {target = post, time = t})
		_ = r2d.texture(&s.batch, foster.TargetAttachment(&s.post, 0), foster.Matrix3x2Identity)
		r2d.submit(&s.batch, {target = scene, time = t})
	}
	if !submit(app, main_view, "transparent") do return

	// 小地图：同一份记录、另一台相机和另一份视图块（不加雾）；面片朝向俯视相机。
	minimap := foster.DrawableTargetFromTarget(&s.minimap)
	map_colors := [1]foster.Color{{40, 48, 70, 255}}
	foster.GraphicsDeviceClear(device, minimap, map_colors[:], 1, 0, foster.ClearMask.Color | foster.ClearMask.Depth)
	map_globals := scene_view(&s.map_camera, 0)
	map_view := r3d.View{target = minimap, view_projection = world.camera3d_view_projection(&s.map_camera),
		view_matrix = world.camera3d_view(&s.map_camera), time = t, globals = mem.ptr_to_bytes(&map_globals)}
	for pass in ([?]mat.Pass_Id{"scene", "body", "transparent"}) {
		if !submit(app, map_view, pass) do return
	}

	compose(s, w, h)
	r2d.submit(&s.batch, {target = foster.DrawableTargetFromTarget(&s.final), time = t})
	_ = r2d.texture(&s.batch, foster.TargetAttachment(&s.final, 0), foster.Matrix3x2Identity)
	r2d.submit(&s.batch, {target = window, time = t})

	if s.shot {
		s.frame += 1
		if s.frame == 130 {
			fmt.printf("Model draws per frame: %d; submit CPU %.3f ms (%d frames); GPU not measured\n",
				s.draw_calls, s.submit_sum * 1000 / f64(s.measured_frames), s.measured_frames)
			save_capture(s, s.flat ? "stylized3d_flat.png" : "stylized3d.png")
			foster.Exit(app)
		}
		if s.frame > 10 do s.measured_frames += 1
	}
}

// 天空跟随主相机；场景方块、角色两段身体与金币各自记录一次。
record :: proc(s: ^State, t: f32) -> bool {
	eye := s.camera.position
	sky := world.matrix4_multiply(world.matrix4_scaling(60, 60, 60), world.matrix4_translation(eye[0], eye[1], eye[2]))
	if r3d.model(&s.renderer, &s.ball, s.sky, sky) != .None do return false
	cube_bounds, ball_bounds, coin_bounds := CUBE_BOUNDS, BALL_BOUNDS, COIN_BOUNDS
	if r3d.models(&s.renderer, &s.cube, s.toon, s.blocks[:], &cube_bounds) != .None do return false
	// 角色在墙后左右来回走：身体（低于墙顶）被挡住时显示剪影，头始终露在墙上。
	x := 3.6 * math.sin(t * 0.7)
	body := world.matrix4_multiply(world.matrix4_scaling(0.55, 0.75, 0.55), world.matrix4_translation(x, 0.85, -0.4))
	head := world.matrix4_multiply(world.matrix4_scaling(0.42, 0.42, 0.42), world.matrix4_translation(x, 2.0, -0.4))
	if r3d.model(&s.renderer, &s.ball, s.hero, body, &ball_bounds) != .None do return false
	if r3d.model(&s.renderer, &s.ball, s.hero, head, &ball_bounds) != .None do return false
	coins := s.coins
	for &coin, i in coins do coin.world.c1[3] += 0.15 * math.sin(t * 2 + f32(i)) // 上下浮动（平移在各列第 4 分量）
	return r3d.models(&s.renderer, &s.card, s.coin, coins[:], &coin_bounds) == .None
}

submit :: proc(app: ^foster.App, view: r3d.View, pass: mat.Pass_Id) -> bool {
	s := foster.AppGetUserDataAs(app, State)
	start := time.tick_now()
	error := r3d.submit(&s.renderer, view, pass)
	if s.shot && s.frame > 10 do s.submit_sum += time.duration_seconds(time.tick_diff(start, time.tick_now()))
	if error != .None {
		fail(app, mat.draw_error_text(error))
		return false
	}
	s.draw_calls += s.renderer.draw_calls
	return true
}

// 最终像素尺寸合成：场景按整数倍最近邻放大居中；小地图与 HUD 不随场景放大，按窗口像素绘制。
compose :: proc(s: ^State, w, h: int) {
	r := &s.batch
	_ = r2d.rect(r, {0, 0, f32(w), f32(h)}, {12, 14, 22, 255})
	scale := max(1, min(w / LOW_W, h / LOW_H))
	sw, sh := f32(LOW_W * scale), f32(LOW_H * scale)
	x0, y0 := f32((w - LOW_W * scale) / 2), f32((h - LOW_H * scale) / 2)
	r2d.push_sampler(r, foster.TextureSamplerMake(.Nearest, .Clamp))
	_ = r2d.quad_texture(r, foster.TargetAttachment(&s.scene, 0), {x0, y0}, {x0 + sw, y0}, {x0 + sw, y0 + sh}, {x0, y0 + sh},
		{0, 0}, {1, 0}, {1, 1}, {0, 1})
	r2d.pop_sampler(r)
	// 小地图 1:1 贴在右上角，带 2 像素边框。
	mx, my := x0 + sw - MAP_SIZE - 16, y0 + 16
	_ = r2d.rect(r, {mx - 2, my - 2, MAP_SIZE + 4, MAP_SIZE + 4}, {245, 240, 225, 255})
	_ = r2d.quad_texture(r, foster.TargetAttachment(&s.minimap, 0), {mx, my}, {mx + MAP_SIZE, my},
		{mx + MAP_SIZE, my + MAP_SIZE}, {mx, my + MAP_SIZE}, {0, 0}, {1, 0}, {1, 1}, {0, 1})
	// HUD：左下角面板与金币计数格，1 像素的描边在最终像素上保持锐利。
	px, py := x0 + 16, y0 + sh - 56
	_ = r2d.rect(r, {px, py, 220, 40}, {20, 24, 40, 220})
	_ = r2d.rect(r, {px, py, 220, 1}, {245, 240, 225, 255})
	for i in 0..<COIN_COUNT {
		_ = r2d.rect(r, {px + 12 + f32(i) * 22, py + 12, 16, 16}, i < 4 ? foster.Color{255, 204, 64, 255} : foster.Color{70, 76, 100, 255})
	}
}

// 读回最终合成（含 UI）写到 library/screenshots（相对示例仓库根）。
save_capture :: proc(s: ^State, name: string) {
	bytes := foster.TextureDownloadData(foster.TargetAttachment(&s.final, 0))
	defer delete(bytes)
	w, h := s.final.Width, s.final.Height
	image := foster.ImageMake(w, h)
	defer foster.ImageDispose(&image)
	if len(bytes) < w*h*4 {
		fmt.eprintln("Capture readback failed")
		return
	}
	for &pixel, i in image.Pixels do pixel = {bytes[i*4], bytes[i*4+1], bytes[i*4+2], bytes[i*4+3]}
	directory :: #directory + "../../library/screenshots"
	_ = os.make_directory_all(directory)
	fmt.println(name, foster.ImageWritePng(&image, fmt.tprintf("%s/%s", directory, name)))
}

shutdown :: proc(app: ^foster.App) {
	s := foster.AppGetUserDataAs(app, State)
	r3d.dispose(&s.renderer) // 先释放借用网格、材质与贴图的记录器
	r2d.dispose(&s.batch)
	mat.material_library_dispose(&s.materials)
	r3d.mesh_dispose(&s.cube)
	r3d.mesh_dispose(&s.ball)
	r3d.mesh_dispose(&s.card)
	foster.TargetDispose(&s.scene)
	foster.TargetDispose(&s.post)
	foster.TargetDispose(&s.minimap)
	foster.TargetDispose(&s.final)
	delete(s.blocks)
}
