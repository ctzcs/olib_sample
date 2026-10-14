package main

// forward3d：参考前向渲染器的演示场景。
//
// kit/rendering3d 只提供机制（Mesh 上传、泛型排序队列、字节码选择、std140、
// DebugDraw3D）；光照与材质在本目录的 renderer / uniforms / material / shaders 里，
// 游戏按自己的画风复制改写。
//
// 场景：地面 + 不透明立方体与金属球 + 两个半透明物体（检验后到前排序），
// 方向光 + 绕场景转的点光 + 一盏聚光，地面上叠调试网格。
// 参数：shot —— 渲染若干帧后把画面写到 forward3d.png 并退出（固定时间，画面可复现）。

import "core:fmt"
import "core:math"
import "core:os"

import dasset "olib:core/dasset"
import app "olib:kit/app"
import r3d "olib:kit/rendering3d"
import world "olib:kit/world"
import foster "olib:foster"

// 分区：
//   状态 —— 窗口 / 场景对象 / 渲染资源
//   生命周期 —— main / startup / shutdown
//   帧 —— update / render / 截图

// ==============================================================================
// 状态
// ==============================================================================

VIEW_W :: 1280
VIEW_H :: 720
SHOT_TIME :: f32(0.8) // shot 模式下固定的场景时间（秒）
SHOT_FRAME :: 3

Shape :: enum {
	Ground,
	Cube,
	Metal_Sphere,
	Glass_Sphere,
	Glass_Cube,
}

Scene_Object :: struct {
	mesh:     foster.Mesh,
	material: Standard_Material_3D,
	position: [3]f32,
	spin:     f32, // 绕 Y 轴角速度（弧度/秒）
}

game: foster.App
renderer: Renderer
debug: r3d.Debug_Draw_3D
queue: r3d.Render_Queue(Standard_Draw)
camera: world.Camera3D
objects: [Shape]Scene_Object
scene_target: foster.Target // 颜色 + 深度；3D 先画在这里，再合成到窗口
compose: foster.Batcher
scene_time: f32
frame: int
shot: bool

// ==============================================================================
// 生命周期
// ==============================================================================

main :: proc() {
	shot = app.has_arg(os.args, "shot")
	foster.InitApp(&game, foster.DefaultAppConfig("forward3d - reference renderer", VIEW_W, VIEW_H))
	defer foster.Dispose(&game)
	game.StartupProc = startup
	game.UpdateProc = update
	game.RenderProc = render
	game.ShutdownProc = shutdown
	foster.Run(&game)
}

startup :: proc(g: ^foster.App) {
	device := &g.GraphicsDevice
	if !renderer_init(&renderer, device) {
		fmt.eprintln("forward3d: 当前图形驱动没有可用的着色器字节码:", device.Driver)
		foster.Exit(g)
		return
	}
	fmt.println("forward3d: driver", device.Driver)
	r3d.debug_draw_init(&debug, device)
	foster.BatcherInit(&compose, device, "forward3d compose")
	attachments := [2]foster.TargetAttachmentSpec{{Format = .Color}, {Format = .Depth32}}
	foster.TargetInit(&scene_target, device, VIEW_W, VIEW_H, attachments[:], "forward3d color + depth")

	world.camera3d_init(&camera, VIEW_W, VIEW_H)
	world.camera3d_set_position(&camera, {0, 3.2, 8.5})
	world.camera3d_set_target(&camera, {0, 0.6, 0})

	add_object(.Ground, make_cube(1, material(0.42, 0.44, 0.40, 1, 0, 0.9)), {0, -0.51, 0})
	add_object(.Cube, make_cube(1.4, material(0.80, 0.22, 0.18, 1, 0, 0.5)), {-2.2, 0.7, -0.3}, spin = 0.6)
	// 纯金属没有环境贴图（IBL）时只反射直接光，看起来偏暗：这正是“外观由游戏决定”的部分。
	add_object(.Metal_Sphere, make_sphere(0.9, 24, 48, material(0.95, 0.75, 0.35, 1, 1, 0.3)), {0.3, 0.9, -0.8})
	add_object(.Glass_Sphere, make_sphere(0.75, 24, 48, material(0.25, 0.55, 0.95, 0.45, 0, 0.15)), {2.2, 0.75, 0.6})
	add_object(.Glass_Cube, make_cube(0.9, material(0.30, 0.90, 0.45, 0.5, 0, 0.4)), {1.3, 0.45, 2.0}, spin = -0.4)
}

shutdown :: proc(g: ^foster.App) {
	for &object in objects {
		r3d.mesh3d_dispose(&object.mesh)
	}
	r3d.queue_dispose(&queue)
	r3d.debug_draw_dispose(&debug)
	foster.TargetDispose(&scene_target)
	foster.BatcherDispose(&compose)
	renderer_dispose(&renderer)
}

// 基础色 + 不透明度 + 金属度 + 粗糙度；alpha < 1 走 Blend（透明队列）。
material :: proc(r, g, b, alpha, metallic, roughness: f32) -> dasset.Dasset_Material {
	m := dasset.DASSET_MATERIAL_DEFAULT
	m.base_color_factor = {r, g, b, alpha}
	m.metallic = metallic
	m.roughness = roughness
	if alpha < 1 {
		m.alpha_mode = .Blend
	}
	return m
}

// 上传 primitive 后即释放 CPU 侧数据（Mesh 已持有 GPU 缓冲）。
add_object :: proc(shape: Shape, primitive: dasset.Dasset_Primitive, position: [3]f32, spin: f32 = 0) {
	p := primitive
	defer primitive_dispose(&p)
	object := &objects[shape]
	r3d.mesh3d_upload(&object.mesh, &game.GraphicsDevice, &p, fmt.tprint(shape))
	object.material = standard_material_from_dasset(&p.material)
	object.position = position
	object.spin = spin
}

// ==============================================================================
// 帧
// ==============================================================================

update :: proc(g: ^foster.App) {
	scene_time = shot ? SHOT_TIME : scene_time + min(g.Time.Delta, 0.1)
}

render :: proc(g: ^foster.App) {
	device := &g.GraphicsDevice
	offscreen := foster.DrawableTargetFromTarget(&scene_target)
	colors := [1]foster.Color{{18, 22, 28, 255}}
	foster.GraphicsDeviceClear(device, offscreen, colors[:], 1, 0, foster.ClearMask.Color | foster.ClearMask.Depth)

	// ---- 提交并排序：payload 是本示例自己定义的 Standard_Draw ----
	r3d.queue_clear(&queue)
	for &object, shape in objects {
		world_matrix := object_world(&object, shape)
		draw := Standard_Draw{mesh = &object.mesh, material = object.material, world = world_matrix}
		r3d.queue_submit(&queue, draw, r3d.queue_view_depth(&camera, world_matrix), object.material.state.transparent)
	}
	r3d.queue_sort(&queue)

	// ---- 灯光 ----
	light := make_light_block({-0.45, -1, -0.35}, {0.16, 0.17, 0.2}, {0.95, 0.92, 0.85}, camera.position, 0)
	orbit := scene_time * 0.9
	point_lights := [1]Point_Light{{
		position  = {3 * math.cos(orbit), 1.4, 3 * math.sin(orbit)},
		range     = 6,
		color     = {1, 0.55, 0.2},
		intensity = 2.5,
	}}
	spot_lights := [1]Spot_Light{{
		position    = {-2.6, 4, 2.4},
		direction   = {0.2, -1, -0.3},
		range       = 8,
		color       = {0.5, 0.7, 1},
		intensity   = 2,
		inner_angle = SPOT_LIGHT_DEFAULT_INNER,
		outer_angle = SPOT_LIGHT_DEFAULT_OUTER,
	}}

	renderer_render(&renderer, &camera, &light, point_lights[:], spot_lights[:], offscreen, &queue, nil)

	// ---- 调试线：地面网格 + 点光位置 ----
	r3d.debug_draw_grid(&debug, 6, 1, {1, 1, 1, 0.12})
	r3d.debug_draw_sphere(&debug, point_lights[0].position, 0.12, {1, 0.6, 0.2, 1}, segments = 12)
	r3d.debug_draw_render(&debug, offscreen, &camera)

	// ---- 合成到窗口（保持宽高比居中）----
	window := foster.DrawableTargetFromWindow(&g.Window)
	w, h := f32(window.WidthInPixels), f32(window.HeightInPixels)
	fit := min(w / VIEW_W, h / VIEW_H)
	x0, y0 := (w - VIEW_W * fit) * 0.5, (h - VIEW_H * fit) * 0.5
	x1, y1 := x0 + VIEW_W * fit, y0 + VIEW_H * fit
	foster.BatcherClear(&compose)
	foster.BatcherPushSampler(&compose, foster.TextureSamplerMake(.Linear, .Clamp))
	foster.BatcherQuadTexture(
		&compose,
		foster.TargetAttachment(&scene_target),
		{x0, y0}, {x1, y0}, {x1, y1}, {x0, y1},
		{0, 0}, {1, 0}, {1, 1}, {0, 1},
		foster.White,
	)
	foster.BatcherPopSampler(&compose)
	foster.GraphicsDeviceClear(device, window, {0, 0, 0, 255})
	foster.BatcherRender(&compose, window)

	frame += 1
	if shot && frame >= SHOT_FRAME {
		save_capture()
		foster.Exit(g)
	}
}

object_world :: proc(object: ^Scene_Object, shape: Shape) -> world.Matrix4 {
	scale := shape == .Ground ? world.matrix4_scaling(14, 1, 14) : world.MATRIX4_IDENTITY
	half := object.spin * scene_time * 0.5
	rotation := world.matrix4_from_quaternion({0, math.sin(half), 0, math.cos(half)})
	translation := world.matrix4_translation(object.position[0], object.position[1], object.position[2])
	// 行向量约定：先缩放、再旋转、最后平移
	return world.matrix4_multiply(world.matrix4_multiply(scale, rotation), translation)
}

save_capture :: proc() {
	bytes := foster.TextureDownloadData(foster.TargetAttachment(&scene_target, 0))
	defer delete(bytes)
	if len(bytes) < VIEW_W * VIEW_H * 4 {
		fmt.eprintln("forward3d: 截图回读失败")
		return
	}
	image := foster.ImageMake(VIEW_W, VIEW_H)
	defer foster.ImageDispose(&image)
	for &pixel, i in image.Pixels {
		pixel = {bytes[i * 4], bytes[i * 4 + 1], bytes[i * 4 + 2], bytes[i * 4 + 3]}
	}
	fmt.println("forward3d.png", foster.ImageWritePng(&image, "forward3d.png"))
}
