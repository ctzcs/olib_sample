package main

// 3D 书的 GPU 绘制：书壳网格、纸张网格上传、带深度的离屏渲染。

// 分区：
//   类型与书壳尺寸 —— Book_Vertex / Binding_Box / Book_Renderer
//   生命周期 —— renderer_init / renderer_dispose / ensure_target
//   网格构建 —— upload_sheet / append_box / build_binding_mesh
//   绘制 —— draw_mesh3d / render_book3d

import foster "olib:foster"
import mat "olib:kit/rendering/material"
import r3d "olib:kit/rendering/3d"

// ==============================================================================
// 类型与书壳尺寸
// ==============================================================================

// 所有网格共用一种顶点格式：纸采样页面纹理；书壳采样 1x1 白纹理，只显示顶点色。
Book_Vertex :: struct {
	position, normal: foster.Vec3,
	uv:               foster.Vec2,
	color:            [4]f32,
}

// 书的剖面（z 指向读者，未按比例）：
//
//   z =  0      ===== 左侧纸 =====  |  ===== 右侧纸 =====
//   z = -1      +--- 书页堆 ----+  书脊  +---- 书页堆 ---+
//   z = -16     +---------------+   |    +---------------+
//   z = -24  ==================== 皮革封面 ====================
//   z = -24.4          （烫金边框，书翻过来时可见）
Binding_Box :: struct {
	lo, hi: foster.Vec3,
	color:  [4]f32,
}

LEATHER :: [4]f32{0.17, 0.27, 0.25, 1}
PAPER_BLOCK :: [4]f32{0.84, 0.80, 0.65, 1}
PAPER_STRIPE :: [4]f32{0.63, 0.58, 0.43, 1}
SPINE :: [4]f32{0.16, 0.23, 0.20, 1}
GILT :: [4]f32{0.66, 0.55, 0.31, 1}

// 实心部分，拾取时视为不透明。build_binding_mesh 额外加的装饰只画不拾取。
binding_boxes :: [3]Binding_Box{
	{{-375, -265, -24}, {375, 265, -16}, LEATHER},   // 封面
	{{-363, -251, -16}, {-2, 251, -1}, PAPER_BLOCK}, // 左侧书页堆
	{{2, -251, -16}, {363, 251, -1}, PAPER_BLOCK},   // 右侧书页堆
}

Book_Mesh :: enum {
	Left_Sheet,
	Right_Sheet,
	Turning_Sheet,
	Binding,
}

// 所有权：renderer_init 创建，renderer_dispose 释放；target 在首次绘制和窗口
// 尺寸变化时由 ensure_target 重建。
Book_Renderer :: struct {
	vertex_shader:   foster.Shader,
	fragment_shader: foster.Shader,
	material:        foster.Material,
	meshes:          [Book_Mesh]foster.Mesh, // 每次绘制各用独立的 GPU 缓冲
	target:          foster.Target,          // 颜色 + 深度，之后合成到窗口
	white:           foster.Texture,
}

// ==============================================================================
// 生命周期
// ==============================================================================

renderer_init :: proc(r: ^Book_Renderer, app: ^foster.App) -> bool {
	device := &app.GraphicsDevice
	if !mat.shader_driver_supported(device.Driver) do return false
	vs := mat.shader_pick(device.Driver, {
		spv = #load("shaders/Compiled/Book.vertex.spv"),
		dxil = #load("shaders/Compiled/Book.vertex.dxil"),
	})
	fs := mat.shader_pick(device.Driver, {
		spv = #load("shaders/Compiled/Book.fragment.spv"),
		dxil = #load("shaders/Compiled/Book.fragment.dxil"),
	})
	foster.ShaderInit(
		&r.vertex_shader,
		device,
		{Stage = .Vertex, Code = vs, UniformBufferCount = 1, EntryPoint = "vertex_main"},
		"book 3D vertex",
	)
	foster.ShaderInit(
		&r.fragment_shader,
		device,
		{Stage = .Fragment, Code = fs, SamplerCount = 2, EntryPoint = "fragment_main"},
		"book double sided paper",
	)
	if r.vertex_shader.Resource == nil || r.fragment_shader.Resource == nil do return false
	foster.MaterialInitWithShaders(&r.material, &r.vertex_shader, &r.fragment_shader)
	elements := []foster.VertexElement{
		{0, .Float3, false}, // position
		{1, .Float3, false}, // normal
		{2, .Float2, false}, // uv
		{3, .Float4, false}, // color
	}
	format := foster.VertexFormatMake(elements, size_of(Book_Vertex))
	defer foster.VertexFormatDispose(&format)
	for &mesh in r.meshes {
		foster.MeshInitWithFormat(&mesh, device, format, .ThirtyTwo, "book 3D geometry")
	}
	foster.TextureInit(&r.white, device, 1, 1, .Color, "binding white")
	pixel := [4]u8{255, 255, 255, 255}
	foster.TextureSetData(&r.white, &pixel[0], 4)
	build_binding_mesh(&r.meshes[.Binding])
	return true
}

renderer_dispose :: proc(r: ^Book_Renderer) {
	for &mesh in r.meshes {
		foster.MeshDispose(&mesh)
	}
	foster.MaterialDispose(&r.material)
	foster.ShaderDispose(&r.vertex_shader)
	foster.ShaderDispose(&r.fragment_shader)
	foster.TextureDispose(&r.white)
	foster.TargetDispose(&r.target)
}

ensure_target :: proc(r: ^Book_Renderer, app: ^foster.App, w, h: int) {
	if r.target.Width == w && r.target.Height == h do return
	foster.TargetDispose(&r.target)
	attachments := [2]foster.TargetAttachmentSpec{{Format = .Color}, {Format = .Depth32}}
	foster.TargetInit(&r.target, &app.GraphicsDevice, w, h, attachments[:], "book color + depth")
}

// ==============================================================================
// 网格构建
// ==============================================================================

// 纸的网格每格两个三角形（a-c-b、a-d-c），与 pick_sheet_ray 和
// sheet_local_point 一致。
upload_sheet :: proc(mesh: ^foster.Mesh, sheet: ^Sheet) {
	vertices: [(COLS + 1) * (ROWS + 1)]Book_Vertex
	indices: [COLS * ROWS * 6]u32
	for row in 0..=ROWS {
		for col in 0..=COLS {
			// 靠书脊的五列稍暗，模拟装订处的阴影。
			gutter := 0.84 + 0.16 * min(f32(col) / 5, 1)
			uv := foster.Vec2{f32(col) / COLS, f32(row) / ROWS}
			color := [4]f32{gutter, gutter, gutter, 1}
			vertices[row * (COLS + 1) + col] = {sheet.points[row][col], sheet.normals[col], uv, color}
		}
	}
	for row in 0..<ROWS {
		for col in 0..<COLS {
			a := u32(row * (COLS + 1) + col) // a b
			b, d := a + 1, a + COLS + 1      // d c
			c := d + 1
			i := (row * COLS + col) * 6
			indices[i], indices[i + 1], indices[i + 2] = a, c, b
			indices[i + 3], indices[i + 4], indices[i + 5] = a, d, c
		}
	}
	foster.MeshSetVerticesTyped(Book_Vertex, mesh, vertices[:])
	foster.MeshSetIndicesTyped(u32, mesh, indices[:])
}

append_box :: proc(vertices: ^[dynamic]Book_Vertex, indices: ^[dynamic]u32, box: Binding_Box) {
	a, b := box.lo, box.hi
	corners := [8]foster.Vec3{
		{a.x, a.y, a.z}, {b.x, a.y, a.z}, {b.x, b.y, a.z}, {a.x, b.y, a.z},
		{a.x, a.y, b.z}, {b.x, a.y, b.z}, {b.x, b.y, b.z}, {a.x, b.y, b.z},
	}
	faces := [6][4]int{{0, 3, 2, 1}, {4, 5, 6, 7}, {0, 1, 5, 4}, {3, 7, 6, 2}, {0, 4, 7, 3}, {1, 2, 6, 5}}
	normals := [6]foster.Vec3{{0, 0, -1}, {0, 0, 1}, {0, -1, 0}, {0, 1, 0}, {-1, 0, 0}, {1, 0, 0}}
	for face, i in faces {
		base := u32(len(vertices^))
		for corner in face {
			append(vertices, Book_Vertex{corners[corner], normals[i], {}, box.color})
		}
		append(indices, base, base + 1, base + 2, base, base + 2, base + 3)
	}
}

build_binding_mesh :: proc(mesh: ^foster.Mesh) {
	vertices: [dynamic]Book_Vertex
	indices: [dynamic]u32
	defer delete(vertices)
	defer delete(indices)
	for box in binding_boxes {
		append_box(&vertices, &indices, box)
	}
	// 书页堆上下边缘的细条纹，让它看起来是一叠纸。
	for layer in 0..<6 {
		z := -15 + f32(layer) * 2.2
		for side in ([]f32{-1, 1}) {
			x := side > 0 ? f32(2) : -363
			append_box(&vertices, &indices, {{x, -251.2, z}, {x + 361, -250.8, z + 0.5}, PAPER_STRIPE})
			append_box(&vertices, &indices, {{x, 250.8, z}, {x + 361, 251.2, z + 0.5}, PAPER_STRIPE})
		}
	}
	append_box(&vertices, &indices, {{-3, -264, -16}, {3, 264, -0.7}, SPINE})
	// 封面下的烫金边框，书翻过来时可见。
	for side in ([]f32{-1, 1}) {
		x := side * 353
		append_box(&vertices, &indices, {{x - 1, -242, -24.4}, {x + 1, 242, -24}, GILT})
		y := side * 242
		append_box(&vertices, &indices, {{-353, y - 1, -24.4}, {353, y + 1, -24}, GILT})
	}
	foster.MeshSetVerticesTyped(Book_Vertex, mesh, vertices[:])
	foster.MeshSetIndicesTyped(u32, mesh, indices[:])
}

// ==============================================================================
// 绘制
// ==============================================================================

// 三角形朝向相机的一面采样 `front`，另一面采样 `back`。
draw_mesh3d :: proc(
	r: ^Book_Renderer,
	app: ^foster.App,
	mesh: ^foster.Mesh,
	front, back: ^foster.Texture,
) {
	sampler := foster.TextureSamplerMake(.Linear, .Clamp)
	r.material.Fragment.Samplers[0] = {Texture = front, Sampler = sampler}
	r.material.Fragment.Samplers[1] = {Texture = back, Sampler = sampler}
	command: foster.DrawCommand
	foster.DrawCommandFromMesh(&command, foster.DrawableTargetFromTarget(&r.target), mesh, &r.material)
	command.DepthTestEnabled = true
	command.DepthWriteEnabled = true
	command.CullMode = .None // 纸是双面的
	foster.GraphicsDeviceDraw(&app.GraphicsDevice, &command)
	foster.DrawCommandDispose(&command)
}

page_texture :: proc(world: ^World, index: int) -> ^foster.Texture {
	return foster.TargetAttachment(&world.pages[index].target)
}

render_book3d :: proc(world: ^World, app: ^foster.App, w, h: int) {
	r := &world.renderer
	ensure_target(r, app, w, h)
	colors := [1]foster.Color{foster.Transparent}
	foster.GraphicsDeviceClear(
		&app.GraphicsDevice,
		foster.DrawableTargetFromTarget(&r.target),
		colors[:],
		1,
		0,
		foster.ClearMask.Color | foster.ClearMask.Depth,
	)
	matrices: [r3d.VERTEX_MATRIX_BLOCK_SIZE]u8
	r3d.pack_vertex_matrix_block(matrices[:], world.view.mvp, world.view.model)
	foster.MaterialStageSetUniformBuffer(&r.material.Vertex, matrices[:])
	draw_mesh3d(r, app, &r.meshes[.Binding], &r.white, &r.white)

	left, right := stack_pages(world)
	upload_sheet(&r.meshes[.Left_Sheet], &world.left_sheet)
	upload_sheet(&r.meshes[.Right_Sheet], &world.right_sheet)
	// 左侧纸转到了 angle = PI，读者看到的是它的背面。
	draw_mesh3d(r, app, &r.meshes[.Left_Sheet], &r.white, page_texture(world, left))
	draw_mesh3d(r, app, &r.meshes[.Right_Sheet], page_texture(world, right), &r.white)

	if world.turn.direction != 0 {
		front, back := turning_leaf_pages(world)
		upload_sheet(&r.meshes[.Turning_Sheet], &world.turning_sheet)
		draw_mesh3d(r, app, &r.meshes[.Turning_Sheet], page_texture(world, front), page_texture(world, back))
	}
}
