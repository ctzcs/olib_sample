package main

import "core:math"
import "core:math/linalg"
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

// Shared low-poly crown / stone mesh: flat normals retain broad painted facets.
faceted_sphere :: proc(wind := false) -> dasset.Dasset_Primitive {
	source := sphere(6, 9)
	defer primitive_dispose(&source)
	p := dasset.Dasset_Primitive{vertices = make([]dasset.Dasset_Vertex, len(source.indices)), indices = make([]u32, len(source.indices))}
	for triangle in 0..<len(source.indices)/3 {
		a := source.vertices[source.indices[triangle*3]].position
		b := source.vertices[source.indices[triangle*3+1]].position
		c := source.vertices[source.indices[triangle*3+2]].position
		n := linalg.cross(b-a, c-a)
		if linalg.length(n) < 0.00001 { n = linalg.normalize(a+b+c) } else { n = linalg.normalize(n) }
		for j in 0..<3 {
			i := triangle*3+j
			p.vertices[i] = source.vertices[source.indices[i]]
			p.vertices[i].normal = n
			if wind do p.vertices[i].tangent.w = -2
			p.indices[i] = u32(i)
		}
	}
	return p
}

// Three broad, bent blades. Back faces are explicit; no alpha overdraw.
grass_tuft :: proc() -> dasset.Dasset_Primitive {
	p := dasset.Dasset_Primitive{vertices = make([]dasset.Dasset_Vertex, 18), indices = make([]u32, 18)}
	for blade in 0..<3 {
		a := f32(blade)*2.1
		x, z := math.cos(a), math.sin(a)
		points := [3][3]f32{{-x*0.28, 0, -z*0.28}, {x*0.28, 0, z*0.28}, {z*0.28, 0.65+f32(blade)*0.17, -x*0.28}}
		for side in 0..<2 do for j in 0..<3 {
			i := blade*6 + side*3 + j
			index := side == 0 ? j : 2-j
			p.vertices[i] = {position = points[index], normal = {0, 1, 0}, uv = {0, points[index].y}, tangent = {1,0,0,-1}}
			p.indices[i] = u32(i)
		}
	}
	return p
}

// The flower's stem, petals and pollen share one mesh / instance draw. UV.x is
// a palette selector in Toon, so pink/cream/lavender blooms need no extra materials.
meadow_flower :: proc() -> dasset.Dasset_Primitive {
	vertices: [dynamic]dasset.Dasset_Vertex
	indices: [dynamic]u32
	triangle :: proc(vertices: ^[dynamic]dasset.Dasset_Vertex, indices: ^[dynamic]u32, a,b,c: [3]f32, palette: f32) {
		for side in 0..<2 {
			points := side == 0 ? [3][3]f32{a,b,c} : [3][3]f32{c,b,a}
			for point in points {
				append(indices, u32(len(vertices^)))
				append(vertices, dasset.Dasset_Vertex{position = point, normal = {0,1,0}, uv = {palette,0}, tangent = {1,0,0,-3}})
			}
		}
	}
	triangle(&vertices, &indices, {-0.025,0,0}, {0.025,0,0}, {0,0.75,0}, 0)
	triangle(&vertices, &indices, {0,0.30,0}, {-0.22,0.44,0.06}, {0,0.50,0}, 0)
	for petal in 0..<5 {
		a := f32(petal)*2*math.PI/5
		center := [3]f32{math.cos(a)*0.19, 0.73, math.sin(a)*0.19}
		left := center + [3]f32{-math.sin(a)*0.12, 0.03, math.cos(a)*0.12}
		right := center - [3]f32{-math.sin(a)*0.12, -0.03, math.cos(a)*0.12}
		tip := [3]f32{math.cos(a)*0.34, 0.81, math.sin(a)*0.34}
		triangle(&vertices, &indices, {0,0.74,0}, left, tip, 1)
		triangle(&vertices, &indices, {0,0.74,0}, tip, right, 1)
		b := a + 2*math.PI/5
		triangle(&vertices, &indices, {0,0.80,0}, {math.cos(a)*0.09,0.80,math.sin(a)*0.09}, {math.cos(b)*0.09,0.80,math.sin(b)*0.09}, 0.5)
	}
	p := dasset.Dasset_Primitive{vertices = make([]dasset.Dasset_Vertex, len(vertices)), indices = make([]u32, len(indices))}
	copy(p.vertices, vertices[:]); copy(p.indices, indices[:])
	delete(vertices); delete(indices)
	return p
}

// A tapered hexagonal trunk with a slight bend, reused with different yaw/scale.
tree_trunk :: proc() -> dasset.Dasset_Primitive {
	p := dasset.Dasset_Primitive{vertices = make([]dasset.Dasset_Vertex, 6*3*6), indices = make([]u32, 6*3*6)}
	for ring in 0..<3 do for side in 0..<6 {
		y0, y1 := f32(ring)/3, f32(ring+1)/3
		r0, r1 := 0.19-y0*0.09, 0.19-y1*0.09
		a, b := f32(side)*math.PI/3, f32(side+1)*math.PI/3
		points := [4][3]f32{{math.cos(a)*r0+y0*y0*0.18,y0,math.sin(a)*r0}, {math.cos(b)*r0+y0*y0*0.18,y0,math.sin(b)*r0},
			{math.cos(b)*r1+y1*y1*0.18,y1,math.sin(b)*r1}, {math.cos(a)*r1+y1*y1*0.18,y1,math.sin(a)*r1}}
		order := [6]int{0,2,1,0,3,2}
		for j in 0..<6 {
			i := (ring*6+side)*6+j
			p.vertices[i] = {position = points[order[j]], normal = {math.cos((a+b)*0.5),0.1,math.sin((a+b)*0.5)}, tangent = {1,0,0,1}}
			p.indices[i] = u32(i)
		}
	}
	return p
}
