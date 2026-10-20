package main

import "core:math"
import dasset "olib:core/dasset"

// 示例用的程序化网格：静态顶点格式（位置、法线、UV、切线）。正面逆时针（从外侧看），配合 Cull Back。

CUBE_BOUNDS :: dasset.Dasset_Bounds{min = {-0.5, -0.5, -0.5}, max = {0.5, 0.5, 0.5}}
BALL_BOUNDS :: dasset.Dasset_Bounds{min = {-1, -1, -1}, max = {1, 1, 1}}
// 面片（金币、圆影）在 Shader 里沿相机轴展开或平铺到地面，盒子要包住任意朝向（半对角线约 0.71）。
CARD_BOUNDS :: dasset.Dasset_Bounds{min = {-0.75, -0.75, -0.75}, max = {0.75, 0.75, 0.75}}

// 单位立方体（边长 1，中心在原点），每面 4 个顶点以保留硬边法线。
cube :: proc() -> dasset.Dasset_Primitive {
	p := dasset.Dasset_Primitive{vertices = make([]dasset.Dasset_Vertex, 24), indices = make([]u32, 36)}
	// 每面：法线 n 与面内两轴 u、v，满足 u × v = n。
	faces := [6][3][3]f32{
		{{1, 0, 0}, {0, 0, -1}, {0, 1, 0}},
		{{-1, 0, 0}, {0, 0, 1}, {0, 1, 0}},
		{{0, 1, 0}, {1, 0, 0}, {0, 0, -1}},
		{{0, -1, 0}, {1, 0, 0}, {0, 0, 1}},
		{{0, 0, 1}, {1, 0, 0}, {0, 1, 0}},
		{{0, 0, -1}, {-1, 0, 0}, {0, 1, 0}},
	}
	corners := [4][2]f32{{-1, -1}, {1, -1}, {1, 1}, {-1, 1}}
	for face, f in faces {
		n, u, v := face[0], face[1], face[2]
		for c, k in corners {
			position := n * 0.5 + u * (c[0] * 0.5) + v * (c[1] * 0.5)
			p.vertices[f*4+k] = {position = position, normal = n, uv = {c[0] * 0.5 + 0.5, 0.5 - c[1] * 0.5},
				tangent = {u[0], u[1], u[2], 1}}
		}
		base := u32(f * 4)
		copy(p.indices[f*6:], []u32{base, base + 1, base + 2, base, base + 2, base + 3})
	}
	return p
}

// 单位球（半径 1）。
sphere :: proc(rings := 24, segments := 32) -> dasset.Dasset_Primitive {
	p := dasset.Dasset_Primitive{vertices = make([]dasset.Dasset_Vertex, (rings+1)*(segments+1)), indices = make([]u32, rings*segments*6)}
	for r in 0..=rings do for n in 0..=segments {
		theta, phi := f32(r)/f32(rings)*math.PI, f32(n)/f32(segments)*2*math.PI
		normal := [3]f32{math.sin(theta)*math.cos(phi), math.cos(theta), math.sin(theta)*math.sin(phi)}
		p.vertices[r*(segments+1)+n] = {position = normal, normal = normal, uv = {f32(n)/f32(segments), f32(r)/f32(rings)},
			tangent = {-math.sin(phi), 0, math.cos(phi), 1}}
	}
	for r in 0..<rings do for n in 0..<segments {
		a := u32(r*(segments+1)+n)
		seg := u32(segments)
		copy(p.indices[(r*segments+n)*6:], []u32{a, a+1, a+seg+2, a, a+seg+2, a+seg+1})
	}
	return p
}

// XY 平面上的单位面片（-0.5..0.5）：金币在顶点着色器里沿相机轴展开，圆影平铺到地面。
quad :: proc() -> dasset.Dasset_Primitive {
	p := dasset.Dasset_Primitive{vertices = make([]dasset.Dasset_Vertex, 4), indices = make([]u32, 6)}
	corners := [4][2]f32{{-0.5, -0.5}, {0.5, -0.5}, {0.5, 0.5}, {-0.5, 0.5}}
	for c, k in corners {
		p.vertices[k] = {position = {c[0], c[1], 0}, normal = {0, 0, 1}, uv = {c[0] + 0.5, 0.5 - c[1]}, tangent = {1, 0, 0, 1}}
	}
	copy(p.indices, []u32{0, 1, 2, 0, 2, 3})
	return p
}

primitive_dispose :: proc(p: ^dasset.Dasset_Primitive) {
	delete(p.vertices)
	delete(p.indices)
}
