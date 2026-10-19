package main

// Standard3D 着色器 cbuffer 的 CPU 侧打包（参考实现，原 kit/rendering/3d uniforms3d）。
//
// 布局对照 shaders/Standard3DCommon.hlsli，全部 vec4 对齐（std140），槽位号与
// HLSL 的 register(bN) 一致。改着色器的 cbuffer 时这里必须同步改，
// forward3d_test.odin 校验了各块大小与关键偏移。
// 顶点槽 0（WVP + World）是通用约定，直接用 kit 的 r3d.pack_vertex_matrix_block。

import "core:math"

import world "olib:kit/world"
import mat "olib:kit/rendering/material"

// 分区：
//   顶点槽 —— 阴影矩阵（槽 1）
//   片元槽 —— 光照（槽 0）/ 材质（槽 1）/ 阴影（槽 2）/ 点光与聚光（槽 3）

// ==============================================================================
// 顶点槽 —— 阴影矩阵（槽 1）
// ==============================================================================

SHADOW_MATRIX_BLOCK_SIZE :: 64 // 单矩阵 LightViewProjection

pack_shadow_matrix_block :: proc(buf: []u8, light_view_projection: world.Matrix4) -> bool {
	if len(buf) < SHADOW_MATRIX_BLOCK_SIZE { return false }
	mat.std140_write_matrix(buf, 0, light_view_projection)
	return true
}

// ==============================================================================
// 片元槽 —— 光照（槽 0）
// ==============================================================================

MAX_POINT_LIGHTS :: 16

// Standard3DLightBlock（112B = 7 个 vec4）。light_direction 是光的传播方向（着色器取负）。
// environment / environment_size 给 IBL 用；本示例没有环境贴图，保持 0（关闭）。
Light_Block :: struct {
	light_direction:  [4]f32,
	ambient:          [4]f32,
	diffuse:          [4]f32,
	camera_position:  [4]f32, // xyz 相机世界位置（镜面项要 view 方向）
	color_pipeline:   [4]f32, // x: HDR 开关（0 = LDR，输出 saturate）
	environment:      [4]f32, // enabled, intensity, rotation, level count
	environment_size: [4]f32, // width, height per roughness level, atlas height
}

LIGHT_BLOCK_SIZE :: 112

pack_light_block :: proc(buf: []u8, light: ^Light_Block) -> bool {
	if len(buf) < LIGHT_BLOCK_SIZE { return false }
	mat.std140_write_vec4(buf, 0, light.light_direction)
	mat.std140_write_vec4(buf, 16, light.ambient)
	mat.std140_write_vec4(buf, 32, light.diffuse)
	mat.std140_write_vec4(buf, 48, light.camera_position)
	mat.std140_write_vec4(buf, 64, light.color_pipeline)
	mat.std140_write_vec4(buf, 80, light.environment)
	mat.std140_write_vec4(buf, 96, light.environment_size)
	return true
}

// 便捷：方向光 + 环境光 + 相机位置；环境贴图关闭。
make_light_block :: proc(
	light_direction, ambient, diffuse: [3]f32,
	camera_position: [3]f32,
	hdr: f32,
) -> Light_Block {
	return Light_Block{
		light_direction = {light_direction[0], light_direction[1], light_direction[2], 0},
		ambient         = {ambient[0], ambient[1], ambient[2], 0},
		diffuse         = {diffuse[0], diffuse[1], diffuse[2], 0},
		camera_position = {camera_position[0], camera_position[1], camera_position[2], 0},
		color_pipeline  = {hdr, 0, 0, 0},
	}
}

// ==============================================================================
// 片元槽 —— 材质（槽 1）
// ==============================================================================

// Standard3DMaterialBlock（96B）。各 vec4 的语义见 Standard3DCommon.hlsli。
Material_Block :: struct {
	base_color: [4]f32,
	flags:      [4]f32, // x: has albedo, y: has normal map, z: normal strength, w: alpha mode
	alpha:      [4]f32, // x: cutoff
	pbr:        [4]f32, // x: metallic, y: roughness, z: albedo-srgb-decoded
	textures:   [4]f32, // x: MR, y: AO, z: emissive, w: emissive sRGB
	emissive:   [4]f32, // xyz: factor, w: AO strength
}

MATERIAL_BLOCK_SIZE :: 96

pack_material_block :: proc(buf: []u8, m: ^Material_Block) -> bool {
	if len(buf) < MATERIAL_BLOCK_SIZE { return false }
	mat.std140_write_vec4(buf, 0, m.base_color)
	mat.std140_write_vec4(buf, 16, m.flags)
	mat.std140_write_vec4(buf, 32, m.alpha)
	mat.std140_write_vec4(buf, 48, m.pbr)
	mat.std140_write_vec4(buf, 64, m.textures)
	mat.std140_write_vec4(buf, 80, m.emissive)
	return true
}

// 由 Standard_Material_3D 生成片元材质块（无贴图路径：全部 has*=0）。
material_block_from :: proc(m: ^Standard_Material_3D) -> Material_Block {
	alpha_mode := f32(0)
	if m.state.transparent { alpha_mode = 2 } else if m.alpha_cutoff < 1 && m.alpha_cutoff > 0 {
		alpha_mode = 1 // 近似：cutout 由调用侧显式指定更准
	}
	return Material_Block{
		base_color = m.base_color_factor,
		flags      = {0, 0, 1, alpha_mode},
		alpha      = {m.alpha_cutoff, 0, 0, 0},
		pbr        = {m.metallic, m.roughness, 0, 0},
		textures   = {0, 0, 0, 0},
		emissive   = {m.emissive_factor[0], m.emissive_factor[1], m.emissive_factor[2], m.occlusion_strength},
	}
}

// ==============================================================================
// 片元槽 —— 阴影（槽 2）
// ==============================================================================

// Standard3DShadowBlock（320B）：ShadowSettings + 4 个级联矩阵 + CascadeSplits +
// CascadeSettings + ShadowCameraForward。本示例没有阴影 pass，整块填 0：
// ShadowSettings.x = 0 关阴影，CascadeSettings.z = 0 关级联调试色。
SHADOW_BLOCK_SIZE :: 16 + 4 * 64 + 3 * 16

pack_shadow_block_disabled :: proc(buf: []u8) -> bool {
	if len(buf) < SHADOW_BLOCK_SIZE { return false }
	for i in 0..<SHADOW_BLOCK_SIZE {
		buf[i] = 0
	}
	return true
}

// ==============================================================================
// 片元槽 —— 点光与聚光（槽 3）
// ==============================================================================

// Standard3DPointLightBlock：meta(1) + 点光 position/color 各 16 + 聚光 meta(1) +
// 聚光 4 组各 16 = 98 vec4 = 1568B。
POINT_LIGHT_BLOCK_SIZE :: 98 * 16

Point_Light :: struct {
	position:  [3]f32,
	range:     f32,
	color:     [3]f32,
	intensity: f32,
}

// 无阴影聚光灯：direction 指向光射出方向，锥角为弧度半角。
Spot_Light :: struct {
	position:    [3]f32,
	direction:   [3]f32,
	range:       f32,
	color:       [3]f32,
	intensity:   f32,
	inner_angle: f32, // 弧度半角
	outer_angle: f32,
}

SPOT_LIGHT_DEFAULT_INNER :: f32(math.PI / 12)
SPOT_LIGHT_DEFAULT_OUTER :: f32(math.PI / 6)

// 打包槽 3：点光与聚光（各自钳制参数，零长度方向兜底 -Y）。
pack_point_light_block :: proc(buf: []u8, lights: []Point_Light, spot_lights: []Spot_Light) -> bool {
	if len(buf) < POINT_LIGHT_BLOCK_SIZE { return false }

	count := min(len(lights), MAX_POINT_LIGHTS)
	mat.std140_write_vec4(buf, 0, {f32(count), 0, 0, 0})
	for i in 0..<MAX_POINT_LIGHTS {
		if i < count {
			l := lights[i]
			mat.std140_write_vec4(buf, 16 + i*16, {l.position[0], l.position[1], l.position[2], l.range})
			mat.std140_write_vec4(buf, 16 + (MAX_POINT_LIGHTS + i)*16, {l.color[0], l.color[1], l.color[2], l.intensity})
		} else {
			mat.std140_write_vec4(buf, 16 + i*16, {0, 0, 0, 0})
			mat.std140_write_vec4(buf, 16 + (MAX_POINT_LIGHTS + i)*16, {0, 0, 0, 0})
		}
	}

	// 聚光：meta 在 33 号 vec4，其后 4 组各 16
	base := 33 * 16
	spot_count := min(len(spot_lights), MAX_POINT_LIGHTS)
	mat.std140_write_vec4(buf, base, {f32(spot_count), 0, 0, 0})
	for i in 0..<MAX_POINT_LIGHTS {
		if i < spot_count {
			l := spot_lights[i]
			dx, dy, dz := l.direction[0], l.direction[1], l.direction[2]
			length2 := dx*dx + dy*dy + dz*dz
			if length2 > 1e-8 {
				inv := 1.0 / math.sqrt(length2)
				dx, dy, dz = dx*inv, dy*inv, dz*inv
			} else {
				dx, dy, dz = 0, -1, 0
			}
			outer := math.clamp(l.outer_angle, 0.001, math.PI / 2)
			inner := math.clamp(l.inner_angle, 0, outer)
			color := [3]f32{max(l.color[0], 0), max(l.color[1], 0), max(l.color[2], 0)}
			mat.std140_write_vec4(buf, base + 16 + i*16, {l.position[0], l.position[1], l.position[2], max(l.range, 0)})
			mat.std140_write_vec4(buf, base + 16 + (16 + i)*16, {color[0], color[1], color[2], max(l.intensity, 0)})
			mat.std140_write_vec4(buf, base + 16 + (32 + i)*16, {dx, dy, dz, math.cos(outer)})
			mat.std140_write_vec4(buf, base + 16 + (48 + i)*16, {math.cos(inner), 0, 0, 0})
		} else {
			for g in 0..<4 {
				mat.std140_write_vec4(buf, base + 16 + (g*16 + i)*16, {0, 0, 0, 0})
			}
		}
	}
	return true
}
