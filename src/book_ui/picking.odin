package main

// 射线拾取：屏幕像素 -> 书空间射线 -> 命中哪一页、页面上的哪个 UV。

// 分区：
//   射线与三角形 —— local_ray / ray_triangle
//   单张纸 —— pick_sheet_ray / pick_sheet
//   整本书 —— pick_book / page_faces_camera

import "core:math"
import foster "olib:foster"
import kw "olib:kit/world"

// ==============================================================================
// 射线与三角形
// ==============================================================================

// 屏幕像素 -> 书空间里的射线。先撤销模型矩阵，射线就能直接与纸的原始顶点求交。
local_ray :: proc(view: ^Book_View, p: foster.Vec2) -> (kw.Ray3D, bool) {
	ray, ok := kw.camera3d_screen_point_to_ray(&view.camera, p)
	if !ok do return {}, false
	origin, valid := kw.matrix4_transform_point(view.inverse_model, ray.origin)
	if !valid do return {}, false
	return kw.ray3d_make(origin, kw.matrix4_transform_vector(view.inverse_model, ray.direction))
}

// Möller-Trumbore 射线/三角形求交。命中时返回由三个角的 UV 插值出的 UV、
// 沿射线的距离，以及射线是否打在按绕序背向它的一面，也就是纸的背面。
ray_triangle :: proc(
	ray: kw.Ray3D,
	a, b, c: foster.Vec3,
	ua, ub, uc: foster.Vec2,
) -> (
	uv: foster.Vec2,
	distance: f32,
	back, hit: bool,
) {
	ab, ac := b - a, c - a
	p := kw.v3_cross(ray.direction, ac)
	det := kw.v3_dot(ab, p)
	if math.abs(det) < 0.00001 do return // 射线与三角形平行
	s := ray.origin - a
	u := kw.v3_dot(s, p) / det
	q := kw.v3_cross(s, ab)
	v := kw.v3_dot(ray.direction, q) / det
	distance = kw.v3_dot(ac, q) / det
	if u < -0.00001 || v < -0.00001 || u + v > 1.00001 || distance < 0 do return
	uv = ua * (1 - u - v) + ub * u + uc * v
	return uv, distance, det < 0, true
}

// ==============================================================================
// 单张纸
// ==============================================================================

// 纸上最近的命中点。`uv` 是页面 UV（背面已经翻转过）。
pick_sheet_ray :: proc(
	sheet: ^Sheet,
	ray: kw.Ray3D,
) -> (
	uv: foster.Vec2,
	distance: f32,
	back, hit: bool,
) {
	distance = math.INF_F32
	for row in 0..<ROWS {
		for col in 0..<COLS {
			// 每格两个三角形 a-c-b 和 a-d-c，与 upload_sheet 一致。
			a, b := sheet.points[row][col], sheet.points[row][col + 1]
			c, d := sheet.points[row + 1][col + 1], sheet.points[row + 1][col]
			u0, u1 := f32(col) / COLS, f32(col + 1) / COLS
			v0, v1 := f32(row) / ROWS, f32(row + 1) / ROWS
			for tri in 0..<2 {
				coords: foster.Vec2
				dist: f32
				reverse, found: bool
				if tri == 0 {
					coords, dist, reverse, found = ray_triangle(ray, a, c, b, {u0, v0}, {u1, v1}, {u1, v0})
				} else {
					coords, dist, reverse, found = ray_triangle(ray, a, d, c, {u0, v0}, {u0, v1}, {u1, v1})
				}
				if found && dist < distance {
					uv, distance, back, hit = flip_for_back(coords, reverse), dist, reverse, true
				}
			}
		}
	}
	return
}

// 屏幕像素 -> 某张纸上的页面 UV，要求从预期的那一面看到。
pick_sheet :: proc(
	view: ^Book_View,
	sheet: ^Sheet,
	p: foster.Vec2,
	expected_back: bool,
) -> (
	uv: foster.Vec2,
	hit: bool,
) {
	ray, ok := local_ray(view, p)
	if !ok do return
	back: bool
	uv, _, back, hit = pick_sheet_ray(sheet, ray)
	hit = hit && back == expected_back
	return
}

// ==============================================================================
// 整本书
// ==============================================================================

// 屏幕像素 -> (页码, 页面 UV)，没点到页面时页码为 -1。书的一切都会遮挡：
// 书壳、空中的纸，以及纸的另一面。
pick_book :: proc(world: ^World, p: foster.Vec2) -> (page: int, uv: foster.Vec2) {
	page = -1
	ray, ok := local_ray(&world.view, p)
	if !ok do return
	nearest := math.INF_F32
	for box in binding_boxes {
		distance, hit := kw.ray3d_hit_aabb(ray, box.lo, box.hi)
		if hit {
			nearest = min(nearest, distance)
		}
	}
	// 能点的面：左页是左侧纸的背面，右页是右侧纸的正面。空中的纸只遮挡。
	sheets := [3]^Sheet{&world.left_sheet, &world.right_sheet, &world.turning_sheet}
	page_on_sheet := [3]int{left_page(world.spread), right_page(world.spread), -1}
	clickable_from_back := [3]bool{true, false, false}
	sheet_count := world.turn.direction != 0 ? 3 : 2
	for i in 0..<sheet_count {
		coords, distance, back, hit := pick_sheet_ray(sheets[i], ray)
		if !hit || distance >= nearest do continue
		nearest = distance
		uv = coords
		page = back == clickable_from_back[i] ? page_on_sheet[i] : -1
	}
	return
}

// 读者看到的是摊开的书页（而不是封底）时为 true。
page_faces_camera :: proc(world: ^World) -> bool {
	normal := kw.matrix4_transform_vector(world.view.model, {0, 0, 1})
	return kw.v3_dot(normal, world.view.camera.position - world.pose.position) > 0
}
