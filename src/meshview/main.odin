package main

// meshview —— 网格线框与统计查看器，按键逐级简化（olib:core/meshutil + gizmo.wireframe_draw）。
// 参数：[模型.dasset] [shot]。不传模型时使用内置的起伏球（带 UV 缝和一个故意留下的破洞）。
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:os"
import "core:strings"

import dasset "olib:core/dasset"
import debug "olib:core/debug"
import meshutil "olib:core/meshutil"
import foster "olib:foster"
import appkit "olib:kit/app"
import gizmo "olib:kit/gizmo"
import r2d "olib:kit/rendering/2d"
import r3d "olib:kit/rendering/3d"
import mat "olib:kit/rendering/material"
import world "olib:kit/world"

// 分区：状态与生命周期 / 网格与简化级别 / 输入 / 绘制 / 内置网格

// 每级目标面数减半；误差超过此值（相对包围盒最长边）时停止，不再增加级别。
MAX_ERROR :: 0.05

// ==============================================================================
// 状态与生命周期
// ==============================================================================

Viewer :: struct {
	materials: mat.Material_Library,
	renderer: r3d.Render3D,
	material: ^mat.Material,
	wire: gizmo.Renderer3D,
	batch: r2d.Render2D,
	font_source: foster.Font,
	font: foster.SpriteFont,
	target: foster.Target,
	camera: world.Camera3D,
	// 轨道相机：左键旋转，右键/中键平移，滚轮缩放，F 复位。
	yaw, pitch, distance: f32,
	focus: [3]f32,
	mouse_last: [2]f32,
	// 原始网格：所有 primitive 合并为静态顶点，简化总是从这里开始。
	name: string,
	source_vertices: []dasset.Dasset_Vertex,
	source_indices: []u32,
	source_positions: [][3]f32,
	// 当前级别：顶点经 compact 只保留用到的部分，edges/stats 随级别重建。
	level: int,
	error: f32,
	vertices: []dasset.Dasset_Vertex,
	indices: []u32,
	positions: [][3]f32,
	edges: []meshutil.Edge,
	stats: meshutil.Stats,
	mesh: foster.Mesh,
	limit_reached: bool, // 上一次简化因误差上限没有减少面数
	solid, wireframe, xray: bool,
	shot, failed: bool,
	frame: int,
}

main :: proc() {
	if !run_app() do os.exit(1)
}

run_app :: proc() -> bool {
	tracking := debug.track_create()
	defer debug.track_destroy(tracking)
	context.allocator = tracking
	s: Viewer
	s.shot = appkit.has_arg(os.args, "shot")
	s.solid = true
	s.wireframe = true
	s.name = "built-in sphere"
	for arg in os.args[1:] {
		if strings.has_suffix(arg, ".dasset") do s.name = arg
	}
	config := foster.DefaultAppConfig("MeshView", 1280, 720)
	config.WindowTitle = "olib - MeshView | S/A: simplify / back | W: wire | M: model | X: x-ray | F: reset view"
	app: foster.App
	foster.InitApp(&app, config)
	foster.AppSetUserData(&app, &s)
	defer {
		foster.Dispose(&app)
		// 交换链 CPU 包装数组由宿主释放，不拥有 SDL 交换链纹理。
		delete(app.GraphicsDevice.WindowRenderTarget.Attachments)
		app.GraphicsDevice.WindowRenderTarget.Attachments = nil
	}
	app.StartupProc = startup
	app.ShutdownProc = shutdown
	app.UpdateProc = update
	app.RenderProc = render
	foster.Run(&app)
	return !s.failed
}

fail :: proc(app: ^foster.App, reason: string) {
	fmt.eprintln("MeshView:", reason)
	foster.AppGetUserDataAs(app, Viewer).failed = true
	foster.Exit(app)
}

startup :: proc(app: ^foster.App) {
	s := foster.AppGetUserDataAs(app, Viewer)
	device := &app.GraphicsDevice
	s.materials = {device = device}
	if reason := mat.material_register_directory(&s.materials, #load_directory("shaders/Compiled")); reason != "" {
		fail(app, reason)
		return
	}
	reason: string
	s.material, reason = mat.material_create(&s.materials, "MeshView")
	if reason == "" do reason = r3d.init(&s.renderer, &s.materials)
	if reason == "" do reason = r2d.init(&s.batch, &s.materials)
	if reason == "" && !gizmo.renderer3d_init(&s.wire, device) do reason = "Cannot create wireframe renderer"
	if reason != "" {
		fail(app, reason)
		return
	}
	for path in ([]string{"C:/Windows/Fonts/segoeui.ttf", "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
		"/System/Library/Fonts/Supplemental/Arial.ttf"}) {
		if !os.exists(path) do continue
		s.font_source = foster.FontLoadFile(path)
		s.font = foster.SpriteFontMakeGPU(device, &s.font_source, 16)
		break
	}
	if s.font_source.Disposed || len(s.font.Characters) == 0 {
		fail(app, "no usable font")
		return
	}
	ok := s.name == "built-in sphere" ? built_in(s) : load_dasset(s, s.name)
	if !ok {
		fail(app, fmt.tprintf("cannot load %s", s.name))
		return
	}
	s.source_positions = make([][3]f32, len(s.source_vertices))
	for v, i in s.source_vertices do s.source_positions[i] = v.position
	world.camera3d_init(&s.camera, 1280, 720)
	camera_reset(s)
	if !set_level(s, device, 0) do fail(app, "cannot upload mesh")
}

shutdown :: proc(app: ^foster.App) {
	s := foster.AppGetUserDataAs(app, Viewer)
	r3d.dispose(&s.renderer)
	r3d.mesh_dispose(&s.mesh)
	level_dispose(s)
	delete(s.source_vertices)
	delete(s.source_indices)
	delete(s.source_positions)
	gizmo.renderer3d_destroy(&s.wire)
	foster.TargetDispose(&s.target)
	foster.SpriteFontDispose(&s.font)
	foster.FontDispose(&s.font_source)
	r2d.dispose(&s.batch)
	mat.material_library_dispose(&s.materials)
}

// ==============================================================================
// 网格与简化级别
// ==============================================================================

// 级别 n 的目标索引数为原始的 1/2^n。误差超限而没有减少面数时保持原级别并返回 false。
set_level :: proc(s: ^Viewer, device: ^foster.GraphicsDevice, level: int) -> bool {
	indices: []u32
	error: f32
	if level == 0 {
		indices = make([]u32, len(s.source_indices))
		copy(indices, s.source_indices)
	} else {
		ok: bool
		indices, error, ok = meshutil.simplify(s.source_positions, s.source_indices,
			len(s.source_indices) >> uint(level), MAX_ERROR)
		if !ok || (level > s.level && len(indices) >= len(s.indices)) {
			delete(indices)
			s.limit_reached = true
			return false
		}
	}
	vertices, _ := meshutil.compact(s.source_vertices, indices)
	r3d.clear(&s.renderer) // 记录借用 Mesh，替换前先清空
	r3d.mesh_dispose(&s.mesh)
	primitive := dasset.Dasset_Primitive{vertices = vertices, indices = indices, skin_index = -1}
	if !r3d.mesh_upload(&s.mesh, device, &primitive, "meshview") {
		delete(vertices)
		delete(indices)
		return false
	}
	level_dispose(s)
	s.level = level
	s.error = error
	s.vertices = vertices
	s.indices = indices
	s.positions = meshutil.primitive_positions(&primitive)
	s.edges, _ = meshutil.edges(s.positions, s.indices)
	s.stats = meshutil.stats(s.positions, s.indices)
	s.limit_reached = false
	return true
}

level_dispose :: proc(s: ^Viewer) {
	delete(s.vertices)
	delete(s.indices)
	delete(s.positions)
	delete(s.edges)
	s.vertices = nil
	s.indices = nil
	s.positions = nil
	s.edges = nil
}

// 合并全部 primitive；蒙皮顶点按绑定姿态转成静态顶点。
load_dasset :: proc(s: ^Viewer, path: string) -> bool {
	data, read_error := os.read_entire_file(path, context.allocator)
	if read_error != nil do return false
	defer delete(data)
	model, error := dasset.dasset_read(data)
	if error != .None do return false
	defer dasset.dasset_model_dispose(&model)
	vertices: [dynamic]dasset.Dasset_Vertex
	indices: [dynamic]u32
	for &p in model.primitives {
		base := u32(len(vertices))
		if dasset.dasset_primitive_is_skinned(&p) {
			for v in p.skin_vertices {
				append(&vertices, dasset.Dasset_Vertex{v.position, v.normal, v.uv, v.tangent})
			}
		} else {
			append(&vertices, ..p.vertices)
		}
		for index in p.indices do append(&indices, base+index)
	}
	s.source_vertices = vertices[:]
	s.source_indices = indices[:]
	return len(indices) > 0
}

// ==============================================================================
// 输入
// ==============================================================================

update :: proc(app: ^foster.App) {
	s := foster.AppGetUserDataAs(app, Viewer)
	if s.failed do return
	s.frame += 1
	keys := &app.Input.State.Keyboard
	device := &app.GraphicsDevice
	if foster.KeyboardPressed(keys, .Escape) do foster.Exit(app)
	if foster.KeyboardPressed(keys, .W) do s.wireframe = !s.wireframe
	if foster.KeyboardPressed(keys, .M) do s.solid = !s.solid
	if foster.KeyboardPressed(keys, .X) do s.xray = !s.xray
	if foster.KeyboardPressed(keys, .F) do camera_reset(s)
	if foster.KeyboardPressed(keys, .S) || foster.KeyboardPressed(keys, .Right) {
		set_level(s, device, s.level+1)
	}
	if (foster.KeyboardPressed(keys, .A) || foster.KeyboardPressed(keys, .Left)) && s.level > 0 {
		set_level(s, device, s.level-1)
	}
	// 自动验收：原始网格截一张，简化三级后再截一张。
	if s.shot && s.frame == 30 {
		for _ in 0..<3 do set_level(s, device, s.level+1)
	}
	camera_input(s, &app.Input.State.Mouse)
}

camera_reset :: proc(s: ^Viewer) {
	bounds := dasset.DASSET_BOUNDS_EMPTY
	for p in s.source_positions {
		bounds.min = linalg.min(bounds.min, p)
		bounds.max = linalg.max(bounds.max, p)
	}
	radius := max(linalg.length(bounds.max-bounds.min)*0.5, 0.001)
	s.focus = (bounds.min+bounds.max)*0.5
	s.distance = radius*2.4
	s.yaw = 0.35
	s.pitch = 0.3
	world.camera3d_set_near_clip(&s.camera, radius*0.01)
	world.camera3d_set_far_clip(&s.camera, radius*50)
}

camera_input :: proc(s: ^Viewer, mouse: ^foster.MouseState) {
	position := [2]f32{mouse.Position.X, mouse.Position.Y}
	delta := position-s.mouse_last // 自己求差：一帧多个移动事件时 Mouse.Delta 只保留最后一个
	s.mouse_last = position
	if foster.MouseLeftDown(mouse) {
		s.yaw -= delta.x*0.006
		s.pitch = math.clamp(s.pitch+delta.y*0.006, -1.5, 1.5)
	}
	if foster.MouseRightDown(mouse) || foster.MouseMiddleDown(mouse) {
		forward := world.camera3d_forward(&s.camera)
		right := world.camera3d_right(&s.camera)
		up := linalg.cross(right, forward)
		s.focus += (up*delta.y-right*delta.x)*(s.distance*0.0015)
	}
	if mouse.Wheel.Y != 0 do s.distance *= math.pow(f32(0.88), mouse.Wheel.Y)
}

// ==============================================================================
// 绘制
// ==============================================================================

render :: proc(app: ^foster.App) {
	s := foster.AppGetUserDataAs(app, Viewer)
	if s.failed do return
	device := &app.GraphicsDevice
	window := foster.DrawableTargetFromWindow(&app.Window)
	w := window.WidthInPixels
	h := window.HeightInPixels
	if w <= 0 || h <= 0 do return
	if s.target.Width != w || s.target.Height != h {
		foster.TargetDispose(&s.target)
		foster.TargetInit(&s.target, device, w, h,
			[]foster.TargetAttachmentSpec{{.Color, .Four}, {.Depth32, .Four}}, "meshview")
	}
	target := foster.DrawableTargetFromTarget(&s.target)
	colors := [1]foster.Color{{24, 28, 36, 255}}
	foster.GraphicsDeviceClear(device, target, colors[:], 1, 0, foster.ClearMask.Color | foster.ClearMask.Depth)
	ui_scale := f32(w)/f32(max(1, foster.Size(&app.Window).X))

	world.camera3d_set_viewport(&s.camera, w, h)
	orbit := [3]f32{math.sin(s.yaw)*math.cos(s.pitch), math.sin(s.pitch), math.cos(s.yaw)*math.cos(s.pitch)}
	world.camera3d_set_target(&s.camera, s.focus)
	world.camera3d_set_position(&s.camera, s.focus+orbit*s.distance)
	if s.solid {
		r3d.clear(&s.renderer)
		view := r3d.View{target = target, view_projection = world.camera3d_view_projection(&s.camera),
			view_matrix = world.camera3d_view(&s.camera)}
		error := r3d.model(&s.renderer, &s.mesh, s.material, world.MATRIX4_IDENTITY, &s.stats.bounds)
		if error == .None do error = r3d.submit(&s.renderer, view)
		if error != .None {
			fail(app, mat.draw_error_text(error))
			return
		}
	}
	if s.wireframe {
		style := gizmo.DEFAULT_WIREFRAME_STYLE
		if s.xray do style.hidden_alpha = 1
		gizmo.wireframe_draw(&s.wire, target, &s.camera, s.positions, s.edges, world.MATRIX4_IDENTITY,
			{0, 0, f32(w), f32(h)}, ui_scale, style)
	}
	draw_overlay(s, f32(h), ui_scale)
	r2d.submit(&s.batch, {target = target})

	r2d.quad_texture(&s.batch, foster.TargetAttachment(&s.target),
		{0, 0}, {f32(w), 0}, {f32(w), f32(h)}, {0, f32(h)}, {0, 0}, {1, 0}, {1, 1}, {0, 1}, foster.White)
	r2d.submit(&s.batch, {target = window})
	if s.shot && (s.frame == 20 || s.frame == 50) {
		save_capture(s, s.frame == 20 ? "meshview.png" : "meshview-simplified.png")
		if s.frame == 50 do foster.Exit(app)
	}
}

// 统计与图例画在最终像素目标上，不随场景缩放。
draw_overlay :: proc(s: ^Viewer, height, scale: f32) {
	st := s.stats
	source_triangles := len(s.source_indices)/3
	lines := [?]string{
		s.name,
		fmt.tprintf("Level %d   error %.2f%%   (limit %.0f%%)", s.level, s.error*100, MAX_ERROR*100),
		fmt.tprintf("Triangles %d / %d  (%.0f%%)", st.triangles, source_triangles,
			f32(st.triangles)*100/f32(max(1, source_triangles))),
		fmt.tprintf("Vertices %d   unique positions %d", st.used_vertices, st.unique_positions),
		fmt.tprintf("Edges %d   degenerate %d", st.edges, st.degenerate_triangles),
	}
	panel_height := f32(len(lines)+4)*22*scale+16*scale
	r2d.rect(&s.batch, {12*scale, 12*scale, 340*scale, panel_height}, {10, 13, 18, 200})
	y := 20*scale
	for line in lines {
		r2d.text(&s.batch, &s.font, line, {24*scale, y}, foster.White, 16*scale)
		y += 22*scale
	}
	style := gizmo.DEFAULT_WIREFRAME_STYLE
	legend := [3]struct {
		kind: meshutil.Edge_Kind,
		label: string,
	}{
		{.Seam, fmt.tprintf("Seam edges %d (UV/normal splits)", st.seam_edges)},
		{.Border, fmt.tprintf("Border edges %d (holes)", st.border_edges)},
		{.Non_Manifold, fmt.tprintf("Non-manifold edges %d", st.non_manifold_edges)},
	}
	for item in legend {
		r2d.rect(&s.batch, {24*scale, y+5*scale, 18*scale, 4*scale}, style.colors[item.kind])
		r2d.text(&s.batch, &s.font, item.label, {50*scale, y}, foster.White, 16*scale)
		y += 22*scale
	}
	if s.limit_reached {
		r2d.text(&s.batch, &s.font, fmt.tprintf("Error limit %.0f%% reached", MAX_ERROR*100), {24*scale, y},
			{255, 180, 97, 255}, 16*scale)
	}
	help := "S / Right: simplify   A / Left: back   W: wireframe   M: model   X: x-ray   F: reset view   Drag: orbit / pan   Wheel: zoom"
	r2d.text(&s.batch, &s.font, help, {24*scale, height-32*scale}, {180, 190, 200, 255}, 16*scale)
}

// 读回离屏目标，写到示例仓库根目录的 library/screenshots。
save_capture :: proc(s: ^Viewer, name: string) {
	bytes := foster.TextureDownloadData(foster.TargetAttachment(&s.target, 0))
	defer delete(bytes)
	w := s.target.Width
	h := s.target.Height
	if len(bytes) < w*h*4 {
		fmt.eprintln("MeshView: capture readback failed")
		s.failed = true
		return
	}
	image := foster.ImageMake(w, h)
	defer foster.ImageDispose(&image)
	for &pixel, i in image.Pixels do pixel = {bytes[i*4], bytes[i*4+1], bytes[i*4+2], bytes[i*4+3]}
	directory :: #directory + "/../../library/screenshots"
	_ = os.make_directory_all(directory)
	fmt.println(name, foster.ImageWritePng(&image, fmt.tprintf("%s/%s", directory, name)))
}

// ==============================================================================
// 内置网格
// ==============================================================================

// 起伏的 UV 球：经线 0/2π 处重复顶点形成属性缝；赤道正面挖掉几个四边形，展示破洞的边界色。
built_in :: proc(s: ^Viewer, segments := 96, rings := 48) -> bool {
	row := segments+1
	vertices := make([]dasset.Dasset_Vertex, (rings+1)*row)
	for r in 0..=rings {
		theta := f32(r)/f32(rings)*math.PI
		for n in 0..=segments {
			phi := f32(n%segments)/f32(segments)*2*math.PI
			radius := 1+0.12*math.sin(5*phi)*math.sin(3*theta)
			direction := [3]f32{math.sin(theta)*math.cos(phi), math.cos(theta), math.sin(theta)*math.sin(phi)}
			// f32 的 sin(π) 不为 0：两极必须写成精确同一点，否则南极扇形散开成一圈细小破洞。
			if r == 0 || r == rings {
				direction = {0, r == 0 ? 1 : -1, 0}
				radius = 1
			}
			vertices[r*row+n] = {position = direction*radius, uv = {f32(n)/f32(segments), f32(r)/f32(rings)},
				tangent = {-math.sin(phi), 0, math.cos(phi), 1}}
		}
	}
	indices: [dynamic]u32
	for r in 0..<rings {
		for n in 0..<segments {
			if r >= rings/2-2 && r < rings/2+1 && n >= segments/4-2 && n < segments/4+2 do continue
			a := u32(r*row+n)
			b := a+u32(row)
			if r > 0 do append(&indices, a, a+1, b)
			if r < rings-1 do append(&indices, a+1, b+1, b)
		}
	}
	// 法线按位置累加面法线（缝两侧共享），两极顶点各自重复也一样平滑。
	normals := make([][3]f32, len(vertices))
	defer delete(normals)
	slot :: proc(index, row, rings: int) -> int {
		r := index/row
		n := index%row%(row-1)
		if r == 0 do return 0
		if r == rings do return rings*row
		return r*row+n
	}
	for t := 0; t < len(indices); t += 3 {
		p0 := vertices[indices[t]].position
		face := linalg.cross(vertices[indices[t+1]].position-p0, vertices[indices[t+2]].position-p0)
		for k in 0..<3 do normals[slot(int(indices[t+k]), row, rings)] += face
	}
	for &v, i in vertices do v.normal = linalg.normalize0(normals[slot(i, row, rings)])
	s.source_vertices = vertices
	s.source_indices = indices[:]
	return true
}
