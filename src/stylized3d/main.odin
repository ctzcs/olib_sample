package main

// stylized3d：按 Celeste64 一帧的结构验收 Render3D 的三项机制——
//   View.globals 视图级数据（太阳、阴影色、雾、billboard 的相机轴，每个视图一份）、
//   ZTest Greater 剪影（角色被墙挡住的部分）、
//   读场景深度附件的 AO 与描边后处理（material_set_texture 绑定单采样深度附件）。
// 光照、雾、AO 与描边的外观都写在本示例的 Shader 里，库只提供机制。
// 一帧：太阳阴影图 → 镜像相机倒影 → 低分辨率场景 → 天空 → 场景 → 剪影 → 角色本体 → AO → 深度描边 → 水面 → 半透明（圆影、金币）→ 小地图 → 最终像素尺寸合成与 UI。
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
FOG_COLOR :: [4]f32{0.91, 0.89, 0.73, 1} // 与 Sky 的地平线颜色相同

// 与 shaders/Stylized.hlsli 的 SceneView 一致：全是 float4，std140 不需要补齐。
Scene_View :: struct {
	sun_direction, sun_color, shadow, fog_color, fog, camera_right, camera_up: [4]f32,
	light_c0, light_c1, light_c2, light_c3, shadow_map: [4]f32,
	reflection_c0, reflection_c1, reflection_c2, reflection_c3, water_view: [4]f32,
}

State :: struct {
	materials: mat.Material_Library,
	ground, toon, hero, sky, coin, blob, edge, ao: ^mat.Material,
	grass_material, flower_material, sun_caster: ^mat.Material,
	water: ^mat.Material,
	water_mesh, terrain_mesh: foster.Mesh,
	reflection: foster.Target,
	reflection_camera: world.Camera3D,
	reflection_projection: world.Matrix4,
	water_shot, no_reflection: bool,
	camera_shot: bool,
	cube, ball, card: foster.Mesh,
	facet, crown_mesh, trunk_mesh, grass_mesh, flower_mesh: foster.Mesh,
	scene, post, minimap, final: foster.Target,
	sun_target: foster.Target,
	light_view, light_projection: world.Matrix4,
	scenery: [Scenery_Kind]Scenery_Batch,
	scenery_instances, submitted_instances, shadow_draws: int,
	no_shadows: bool,
	pixel_scale: int, // 场景像素放大倍数
	ui_scale: f32,
	renderer: r3d.Render3D,
	batch: r2d.Render2D,
	camera, map_camera: world.Camera3D,
	player: Player,
	follow: Follow_Camera,
	colliders: [dynamic]Collision_Box,
	physics_accumulator: f32,
	mouse_look, follow_shot, smoke: bool,
	coins: [COIN_COUNT]r3d.Model_Item,
	time: f32,
	shot_time: f32,
	wind_capture: bool,
	paused, flat, shot, failed: bool, // flat：关掉深度描边对比
	no_ao: bool,
	frame, measured_frames, draw_calls: int,
	submit_sum: f64,
}

main :: proc() {
	s := new(State)
	s.shot_time = SHOT_TIME
	defer free(s)
	width, height := 1280, 720
	for arg in os.args[1:] {
		switch {
		case arg == "shot": s.shot = true
		case arg == "flat": s.flat = true
		case arg == "noao": s.no_ao = true
		case arg == "noshadow": s.no_shadows = true
		case arg == "calm": s.shot_time, s.wind_capture = 0, true
		case arg == "gust": s.shot_time, s.wind_capture = 7, true
		case arg == "follow": s.follow_shot = true
		case arg == "water": s.water_shot, s.follow_shot = true, true
		case arg == "camera": s.camera_shot, s.follow_shot = true, true
		case arg == "noreflection": s.no_reflection = true
		case arg == "smoke": s.smoke, s.shot, s.follow_shot = true, true, true
		case strings.has_prefix(arg, "size="): // 例如 size=1366x768，检查非整数倍窗口也能铺满
			parts := strings.split(arg[5:], "x", context.temp_allocator)
			if len(parts) == 2 {
				width = strconv.parse_int(parts[0]) or_else width
				height = strconv.parse_int(parts[1]) or_else height
			}
		}
	}
	app: foster.App
	config := foster.DefaultAppConfig("Stylized3D | WASD move | Space jump | Shift run | RMB orbit | Wheel zoom | R reset | P pause | O AO | L shadows | E edge", width, height)
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
	names := [?]string{"Toon", "Toon", "Hero", "Sky", "Billboard", "Blob", "DepthEdge", "AmbientOcclusion", "Toon", "Toon", "SunShadow", "Water"}
	slots := [?]^^mat.Material{&s.ground, &s.toon, &s.hero, &s.sky, &s.coin, &s.blob, &s.edge, &s.ao, &s.grass_material, &s.flower_material, &s.sun_caster, &s.water}
	for name, i in names {
		material, reason := mat.material_create(&s.materials, name)
		if reason != "" {
			fail(app, reason)
			return
		}
		slots[i]^ = material
	}
	_ = mat.material_set_number(s.ground, "Toon_scene", "color", {0.52, 0.64, 0.30, 1})
	_ = mat.material_set_number(s.ground, "Toon_scene", "terrain", {1, 0, 0, 0})
	_ = mat.material_set_number(s.flower_material, "Toon_scene", "flower", {1, 0, 0, 0})
	_ = mat.material_set_number(s.edge, "DepthEdge_edge", "clip", {NEAR, FAR, 0, 0})
	_ = mat.material_set_number(s.ao, "AmbientOcclusion_ao", "clip", {NEAR, FAR, 0, 0})
	_ = mat.material_set_number(s.ao, "AmbientOcclusion_ao", "strength", {1.15, 0, 0, 0})
	_ = mat.material_set_number(s.ao, "AmbientOcclusion_ao", "radius", {0.65, 0, 0, 0})
	primitives := [?]dasset.Dasset_Primitive{cube(), sphere(), quad(), faceted_sphere(), tree_trunk(), grass_tuft(), meadow_flower(), faceted_sphere(true), pond_plane(), pond_terrain()}
	defer for &primitive in primitives do primitive_dispose(&primitive)
	meshes := [?]^foster.Mesh{&s.cube, &s.ball, &s.card, &s.facet, &s.trunk_mesh, &s.grass_mesh, &s.flower_mesh, &s.crown_mesh, &s.water_mesh, &s.terrain_mesh}
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
	if !sun_shadow_init(s, device) {
		fail(app, "Cannot bind sun depth texture")
		return
	}
	if reason := build_level(s); reason != "" {
		fail(app, reason)
		return
	}
	fmt.printf("Meadow: %d static instances in %d resident GPU batches\n", s.scenery_instances, len(s.scenery))
	reset_controller(s)
	if s.follow_shot do advance_controller(s, {}, 0)
	if s.camera_shot {
		s.player.position={-0.8,0,0.68}
		s.follow.pitch,s.follow.lift,s.follow.boom=0.12,0,7.5
		s.follow.focus=s.player.position+[3]f32{0,1.05,0}
		follow_camera_step(&s.follow,&s.camera,s.player,s.colliders[:],1.0/60.0)
	}
	if s.water_shot {
		world.camera3d_set_position(&s.camera, {-0.5, 3.6, 9.0})
		world.camera3d_set_target(&s.camera, {-4.0, 0.4, 2.0})
	}
	if s.shot && !s.follow_shot {
		// Preserve the fixed AO comparison view independently of the live controller.
		s.player.position = {3.0 * math.sin(f32(SHOT_TIME) * 0.7), 0, -0.4}
		world.camera3d_set_position(&s.camera, {0, 4.4, 10})
		world.camera3d_set_target(&s.camera, {0, 0.9, 0})
	}
}

// 先缩放、再绕 Y 轴旋转、最后平移（行向量约定 v * S * R * T）。
place :: proc(center, size: [3]f32, yaw: f32 = 0) -> world.Matrix4 {
	rotation := world.matrix4_from_quaternion({0, math.sin(yaw * 0.5), 0, math.cos(yaw * 0.5)})
	m := world.matrix4_multiply(world.matrix4_scaling(size[0], size[1], size[2]), rotation)
	return world.matrix4_multiply(m, world.matrix4_translation(center[0], center[1], center[2]))
}

update :: proc(app: ^foster.App) {
	s := foster.AppGetUserDataAs(app, State)
	keys := &app.Input.State.Keyboard
	if foster.KeyboardPressed(keys, .Escape) {
		foster.SetMouseRelativeMode(&app.Window, false)
		foster.Exit(app)
		return
	}
	if foster.KeyboardPressed(keys, .P) do s.paused = !s.paused
	if foster.KeyboardPressed(keys, .E) do s.flat = !s.flat
	if foster.KeyboardPressed(keys, .O) do s.no_ao = !s.no_ao
	if foster.KeyboardPressed(keys, .L) do s.no_shadows = !s.no_shadows
	mouse := &app.Input.State.Mouse
	active := foster.Focused(&app.Window) && !s.paused && !s.shot
	look := active && foster.MouseRightDown(mouse)
	changed := look != s.mouse_look
	if changed {
		foster.SetMouseRelativeMode(&app.Window, look)
		s.mouse_look = look
	}
	if !active {
		s.physics_accumulator, s.player.jump_buffer = 0, 0
		return
	}
	if foster.KeyboardPressed(keys, .R) do reset_controller(s)
	if look && !changed {
		s.follow.yaw -= mouse.Delta.X * 0.005
		s.follow.yaw = math.atan2(math.sin(s.follow.yaw), math.cos(s.follow.yaw))
		s.follow.pitch = math.clamp(s.follow.pitch + mouse.Delta.Y * 0.005, 0.12, 1.25)
	}
	s.follow.distance = math.clamp(s.follow.distance * math.pow(f32(0.88), mouse.Wheel.Y), 3, 12)
	input: Player_Input
	if foster.KeyboardDown(keys, .A) || foster.KeyboardDown(keys, .Left) do input.move.x -= 1
	if foster.KeyboardDown(keys, .D) || foster.KeyboardDown(keys, .Right) do input.move.x += 1
	if foster.KeyboardDown(keys, .W) || foster.KeyboardDown(keys, .Up) do input.move.y += 1
	if foster.KeyboardDown(keys, .S) || foster.KeyboardDown(keys, .Down) do input.move.y -= 1
	input.sprint = foster.KeyboardShift(keys)
	input.jump = foster.KeyboardPressed(keys, .Space)
	advance_controller(s, input, min(f32(app.Time.Delta), 0.1))
}

advance_controller :: proc(s: ^State, input: Player_Input, dt: f32) {
	s.time += dt
	s.physics_accumulator += dt
	if input.jump do s.player.jump_buffer = 0.12
	held := input
	held.jump = false
	for s.physics_accumulator >= PHYSICS_DT {
		player_step(&s.player, held, s.follow.yaw, s.colliders[:], PHYSICS_DT)
		s.physics_accumulator -= PHYSICS_DT
	}
	follow_camera_step(&s.follow, &s.camera, s.player, s.colliders[:], dt)
	// North stays up, but the map follows the player across the level.
	p := s.player.position
	world.camera3d_set_position(&s.map_camera, {p.x, p.y + 24, p.z + 0.01})
	world.camera3d_set_target(&s.map_camera, p)
}

// 窗口尺寸变化时重建目标：场景与 post 跟随放大倍数，小地图跟随 UI 缩放。
// 重建前 clear 记录器，释放它对旧资源的借用；AO 与描边材质重新绑定新的深度附件。
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
	foster.TargetDispose(&s.reflection)
	foster.TargetInit(&s.reflection, device, sw, sh, attachments[:], "pond reflection")
	if !mat.material_set_texture(s.water, "Water_water", "reflection", foster.TargetAttachment(&s.reflection, 0)) do return false
	world.camera3d_set_viewport(&s.camera, sw, sh)
	if !mat.material_set_texture(s.edge, "DepthEdge_edge", "depth", foster.TargetAttachment(&s.scene, 1)) do return false
	_ = mat.material_set_number(s.edge, "DepthEdge_edge", "texel", {1 / f32(sw), 1 / f32(sh), 0, 0})
	if !mat.material_set_texture(s.ao, "AmbientOcclusion_ao", "depth", foster.TargetAttachment(&s.scene, 1)) do return false
	_ = mat.material_set_number(s.ao, "AmbientOcclusion_ao", "texel", {1 / f32(sw), 1 / f32(sh), 0, 0})
	tan_half_fov := math.tan(s.camera.field_of_view * 0.5)
	_ = mat.material_set_number(s.ao, "AmbientOcclusion_ao", "projection", {tan_half_fov * f32(sw) / f32(sh), tan_half_fov, 0, 0})
	_ = mat.material_set_number(s.ao, "AmbientOcclusion_ao", "fog", {16, 75, 0, 0})
	s.ui_scale = max(1, f32(h) / 720)
	size := int(MAP_SIZE * s.ui_scale)
	if s.minimap.Width != size {
		foster.TargetDispose(&s.minimap)
		foster.TargetInit(&s.minimap, device, size, size, attachments[:], "stylized minimap")
	}
	return true
}

// 每个视图自己的视图块：相机轴来自该视图的相机；fog 为 0 时不加雾（小地图）。
scene_view :: proc(s: ^State, camera: ^world.Camera3D, fog: f32) -> Scene_View {
	right := world.camera3d_right(camera)
	up := linalg.cross(right, world.camera3d_forward(camera))
	sun := linalg.normalize(SUN_DIRECTION)
	return {
		sun_direction = {sun[0], sun[1], sun[2], 0},
		sun_color = {1.0, 0.95, 0.82, 1}, // a = 1：视图块有效
		shadow = {0.24, 0.27, 0.39, 0.55},
		fog_color = FOG_COLOR,
		fog = {16, 75, fog, 0},
		camera_right = {right[0], right[1], right[2], 0},
		camera_up = {up[0], up[1], up[2], 0},
		light_c0 = s.light_projection.c0, light_c1 = s.light_projection.c1,
		light_c2 = s.light_projection.c2, light_c3 = s.light_projection.c3,
		shadow_map = {1.0 / SHADOW_SIZE, 0.00045, 0.85, s.no_shadows ? f32(0) : 1},
		reflection_c0 = s.reflection_projection.c0, reflection_c1 = s.reflection_projection.c1,
		reflection_c2 = s.reflection_projection.c2, reflection_c3 = s.reflection_projection.c3,
		water_view = {WATER_HEIGHT, 0, fog, s.no_reflection ? f32(0) : 1},
	}
}

render :: proc(app: ^foster.App) {
	s := foster.AppGetUserDataAs(app, State)
	if s.failed do return
	if s.smoke {
		input := Player_Input{move = {0, 1}, sprint = true, jump = s.frame == 20}
		if s.frame > 70 { input.move = {1, 0}; s.follow.yaw += 0.012 }
		if s.frame > 100 do input.move = {}
		advance_controller(s, input, 1.0 / 60.0)
		if !player_clear(s.player.position, s.colliders[:]) ||
		   !camera_position_clear(s.camera.position, s.colliders[:], 0.1) {
			fail(app, "Controller smoke: player or camera overlaps level geometry")
			return
		}
		if s.frame == 80 do foster.SetWindowSize(&app.Window, {1366, 768})
	}
	device := &app.GraphicsDevice
	window := foster.DrawableTargetFromWindow(&app.Window)
	w, h := window.WidthInPixels, window.HeightInPixels
	if w <= 0 || h <= 0 do return
	if !resize(s, device, w, h) {
		fail(app, "Scene depth attachment cannot be sampled on this device")
		return
	}
	t := s.shot ? s.shot_time : s.time
	s.draw_calls = 0
	s.submitted_instances, s.shadow_draws = 0, 0
	s.light_view, s.light_projection = sun_shadow_matrix(s.player.position)
	s.reflection_camera = pond_camera(s.camera)
	s.reflection_projection = world.camera3d_view_projection(&s.reflection_camera)

	// 记录一次，提交给主视图的各阶段和小地图。
	r3d.clear(&s.renderer)
	if !record(s, t) {
		fail(app, "Cannot record scene")
		return
	}
	if !s.no_shadows {
		shadow_target := foster.DrawableTargetFromTarget(&s.sun_target)
		clear := [1]foster.Color{{255,255,255,255}}
		foster.GraphicsDeviceClear(device, shadow_target, clear[:], 1, 0, foster.ClearMask.Color | foster.ClearMask.Depth)
		if !submit(app, {target = shadow_target, view_projection = s.light_projection, view_matrix = s.light_view, time = t}, "shadow") do return
		s.shadow_draws = s.draw_calls
	}
	if !s.no_reflection && !render_reflection(app, t) do return

	// 主视图：天空 → 场景 → 剪影 → 角色本体。
	scene := foster.DrawableTargetFromTarget(&s.scene)
	colors := [1]foster.Color{{0, 0, 0, 255}}
	foster.GraphicsDeviceClear(device, scene, colors[:], 1, 0, foster.ClearMask.Color | foster.ClearMask.Depth)
	main_globals := scene_view(s, &s.camera, 1)
	main_view := r3d.View{target = scene, view_projection = world.camera3d_view_projection(&s.camera),
		view_matrix = world.camera3d_view(&s.camera), time = t, globals = mem.ptr_to_bytes(&main_globals)}
	for pass in ([?]mat.Pass_Id{"sky", "scene", "silhouette", "body"}) {
		if !submit(app, main_view, pass) do return
	}

	// AO 先于描边：共享 post 暂存，避免同时读写场景的颜色/深度附件。
	if !s.no_ao {
		if !post_process(app, s.ao, t) do return
	}
	if !s.flat {
		if !post_process(app, s.edge, t) do return
	}
	// Water writes its own depth after opaque post effects, before floating objects.
	if !submit(app, main_view, "water") do return
	if !submit(app, main_view, "transparent") do return

	// 小地图：同一份记录、另一台相机和另一份视图块（不加雾）；金币朝向俯视相机。
	minimap := foster.DrawableTargetFromTarget(&s.minimap)
	map_colors := [1]foster.Color{{40, 48, 70, 255}}
	foster.GraphicsDeviceClear(device, minimap, map_colors[:], 1, 0, foster.ClearMask.Color | foster.ClearMask.Depth)
	world.camera3d_set_viewport(&s.map_camera, s.minimap.Width, s.minimap.Height)
	map_globals := scene_view(s, &s.map_camera, 0)
	map_view := r3d.View{target = minimap, view_projection = world.camera3d_view_projection(&s.map_camera),
		view_matrix = world.camera3d_view(&s.map_camera), time = t, globals = mem.ptr_to_bytes(&map_globals)}
	for pass in ([?]mat.Pass_Id{"scene", "body", "water", "transparent"}) {
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
			name := s.flat ? "stylized3d_flat.png" : "stylized3d.png"
			fmt.printf("Instanced scene: %d static objects; %d total model draws (%d shadow); %d submitted instances across views/passes\n", s.scenery_instances, s.draw_calls, s.shadow_draws, s.submitted_instances)
			if s.no_ao do name = s.flat ? "stylized3d_flat_noao.png" : "stylized3d_noao.png"
			if s.follow_shot do name = "stylized3d-follow.png"
			if s.no_shadows do name = "stylized3d-noshadow.png"
			if s.wind_capture do name = s.shot_time == 0 ? "stylized3d-calm.png" : "stylized3d-gust.png"
			if s.smoke do name = "stylized3d-controller-smoke.png"
			if s.water_shot do name = "stylized3d-water.png"
			if s.camera_shot {
				name="stylized3d-camera.png"
				fmt.printf("Occluded camera: distance %.2f; camera position clear %v\n",s.follow.boom,camera_position_clear(s.camera.position,s.colliders[:],0.2))
			}
			if s.no_reflection do name = "stylized3d-water-flat.png"
			if s.smoke {
				fmt.printf("Controller feet %v; grounded %v; camera boom %.2f\n", s.player.position, s.player.grounded, s.follow.boom)
			}
			save_capture(s, name)
			foster.Exit(app)
		}
		if s.frame > 10 do s.measured_frames += 1
	}
}

// 读场景颜色与深度画到 post，再拷回颜色；深度保留给后面的半透明物体。
post_process :: proc(app: ^foster.App, material: ^mat.Material, t: f32) -> bool {
	s := foster.AppGetUserDataAs(app, State)
	if error := r2d.texture(&s.batch, foster.TargetAttachment(&s.scene, 0), foster.Matrix3x2Identity, material = material); error != .None {
		fail(app, mat.draw_error_text(error))
		return false
	}
	r2d.submit(&s.batch, {target = foster.DrawableTargetFromTarget(&s.post), time = t})
	_ = r2d.texture(&s.batch, foster.TargetAttachment(&s.post, 0), foster.Matrix3x2Identity)
	r2d.submit(&s.batch, {target = foster.DrawableTargetFromTarget(&s.scene), time = t})
	return true
}

// 天空跟随主相机；地面、方块、树冠、角色三段、圆影与金币各记录一次。
record :: proc(s: ^State, t: f32) -> bool {
	eye := s.camera.position
	ground_bounds, card_bounds := GROUND_BOUNDS, CARD_BOUNDS
	if r3d.model(&s.renderer, &s.ball, s.sky, place(eye, {80, 80, 80})) != .None do return false
	if r3d.model(&s.renderer, &s.terrain_mesh, s.ground, place({}, {1,1,1}), &ground_bounds) != .None do return false
	if !record_scenery(s) do return false
	if !record_player(s) do return false
	if r3d.model(&s.renderer, &s.water_mesh, s.water, place({POND_CENTER.x, WATER_HEIGHT, POND_CENTER.y}, {POND_RADIUS.x, 1, POND_RADIUS.y})) != .None do return false
	coins := s.coins
	blobs: [COIN_COUNT + 1]r3d.Model_Item
	count := 0
	for &coin, i in coins {
		coin.world.c1[3] += 0.12 * math.sin(t * 2 + f32(i)) // 上下浮动（平移在各列第 4 分量）
		blobs[count] = {place({coin.world.c0[3], terrain_height(coin.world.c0[3],coin.world.c2[3])+0.02, coin.world.c2[3]}, {0.34, 1, 0.34}), {1, 1, 1, 0.35}}
		count += 1
	}
	shadow_y := player_shadow_height(s.player, s.colliders[:])
	shadow_alpha := 0.55 / (1 + (s.player.position.y - shadow_y) * 0.5)
	blobs[count] = {place({s.player.position.x, shadow_y + 0.02, s.player.position.z}, {0.55, 1, 0.55}), {1, 1, 1, shadow_alpha}}
	count += 1
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
	s.submitted_instances += s.renderer.instances
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
save_capture :: proc(s: ^State, name: string, source: ^foster.Target = nil) {
	target := source == nil ? &s.final : source
	bytes := foster.TextureDownloadData(foster.TargetAttachment(target, 0))
	defer delete(bytes)
	w, h := target.Width, target.Height
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
	foster.SetMouseRelativeMode(&app.Window, false)
	r3d.dispose(&s.renderer) // 先释放借用网格、材质与贴图的记录器
	r2d.dispose(&s.batch)
	for &batch in s.scenery do r3d.model_buffer_dispose(&batch.instances)
	mat.material_library_dispose(&s.materials)
	r3d.mesh_dispose(&s.cube)
	r3d.mesh_dispose(&s.ball)
	r3d.mesh_dispose(&s.card)
	r3d.mesh_dispose(&s.facet)
	r3d.mesh_dispose(&s.crown_mesh)
	r3d.mesh_dispose(&s.trunk_mesh)
	r3d.mesh_dispose(&s.grass_mesh)
	r3d.mesh_dispose(&s.flower_mesh)
	r3d.mesh_dispose(&s.water_mesh)
	r3d.mesh_dispose(&s.terrain_mesh)
	foster.TargetDispose(&s.reflection)
	foster.TargetDispose(&s.sun_target)
	foster.TargetDispose(&s.scene)
	foster.TargetDispose(&s.post)
	foster.TargetDispose(&s.minimap)
	foster.TargetDispose(&s.final)
	delete(s.colliders)
}
