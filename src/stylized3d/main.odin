package main

// stylized3d：按 Celeste64 一帧的结构验收 Render3D 的三项机制——
//   View.globals 视图级数据（太阳、阴影色、雾、billboard 的相机轴，每个视图一份）、
//   ZTest Greater 剪影（角色被墙挡住的部分）、
//   读场景深度附件的描边后处理（material_set_texture 绑定单采样深度附件）。
// 光照、雾与描边的外观都写在本示例的 Shader 里，库只提供机制。
// 一帧：低分辨率场景 → 天空 → 场景 → 剪影 → 角色本体 → 深度描边 → 半透明（圆影、金币）→ 小地图 → 最终像素尺寸合成与 UI。
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import dasset "olib:core/dasset"
import foster "olib:foster"
import r2d "olib:kit/rendering/2d"
import r3d "olib:kit/rendering/3d"
import mat "olib:kit/rendering/material"
import world "olib:kit/world"

// 场景以约 360 像素高渲染：按窗口高度取整数放大倍数，宽高向上取整铺满窗口（多出的不足一个放大像素被裁掉）。
// UI 与小地图在最终窗口像素尺寸绘制，按窗口高度相对 720 缩放。
SCENE_HEIGHT :: 360
MAP_SIZE :: 180
NEAR :: 0.1
FAR :: 140
COIN_COUNT :: 9
SHOT_TIME :: 4.9 // shot 模式固定时间：角色身体在墙后、头露在墙上
FOG_COLOR :: [4]f32{0.84, 0.90, 0.98, 1} // 与 Sky 的地平线颜色相同

// 与 shaders/Stylized.hlsli 的 SceneView 一致：全是 float4，std140 不需要补齐。
Scene_View :: struct {
	sun_direction, sun_color, shadow, fog_color, fog, camera_right, camera_up: [4]f32,
}

State :: struct {
	materials: mat.Material_Library,
	ground, toon, hero, sky, coin, blob, edge: ^mat.Material,
	cube, ball, card: foster.Mesh,
	scene, post, minimap, final: foster.Target,
	pixel_scale: int, // 场景像素放大倍数
	ui_scale: f32,
	renderer: r3d.Render3D,
	batch: r2d.Render2D,
	camera, map_camera: world.Camera3D,
	blocks, canopies: [dynamic]r3d.Model_Item,
	trees: [dynamic][3]f32, // 树的位置，用来放圆影
	coins: [COIN_COUNT]r3d.Model_Item,
	time: f32,
	paused, flat, shot, failed: bool, // flat：关掉深度描边对比
	frame, measured_frames, draw_calls: int,
	submit_sum: f64,
}

main :: proc() {
	s := new(State)
	defer free(s)
	width, height := 1280, 720
	for arg in os.args[1:] {
		switch {
		case arg == "shot": s.shot = true
		case arg == "flat": s.flat = true
		case strings.has_prefix(arg, "size="): // 例如 size=1366x768，检查非整数倍窗口也能铺满
			parts := strings.split(arg[5:], "x", context.temp_allocator)
			if len(parts) == 2 {
				width = strconv.parse_int(parts[0]) or_else width
				height = strconv.parse_int(parts[1]) or_else height
			}
		}
	}
	app: foster.App
	config := foster.DefaultAppConfig("Stylized3D | Space: pause | E: edge post | Esc: exit", width, height)
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
	names := [?]string{"Toon", "Toon", "Hero", "Sky", "Billboard", "Blob", "DepthEdge"}
	slots := [?]^^mat.Material{&s.ground, &s.toon, &s.hero, &s.sky, &s.coin, &s.blob, &s.edge}
	for name, i in names {
		material, reason := mat.material_create(&s.materials, name)
		if reason != "" {
			fail(app, reason)
			return
		}
		slots[i]^ = material
	}
	// 地面与其余场景共用 Toon 效果，各自一个材质实例：只有地面铺棋盘格；其余物体的颜色走每项 tint。
	_ = mat.material_set_number(s.ground, "Toon_scene", "color", {0.46, 0.74, 0.46, 1})
	_ = mat.material_set_number(s.ground, "Toon_scene", "checker", {0.045, 0, 0, 0})
	_ = mat.material_set_number(s.toon, "Toon_scene", "checker", {0, 0, 0, 0})
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
	world.camera3d_init(&s.camera, 640, 360)
	world.camera3d_set_position(&s.camera, {0, 4.4, 10})
	world.camera3d_set_target(&s.camera, {0, 0.9, 0})
	world.camera3d_set_field_of_view(&s.camera, math.PI / 3.4)
	world.camera3d_set_near_clip(&s.camera, NEAR)
	world.camera3d_set_far_clip(&s.camera, FAR)
	// 小地图从正上方俯视；视线与默认 up 平行，所以 up 改成 -Z。
	world.camera3d_init(&s.map_camera, MAP_SIZE, MAP_SIZE)
	world.camera3d_set_position(&s.map_camera, {0, 24, 0.01})
	world.camera3d_set_target(&s.map_camera, {0, 0, 0})
	world.camera3d_set_up(&s.map_camera, {0, 0, -1})
	world.camera3d_set_near_clip(&s.map_camera, NEAR)
	world.camera3d_set_far_clip(&s.map_camera, FAR)
	build_level(s)
}

// 先缩放、再绕 Y 轴旋转、最后平移（行向量约定 v * S * R * T）。
place :: proc(center, size: [3]f32, yaw: f32 = 0) -> world.Matrix4 {
	rotation := world.matrix4_from_quaternion({0, math.sin(yaw * 0.5), 0, math.cos(yaw * 0.5)})
	m := world.matrix4_multiply(world.matrix4_scaling(size[0], size[1], size[2]), rotation)
	return world.matrix4_multiply(m, world.matrix4_translation(center[0], center[1], center[2]))
}

// 关卡：远处有土台，中间一堵挡住角色身体的矮墙，周围是树、石头和木箱；颜色走每项 tint。
build_level :: proc(s: ^State) {
	STONE :: [4]f32{0.84, 0.76, 0.66, 1}
	EARTH :: [4]f32{0.70, 0.54, 0.42, 1}
	GRASS :: [4]f32{0.46, 0.74, 0.46, 1}
	ROCK :: [4]f32{0.62, 0.63, 0.72, 1}
	WOOD :: [4]f32{0.86, 0.62, 0.40, 1}
	BARK :: [4]f32{0.52, 0.36, 0.28, 1}
	block :: proc(s: ^State, center, size: [3]f32, color: [4]f32, yaw: f32 = 0) {
		append(&s.blocks, r3d.Model_Item{place(center, size, yaw), color})
	}
	block(s, {-0.8, 0.575, 1.4}, {5.0, 1.15, 0.6}, STONE) // 矮墙：挡住走到它后面的角色身体
	block(s, {0, 0.7, -13}, {44, 1.4, 8}, EARTH)          // 远处土台
	block(s, {0, 1.5, -13}, {44, 0.2, 8.2}, GRASS)        // 土台上的草皮
	// 石头半埋进地面，比例不一，看起来不像摆放的方块。
	block(s, {3.0, 0.12, 3.4}, {0.7, 0.45, 0.55}, ROCK, 0.35)
	block(s, {3.5, 0.08, 3.9}, {0.4, 0.3, 0.35}, ROCK, -0.6)
	block(s, {-4.6, 0.15, 2.6}, {0.8, 0.5, 0.6}, ROCK, -0.5)
	block(s, {6.4, 0.1, 2.2}, {0.5, 0.35, 0.5}, ROCK, 0.8)
	block(s, {4.3, 0.4, -1.4}, {0.8, 0.8, 0.8}, WOOD, 0.15)
	block(s, {5.2, 0.4, -1.1}, {0.8, 0.8, 0.8}, WOOD, -0.3)
	block(s, {4.7, 1.2, -1.3}, {0.8, 0.8, 0.8}, WOOD, 0.5)
	TREES :: [?][3]f32{{-5.6, 0, -3.4}, {6.2, 0, -4.4}, {-8.2, 0, 1.6}, {8.6, 0, 0.6}, {-10.5, 0, -5.5}, {10.8, 0, -6.2}, {1.8, 0, -7.0}}
	for p, i in TREES {
		append(&s.trees, p)
		block(s, {p[0], 0.6, p[2]}, {0.3, 1.2, 0.3}, BARK)
		leaf := i % 2 == 0 ? [4]f32{0.34, 0.62, 0.40, 1} : [4]f32{0.40, 0.68, 0.42, 1}
		append(&s.canopies, r3d.Model_Item{place({p[0], 1.9, p[2]}, {1.1, 0.95, 1.1}), leaf})
		append(&s.canopies, r3d.Model_Item{place({p[0] + 0.3, 2.55, p[2] + 0.1}, {0.7, 0.62, 0.7}), leaf})
	}
	for &coin, i in s.coins {
		x := -4.8 + f32(i) * 1.2
		z: f32 = i % 3 == 0 ? -2.2 : 3.0 // 每三个有一个在墙后，被墙按深度遮住
		coin = {place({x, 0.95, z}, {0.5, 0.5, 0.5}), {1.0, 0.80, 0.28, 1}}
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

// 窗口尺寸变化时重建目标：场景与 post 跟随放大倍数，小地图跟随 UI 缩放。
// 重建前 clear 记录器，释放它对旧资源的借用；描边材质重新绑定新的深度附件。
resize :: proc(s: ^State, device: ^foster.GraphicsDevice, w, h: int) -> bool {
	if s.final.Width == w && s.final.Height == h do return true
	r3d.clear(&s.renderer)
	foster.TargetDispose(&s.final)
	foster.TargetInit(&s.final, device, w, h, "stylized final")
	s.pixel_scale = max(1, int(math.round(f32(h) / SCENE_HEIGHT)))
	sw, sh := (w + s.pixel_scale - 1) / s.pixel_scale, (h + s.pixel_scale - 1) / s.pixel_scale
	foster.TargetDispose(&s.scene)
	foster.TargetDispose(&s.post)
	// 场景深度用单采样 Depth32：只有单采样深度附件可以当贴图采样（foster L-018）。
	attachments := [2]foster.TargetAttachmentSpec{{Format = .Color}, {Format = .Depth32}}
	foster.TargetInit(&s.scene, device, sw, sh, attachments[:], "stylized scene")
	foster.TargetInit(&s.post, device, sw, sh, "stylized post")
	world.camera3d_set_viewport(&s.camera, sw, sh)
	if !mat.material_set_texture(s.edge, "DepthEdge_edge", "depth", foster.TargetAttachment(&s.scene, 1)) do return false
	_ = mat.material_set_number(s.edge, "DepthEdge_edge", "texel", {1 / f32(sw), 1 / f32(sh), 0, 0})
	s.ui_scale = max(1, f32(h) / 720)
	size := int(MAP_SIZE * s.ui_scale)
	if s.minimap.Width != size {
		foster.TargetDispose(&s.minimap)
		foster.TargetInit(&s.minimap, device, size, size, attachments[:], "stylized minimap")
	}
	return true
}

// 每个视图自己的视图块：相机轴来自该视图的相机；fog 为 0 时不加雾（小地图）。
scene_view :: proc(camera: ^world.Camera3D, fog: f32) -> Scene_View {
	right := world.camera3d_right(camera)
	up := linalg.cross(right, world.camera3d_forward(camera))
	sun := linalg.normalize([3]f32{-0.45, -0.8, -0.4})
	return {
		sun_direction = {sun[0], sun[1], sun[2], 0},
		sun_color = {1.0, 0.96, 0.88, 1}, // a = 1：视图块有效
		shadow = {0.16, 0.20, 0.42, 0.55},
		fog_color = FOG_COLOR,
		fog = {16, 75, fog, 0},
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
	if !resize(s, device, w, h) {
		fail(app, "Scene depth attachment cannot be sampled on this device")
		return
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
	main_globals := scene_view(&s.camera, 1)
	main_view := r3d.View{target = scene, view_projection = world.camera3d_view_projection(&s.camera),
		view_matrix = world.camera3d_view(&s.camera), time = t, globals = mem.ptr_to_bytes(&main_globals)}
	for pass in ([?]mat.Pass_Id{"sky", "scene", "silhouette", "body"}) {
		if !submit(app, main_view, pass) do return
	}

	// 深度描边：读场景颜色与深度画到 post，再拷回场景（深度保留给后面的半透明物体）。
	if !s.flat {
		if error := r2d.texture(&s.batch, foster.TargetAttachment(&s.scene, 0), foster.Matrix3x2Identity, material = s.edge); error != .None {
			fail(app, mat.draw_error_text(error))
			return
		}
		r2d.submit(&s.batch, {target = foster.DrawableTargetFromTarget(&s.post), time = t})
		_ = r2d.texture(&s.batch, foster.TargetAttachment(&s.post, 0), foster.Matrix3x2Identity)
		r2d.submit(&s.batch, {target = scene, time = t})
	}
	if !submit(app, main_view, "transparent") do return

	// 小地图：同一份记录、另一台相机和另一份视图块（不加雾）；金币朝向俯视相机。
	minimap := foster.DrawableTargetFromTarget(&s.minimap)
	map_colors := [1]foster.Color{{40, 48, 70, 255}}
	foster.GraphicsDeviceClear(device, minimap, map_colors[:], 1, 0, foster.ClearMask.Color | foster.ClearMask.Depth)
	world.camera3d_set_viewport(&s.map_camera, s.minimap.Width, s.minimap.Height)
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
			fmt.printf("Scene %dx%d x%d; model draws per frame: %d; submit CPU %.3f ms (%d frames); GPU not measured\n",
				s.scene.Width, s.scene.Height, s.pixel_scale, s.draw_calls,
				s.submit_sum * 1000 / f64(s.measured_frames), s.measured_frames)
			save_capture(s, s.flat ? "stylized3d_flat.png" : "stylized3d.png")
			foster.Exit(app)
		}
		if s.frame > 10 do s.measured_frames += 1
	}
}

// 天空跟随主相机；地面、方块、树冠、角色三段、圆影与金币各记录一次。
record :: proc(s: ^State, t: f32) -> bool {
	eye := s.camera.position
	cube_bounds, ball_bounds, card_bounds := CUBE_BOUNDS, BALL_BOUNDS, CARD_BOUNDS
	if r3d.model(&s.renderer, &s.ball, s.sky, place(eye, {80, 80, 80})) != .None do return false
	if r3d.model(&s.renderer, &s.cube, s.ground, place({0, -0.5, 0}, {240, 1, 240}), &cube_bounds) != .None do return false
	if r3d.models(&s.renderer, &s.cube, s.toon, s.blocks[:], &cube_bounds) != .None do return false
	if r3d.models(&s.renderer, &s.ball, s.toon, s.canopies[:], &ball_bounds) != .None do return false
	// 角色在墙后左右来回走：身体低于墙顶，被挡住时显示剪影；头和头发露在墙上。
	x, z := 3.0 * math.sin(t * 0.7), f32(-0.4)
	hero := [3]r3d.Model_Item{
		{place({x, 0.55, z}, {0.38, 0.5, 0.38}), {0.60, 0.38, 0.72, 1}},       // 身体
		{place({x, 1.33, z}, {0.34, 0.34, 0.34}), {1.0, 0.84, 0.72, 1}},       // 头
		{place({x, 1.42, z - 0.08}, {0.37, 0.33, 0.37}), {0.90, 0.26, 0.28, 1}}, // 头发
	}
	if r3d.models(&s.renderer, &s.ball, s.hero, hero[:], &ball_bounds) != .None do return false
	coins := s.coins
	blobs: [COIN_COUNT + 16]r3d.Model_Item
	count := 0
	for &coin, i in coins {
		coin.world.c1[3] += 0.12 * math.sin(t * 2 + f32(i)) // 上下浮动（平移在各列第 4 分量）
		blobs[count] = {place({coin.world.c0[3], 0.02, coin.world.c2[3]}, {0.34, 1, 0.34}), {1, 1, 1, 0.35}}
		count += 1
	}
	blobs[count] = {place({x, 0.02, z}, {0.55, 1, 0.55}), {1, 1, 1, 0.55}}
	count += 1
	for p in s.trees {
		if count == len(blobs) do break
		blobs[count] = {place({p[0], 0.02, p[2]}, {1.4, 1, 1.4}), {1, 1, 1, 0.4}}
		count += 1
	}
	if r3d.models(&s.renderer, &s.card, s.blob, blobs[:count], &card_bounds) != .None do return false
	return r3d.models(&s.renderer, &s.card, s.coin, coins[:], &card_bounds) == .None
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

// 最终像素尺寸合成：场景按整数倍最近邻放大铺满窗口；小地图与 HUD 贴窗口角落，按 UI 缩放、不随场景放大。
compose :: proc(s: ^State, w, h: int) {
	r := &s.batch
	sw, sh := f32(s.scene.Width * s.pixel_scale), f32(s.scene.Height * s.pixel_scale)
	r2d.push_sampler(r, foster.TextureSamplerMake(.Nearest, .Clamp))
	_ = r2d.quad_texture(r, foster.TargetAttachment(&s.scene, 0), {0, 0}, {sw, 0}, {sw, sh}, {0, sh},
		{0, 0}, {1, 0}, {1, 1}, {0, 1})
	r2d.pop_sampler(r)
	u := s.ui_scale
	px :: proc(v: f32) -> f32 { return math.round(v) } // UI 对齐到整像素，细线保持锐利
	margin, border := px(16 * u), px(2 * u)
	// 小地图：右上角，浅色细边框外加一圈半透明暗边。
	size := f32(s.minimap.Width)
	mx, my := f32(w) - size - margin, margin
	_ = r2d.rect(r, {mx - border * 2, my - border * 2, size + border * 4, size + border * 4}, {16, 20, 36, 140})
	_ = r2d.rect(r, {mx - border, my - border, size + border * 2, size + border * 2}, {240, 236, 226, 255})
	_ = r2d.quad_texture(r, foster.TargetAttachment(&s.minimap, 0), {mx, my}, {mx + size, my},
		{mx + size, my + size}, {mx, my + size}, {0, 0}, {1, 0}, {1, 1}, {0, 1})
	// HUD：左下角半透明面板与金币计数格。
	pip, gap := px(14 * u), px(6 * u)
	pw, ph := px(12 * u) * 2 + f32(COIN_COUNT) * pip + f32(COIN_COUNT - 1) * gap, px(38 * u)
	hx, hy := margin, f32(h) - margin - ph
	_ = r2d.rect(r, {hx, hy, pw, ph}, {16, 20, 36, 190})
	_ = r2d.rect(r, {hx, hy, pw, px(u)}, {240, 236, 226, 200})
	for i in 0..<COIN_COUNT {
		cx, cy := hx + px(12 * u) + f32(i) * (pip + gap), hy + (ph - pip) / 2
		color := i < 4 ? foster.Color{255, 206, 72, 255} : foster.Color{64, 72, 100, 255}
		_ = r2d.rect(r, {cx, cy, pip, pip}, color)
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
	delete(s.canopies)
	delete(s.trees)
}
