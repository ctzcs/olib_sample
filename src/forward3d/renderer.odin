package main

// Standard 前向渲染器（参考实现，原 kit/rendering3d renderer3d + shader3d 的 Standard 部分）。
//
// 这是“复制到游戏里按需修改”的起点，不是库 API：光照模型、槽位约定、
// 阴影/后处理是否要做都由游戏决定。kit/rendering3d 只提供机制
// （Mesh 上传、泛型排序队列、字节码按驱动选择、std140 写入、DebugDraw3D）。
//
// 每帧：renderer_render —— 片元公共槽（光照/阴影关闭/点光）设一次，
// 逐项设顶点矩阵块 + 片元材质块后经 Foster DrawCommand 发射。
// 蒙皮项经 palette 槽（2、3）注入骨骼矩阵（animation.compute_palette 产出）。

import world "olib:kit/world"
import r3d "olib:kit/rendering3d"
import foster "olib:foster"

// 分区：
//   着色器 —— 内嵌字节码 / Standard3D 装载
//   类型与生命周期 —— Renderer / Standard_Draw / init / dispose
//   帧渲染 —— render（公共槽 + 逐项发射）

// ==============================================================================
// 着色器
// ==============================================================================

// shaders/Compiled 由 olib 的 tools/shaders 编译后入库，#load 内嵌（在 olib_sample 根目录运行）：
//   odin run ../olib/tools/shaders -- -dir:src/forward3d/shaders
@(private) standard3d_vertex_spv :: #load("shaders/Compiled/Standard3D.vertex.spv")
@(private) standard3d_fragment_spv :: #load("shaders/Compiled/Standard3D.fragment.spv")
@(private) standard3d_skinned_vertex_spv :: #load("shaders/Compiled/Standard3DSkinned.vertex.spv")
@(private) standard3d_skinned_fragment_spv :: #load("shaders/Compiled/Standard3DSkinned.fragment.spv")
@(private) standard3d_vertex_dxil :: #load("shaders/Compiled/Standard3D.vertex.dxil")
@(private) standard3d_fragment_dxil :: #load("shaders/Compiled/Standard3D.fragment.dxil")
@(private) standard3d_skinned_vertex_dxil :: #load("shaders/Compiled/Standard3DSkinned.vertex.dxil")
@(private) standard3d_skinned_fragment_dxil :: #load("shaders/Compiled/Standard3DSkinned.fragment.dxil")
@(private) standard3d_vertex_msl :: #load("shaders/Compiled/Standard3D.vertex.msl")
@(private) standard3d_fragment_msl :: #load("shaders/Compiled/Standard3D.fragment.msl")
@(private) standard3d_skinned_vertex_msl :: #load("shaders/Compiled/Standard3DSkinned.vertex.msl")
@(private) standard3d_skinned_fragment_msl :: #load("shaders/Compiled/Standard3DSkinned.fragment.msl")

// 片元采样器数量与 Standard3DCommon.hlsli 的 t0..t8 一致：
// albedo / normal / shadow / MR / AO / emissive / env diffuse / env specular / env BRDF。
// 未绑定的槽由 foster 填调试纹理，对应开关在 uniform 里关着，不会被采样到结果里。
STANDARD3D_FRAGMENT_SAMPLERS :: 9

// Standard3D 一套（静态 + 蒙皮）：
// vertex 槽 0=矩阵块 / 1=阴影矩阵（蒙皮再加 2、3=palette 两块）；
// fragment 槽 0=光照 / 1=材质 / 2=阴影 / 3=点光与聚光。
Standard_Shaders :: struct {
	static_vertex:    foster.Shader,
	static_fragment:  foster.Shader,
	skinned_vertex:   foster.Shader,
	skinned_fragment: foster.Shader,
}

standard_shaders_init :: proc(s: ^Standard_Shaders, device: ^foster.GraphicsDevice) -> bool {
	if !r3d.shader3d_driver_supported(device.Driver) { return false }
	pick :: r3d.shader3d_pick_code
	driver := device.Driver

	foster.ShaderInit(&s.static_vertex, device, foster.ShaderCreateInfo{
		Stage              = .Vertex,
		Code               = pick(driver, standard3d_vertex_spv, standard3d_vertex_dxil, standard3d_vertex_msl),
		UniformBufferCount = 2, // b0 矩阵块 / b1 阴影矩阵
		EntryPoint         = "vertex_main",
	}, "Standard3DVertex")
	foster.ShaderInit(&s.static_fragment, device, foster.ShaderCreateInfo{
		Stage              = .Fragment,
		Code               = pick(driver, standard3d_fragment_spv, standard3d_fragment_dxil, standard3d_fragment_msl),
		SamplerCount       = STANDARD3D_FRAGMENT_SAMPLERS,
		UniformBufferCount = 4, // b0 光照 / b1 材质 / b2 阴影 / b3 点光
		EntryPoint         = "fragment_main",
	}, "Standard3DFragment")
	foster.ShaderInit(&s.skinned_vertex, device, foster.ShaderCreateInfo{
		Stage              = .Vertex,
		Code               = pick(driver, standard3d_skinned_vertex_spv, standard3d_skinned_vertex_dxil, standard3d_skinned_vertex_msl),
		UniformBufferCount = 4, // 再加 b2/b3 palette 两块
		EntryPoint         = "vertex_main",
	}, "Standard3DSkinnedVertex")
	foster.ShaderInit(&s.skinned_fragment, device, foster.ShaderCreateInfo{
		Stage              = .Fragment,
		Code               = pick(driver, standard3d_skinned_fragment_spv, standard3d_skinned_fragment_dxil, standard3d_skinned_fragment_msl),
		SamplerCount       = STANDARD3D_FRAGMENT_SAMPLERS,
		UniformBufferCount = 4,
		EntryPoint         = "fragment_main",
	}, "Standard3DSkinnedFragment")

	return s.static_vertex.Resource != nil && s.static_fragment.Resource != nil &&
	       s.skinned_vertex.Resource != nil && s.skinned_fragment.Resource != nil
}

standard_shaders_dispose :: proc(s: ^Standard_Shaders) {
	foster.ShaderDispose(&s.static_vertex)
	foster.ShaderDispose(&s.static_fragment)
	foster.ShaderDispose(&s.skinned_vertex)
	foster.ShaderDispose(&s.skinned_fragment)
	s^ = {}
}

// ==============================================================================
// 类型与生命周期
// ==============================================================================

// 渲染项 payload：经 r3d.Render_Queue(Standard_Draw) 排序后由 renderer_render 发射。
Standard_Draw :: struct {
	mesh:     ^foster.Mesh, // Foster Mesh（r3d.mesh3d_upload 上传）
	material: Standard_Material_3D,
	world:    world.Matrix4,
	skinned:  bool, // 蒙皮走 palette 槽的材质变体
}

Renderer :: struct {
	device: ^foster.GraphicsDevice,

	shaders:          Standard_Shaders,
	material_static:  foster.Material,
	material_skinned: foster.Material,

	scratch: [dynamic]u8, // uniform 打包临时
}

renderer_init :: proc(r: ^Renderer, device: ^foster.GraphicsDevice) -> bool {
	if device == nil { return false }
	r.device = device
	if !standard_shaders_init(&r.shaders, device) {
		return false
	}
	foster.MaterialInitWithShaders(&r.material_static, &r.shaders.static_vertex, &r.shaders.static_fragment)
	foster.MaterialInitWithShaders(&r.material_skinned, &r.shaders.skinned_vertex, &r.shaders.skinned_fragment)
	return true
}

renderer_dispose :: proc(r: ^Renderer) {
	foster.MaterialDispose(&r.material_static)
	foster.MaterialDispose(&r.material_skinned)
	standard_shaders_dispose(&r.shaders)
	delete(r.scratch)
	r^ = {}
}

// ==============================================================================
// 帧渲染
// ==============================================================================

// 按队列顺序发射（调用前先 r3d.queue_sort）。camera 提供视矩阵；light 为方向光；
// point_lights / spot_lights 可为空。palette 为蒙皮项的骨骼矩阵（非蒙皮传 nil）。
// 返回实际发射的 draw 数。
renderer_render :: proc(
	r: ^Renderer,
	camera:       ^world.Camera3D,
	light:        ^Light_Block,
	point_lights: []Point_Light,
	spot_lights:  []Spot_Light,
	target:       foster.DrawableTarget,
	queue:        ^r3d.Render_Queue(Standard_Draw),
	palette:      []world.Matrix4,
) -> int {
	if r.device == nil { return 0 }

	// ---- 片元公共槽：光照(0) / 阴影关闭(2) / 点光(3) ----
	light_buf := scratch_reserve(&r.scratch, LIGHT_BLOCK_SIZE)
	if pack_light_block(light_buf, light) {
		foster.MaterialStageSetUniformBuffer(&r.material_static.Fragment, light_buf, 0)
		foster.MaterialStageSetUniformBuffer(&r.material_skinned.Fragment, light_buf, 0)
	}
	shadow_buf := scratch_reserve(&r.scratch, SHADOW_BLOCK_SIZE)
	if pack_shadow_block_disabled(shadow_buf) {
		foster.MaterialStageSetUniformBuffer(&r.material_static.Fragment, shadow_buf, 2)
		foster.MaterialStageSetUniformBuffer(&r.material_skinned.Fragment, shadow_buf, 2)
	}
	pl_buf := scratch_reserve(&r.scratch, POINT_LIGHT_BLOCK_SIZE)
	if pack_point_light_block(pl_buf, point_lights, spot_lights) {
		foster.MaterialStageSetUniformBuffer(&r.material_static.Fragment, pl_buf, 3)
		foster.MaterialStageSetUniformBuffer(&r.material_skinned.Fragment, pl_buf, 3)
	}

	// ---- 视矩阵（乘在各 item 的 world 后构成 WVP：行向量 v*W*VP）----
	view_projection := world.camera3d_view_projection(camera)

	drawn := 0
	for &queued in queue.items {
		item := &queued.payload
		mesh := item.mesh
		if mesh == nil { continue }
		material := item.skinned ? &r.material_skinned : &r.material_static

		// 顶点槽 0：WVP + World
		matrix_buf := scratch_reserve(&r.scratch, r3d.VERTEX_MATRIX_BLOCK_SIZE)
		wvp := world.matrix4_multiply(item.world, view_projection)
		if !r3d.pack_vertex_matrix_block(matrix_buf, wvp, item.world) { continue }
		foster.MaterialStageSetUniformBuffer(&material.Vertex, matrix_buf, 0)
		// 顶点槽 1：阴影矩阵（关闭形态也要给，着色器仍会乘）
		shadow_matrix_buf := scratch_reserve(&r.scratch, SHADOW_MATRIX_BLOCK_SIZE)
		if pack_shadow_matrix_block(shadow_matrix_buf, world.MATRIX4_IDENTITY) {
			foster.MaterialStageSetUniformBuffer(&material.Vertex, shadow_matrix_buf, 1)
		}
		// 蒙皮：palette 两块（两块同时要用，不能都取自 scratch）
		if item.skinned {
			p0 := make([]u8, 64 * 64, context.temp_allocator)
			p1 := make([]u8, 64 * 64, context.temp_allocator)
			if r3d.pack_joint_palette(p0, p1, palette) {
				foster.MaterialStageSetUniformBuffer(&material.Vertex, p0, 2)
				foster.MaterialStageSetUniformBuffer(&material.Vertex, p1, 3)
			}
		}

		// 片元槽 1：材质块
		mat_block := material_block_from(&item.material)
		mat_buf := scratch_reserve(&r.scratch, MATERIAL_BLOCK_SIZE)
		if !pack_material_block(mat_buf, &mat_block) { continue }
		foster.MaterialStageSetUniformBuffer(&material.Fragment, mat_buf, 1)

		// ---- 发射 ----
		command: foster.DrawCommand
		foster.DrawCommandFromMesh(&command, target, mesh, material)
		command.DepthTestEnabled = true
		command.DepthWriteEnabled = !item.material.state.transparent
		command.CullMode = item.material.state.cull_none ? .None : .Back
		if item.material.state.transparent {
			command.BlendMode = foster.BlendMode{
				ColorOperation   = .Add,
				ColorSource      = .SrcAlpha,
				ColorDestination = .OneMinusSrcAlpha,
				AlphaOperation   = .Add,
				AlphaSource      = .One,
				AlphaDestination = .OneMinusSrcAlpha,
				Mask             = .RGBA, // 零值 .None 会关掉颜色写入
				Color            = foster.White,
			}
		}
		foster.GraphicsDeviceDraw(r.device, &command)
		foster.DrawCommandDispose(&command)
		drawn += 1
	}
	return drawn
}

// 复用一块动态缓冲做 uniform 打包临时（每次调用重置，返回 len=size 的视图）。
// MaterialStageSetUniformBuffer 会拷贝数据，所以上一次的视图被覆盖没有关系。
@(private = "file")
scratch_reserve :: proc(scratch: ^[dynamic]u8, size: int) -> []u8 {
	clear(scratch)
	resize(scratch, size)
	return scratch[:]
}
