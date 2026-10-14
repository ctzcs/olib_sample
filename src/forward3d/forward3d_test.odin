#+test
package main

// forward3d 单元测试（CPU）：材质状态推导、cbuffer 布局、内嵌字节码、程序化几何。
// 由 olib 的 check.ps1 对含 *_test.odin 的示例目录自动运行。

import "core:math"
import "core:testing"

import dasset "olib:core/dasset"
import world "olib:kit/world"

// ==============================================================================
// 材质
// ==============================================================================

@(test)
material_render_state_dispatch :: proc(t: ^testing.T) {
	opaque := dasset.DASSET_MATERIAL_DEFAULT
	testing.expect(t, material_render_state(&opaque) == RENDER_STATE_OPAQUE)

	mask := dasset.DASSET_MATERIAL_DEFAULT
	mask.alpha_mode = .Mask
	testing.expect(t, !material_render_state(&mask).transparent) // Mask 留在不透明队列

	blend := dasset.DASSET_MATERIAL_DEFAULT
	blend.alpha_mode = .Blend
	blend.double_sided = true
	state := material_render_state(&blend)
	testing.expect(t, state.transparent && state.cull_none)

	mat := standard_material_from_dasset(&blend)
	testing.expect(t, mat.state.transparent && mat.albedo_texture == -1 && !material_has_normal_map(&mat))
}

// ==============================================================================
// cbuffer 布局（与 shaders/Standard3DCommon.hlsli 对照）
// ==============================================================================

@(test)
uniform_block_sizes_match_shader :: proc(t: ^testing.T) {
	testing.expect(t, LIGHT_BLOCK_SIZE == 7 * 16)                   // Standard3DLightBlock
	testing.expect(t, MATERIAL_BLOCK_SIZE == 6 * 16)                // Standard3DMaterialBlock
	testing.expect(t, SHADOW_BLOCK_SIZE == 320)                     // Standard3DShadowBlock
	testing.expect(t, POINT_LIGHT_BLOCK_SIZE == (2 + 6 * MAX_POINT_LIGHTS) * 16)
	testing.expect(t, size_of(Light_Block) == LIGHT_BLOCK_SIZE)
	testing.expect(t, size_of(Material_Block) == MATERIAL_BLOCK_SIZE)
}

@(test)
light_and_material_blocks_pack :: proc(t: ^testing.T) {
	buf := make([]u8, 1024)
	defer delete(buf)

	// 光照块：相机位置在第 4 个 vec4，HDR 在第 5 个，环境贴图默认关闭
	light := make_light_block({0, -1, 0}, {0.1, 0.1, 0.1}, {1, 1, 1}, {1, 2, 3}, 1)
	for &b in buf { b = 0xff }
	testing.expect(t, pack_light_block(buf, &light))
	testing.expect(t, read_vec4(buf, 48) == [4]f32{1, 2, 3, 0})
	testing.expect(t, read_vec4(buf, 64)[0] == 1)
	testing.expect(t, read_vec4(buf, 80) == [4]f32{0, 0, 0, 0}) // Environment.x = 0
	testing.expect(t, !pack_light_block(buf[:LIGHT_BLOCK_SIZE - 1], &light))

	// 材质块
	mat := dasset.DASSET_MATERIAL_DEFAULT
	mat.base_color_factor = {1, 0, 0, 1}
	mat.metallic = 0.5
	std_mat := standard_material_from_dasset(&mat)
	block := material_block_from(&std_mat)
	testing.expect(t, pack_material_block(buf, &block))
	testing.expect(t, read_vec4(buf, 0) == [4]f32{1, 0, 0, 1})
	testing.expect(t, read_vec4(buf, 48)[0] == 0.5)

	// 阴影块关闭形态：整块清零（ShadowSettings.x 与 CascadeSettings.z 都为 0）
	for &b in buf { b = 0xff }
	testing.expect(t, pack_shadow_block_disabled(buf))
	for b in buf[:SHADOW_BLOCK_SIZE] {
		testing.expect(t, b == 0)
	}
}

@(test)
point_light_block_meta_and_slots :: proc(t: ^testing.T) {
	buf := make([]u8, POINT_LIGHT_BLOCK_SIZE)
	defer delete(buf)

	lights := []Point_Light{
		{position = {1, 2, 3}, range = 10, color = {1, 0, 0}, intensity = 2},
	}
	testing.expect(t, pack_point_light_block(buf, lights, nil))
	testing.expect(t, read_vec4(buf, 0)[0] == 1) // count
	testing.expect(t, read_vec4(buf, 16) == [4]f32{1, 2, 3, 10})
	testing.expect(t, read_vec4(buf, 16 + 16*16) == [4]f32{1, 0, 0, 2})
	testing.expect(t, read_vec4(buf, 16 + 16*17) == [4]f32{0, 0, 0, 0}) // 第二盏为空
}

@(test)
spot_light_pack_layout :: proc(t: ^testing.T) {
	buf := make([]u8, POINT_LIGHT_BLOCK_SIZE)
	defer delete(buf)

	spots := []Spot_Light{{
		position    = {0, 5, 0},
		direction   = {0, -1, 0},
		range       = 10,
		color       = {1, 0.5, 0.2},
		intensity   = 3,
		inner_angle = math.PI / 12,
		outer_angle = math.PI / 6,
	}}
	testing.expect(t, pack_point_light_block(buf, nil, spots))
	testing.expect(t, read_vec4(buf, 33*16)[0] == 1)                         // 聚光 meta
	testing.expect(t, read_vec4(buf, 34*16) == [4]f32{0, 5, 0, 10})          // position/range
	testing.expect(t, read_vec4(buf, 50*16) == [4]f32{1, 0.5, 0.2, 3})       // color/intensity
	dir := read_vec4(buf, 66*16)                                             // direction/cosOuter
	testing.expect(t, dir[0] == 0 && dir[1] == -1 && dir[2] == 0)
	testing.expectf(t, math.abs(dir[3] - math.cos(f32(math.PI / 6))) < 1e-6, "cosOuter")
	inner := read_vec4(buf, 82*16)                                           // cosInner
	testing.expectf(t, math.abs(inner[0] - math.cos(f32(math.PI / 12))) < 1e-6, "cosInner")

	// 越界角度钳制：outer > pi/2
	bad := []Spot_Light{{outer_angle = 3, inner_angle = 5}}
	testing.expect(t, pack_point_light_block(buf, nil, bad))
	clamped := read_vec4(buf, 66*16)
	testing.expectf(t, math.abs(clamped[3] - math.cos(f32(math.PI / 2))) < 1e-6, "outer 钳到 pi/2")
}

@(private = "file")
read_vec4 :: proc(buf: []u8, offset: int) -> [4]f32 {
	v: [4]f32
	for i in 0..<4 {
		bits := u32(buf[offset + i*4]) | u32(buf[offset + i*4 + 1]) << 8 |
		        u32(buf[offset + i*4 + 2]) << 16 | u32(buf[offset + i*4 + 3]) << 24
		v[i] = transmute(f32)bits
	}
	return v
}

// ==============================================================================
// 内嵌字节码
// ==============================================================================

@(test)
shader_blobs_embedded :: proc(t: ^testing.T) {
	// SPIR-V 魔数 0x07230203（小端 03 02 23 07）、DXIL 容器 "DXBC"、MSL 源码
	spv := standard3d_vertex_spv
	testing.expect(t, len(spv) > 4 && spv[0] == 0x03 && spv[1] == 0x02 && spv[2] == 0x23 && spv[3] == 0x07)
	dxil := standard3d_fragment_dxil
	testing.expect(t, len(dxil) > 4 && dxil[0] == 'D' && dxil[1] == 'X' && dxil[2] == 'B' && dxil[3] == 'C')
	testing.expect(t, len(standard3d_skinned_vertex_msl) > 0 && standard3d_skinned_vertex_msl[0] == '#')
}

// ==============================================================================
// 程序化几何
// ==============================================================================

// 每个三角形从外侧看为 CCW：面法线与“中心指向三角形”的方向同向。
@(test)
shapes_wind_ccw_from_outside :: proc(t: ^testing.T) {
	cube := make_cube(2, dasset.DASSET_MATERIAL_DEFAULT)
	defer primitive_dispose(&cube)
	sphere := make_sphere(1, 8, 16, dasset.DASSET_MATERIAL_DEFAULT)
	defer primitive_dispose(&sphere)

	for p in ([]^dasset.Dasset_Primitive{&cube, &sphere}) {
		for i := 0; i < len(p.indices); i += 3 {
			a := p.vertices[p.indices[i]].position
			b := p.vertices[p.indices[i + 1]].position
			c := p.vertices[p.indices[i + 2]].position
			n := world.v3_cross(b - a, c - a)
			if world.v3_dot(n, n) < 1e-12 { continue } // 极点处的退化三角形
			centroid := (a + b + c) / 3
			testing.expectf(t, world.v3_dot(n, centroid) > 0, "三角形 %d 绕序朝内", i / 3)
		}
	}
	testing.expect(t, len(cube.vertices) == 24 && len(cube.indices) == 36)
	testing.expect(t, cube.bounds.max == [3]f32{1, 1, 1})
}
