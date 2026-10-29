package main

import "core:math/linalg"

import world "olib:kit/world"

// ==============================================================================
// 关卡：轴对齐盒子，两端用同一份数据做碰撞、射线与绘制
// ==============================================================================

Box :: struct {
	min, max: [3]f32,
	color:    [4]f32,
}

ARENA_HALF :: f32(20)

FLOOR_COLOR :: [4]f32{0.52, 0.56, 0.62, 1}
WALL_COLOR :: [4]f32{0.86, 0.79, 0.66, 1}
CRATE_COLOR :: [4]f32{0.92, 0.58, 0.28, 1}
PILLAR_COLOR :: [4]f32{0.36, 0.66, 0.72, 1}
TOWER_COLOR :: [4]f32{0.74, 0.76, 0.84, 1}

level: [dynamic]Box

box_at :: proc(center, size: [3]f32, color: [4]f32) -> Box {
	return {center - size * 0.5, center + size * 0.5, color}
}

// 中心塔可以经台阶箱跳上去；四角柱子、四块 L 形掩体、散落木箱。左右、前后对称。
level_build :: proc() {
	clear(&level)
	h := ARENA_HALF
	append(&level, Box{{-h - 1, -1, -h - 1}, {h + 1, 0, h + 1}, FLOOR_COLOR})
	append(&level, Box{{-h - 1, 0, -h - 1}, {h + 1, 4, -h}, WALL_COLOR})
	append(&level, Box{{-h - 1, 0, h}, {h + 1, 4, h + 1}, WALL_COLOR})
	append(&level, Box{{-h - 1, 0, -h}, {-h, 4, h}, WALL_COLOR})
	append(&level, Box{{h, 0, -h}, {h + 1, 4, h}, WALL_COLOR})

	append(&level, box_at({0, 1.1, 0}, {4, 2.2, 4}, TOWER_COLOR))
	for s in ([][2]f32{{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) {
		// 每面一级 1 m 高的台阶箱
		append(&level, box_at({s.x * 2.7, 0.5, s.y * 2.7}, {1.2, 1, 1.2}, CRATE_COLOR))
	}
	for sx in ([]f32{-1, 1}) {
		for sz in ([]f32{-1, 1}) {
			append(&level, box_at({sx * 14, 2.25, sz * 14}, {1.4, 4.5, 1.4}, PILLAR_COLOR))
			// L 形掩体
			append(&level, box_at({sx * 9, 1.1, sz * 7}, {5, 2.2, 0.8}, WALL_COLOR))
			append(&level, box_at({sx * 11.1, 1.1, sz * 8.9}, {0.8, 2.2, 3}, WALL_COLOR))
			// 木箱：一高一低
			append(&level, box_at({sx * 5.5, 0.6, sz * 13}, {1.2, 1.2, 1.2}, CRATE_COLOR))
			append(&level, box_at({sx * 6.7, 0.6, sz * 13.2}, {1.2, 1.2, 1.2}, CRATE_COLOR))
			append(&level, box_at({sx * 6.1, 1.8, sz * 13.1}, {1.2, 1.2, 1.2}, CRATE_COLOR))
			append(&level, box_at({sx * 16, 0.5, sz * 3}, {1, 1, 3}, CRATE_COLOR))
		}
	}
}

SPAWN_POINTS := [8][3]f32{
	{-17, 0, -17}, {17, 0, 17}, {-17, 0, 17}, {17, 0, -17},
	{0, 0, -16}, {0, 0, 16}, {-16, 0, 0}, {16, 0, 0},
}

overlaps :: proc(amin, amax, bmin, bmax: [3]f32) -> bool {
	return amin.x < bmax.x && amax.x > bmin.x && amin.y < bmax.y && amax.y > bmin.y && amin.z < bmax.z && amax.z > bmin.z
}

player_bounds :: proc(pos: [3]f32) -> (lo, hi: [3]f32) {
	return pos - {PLAYER_RADIUS, 0, PLAYER_RADIUS}, pos + {PLAYER_RADIUS, PLAYER_HEIGHT, PLAYER_RADIUS}
}

// 沿单轴移动后把角色推出所有重叠的盒子；返回是否碰到。
move_axis :: proc(pos: ^[3]f32, delta: f32, axis: int) -> bool {
	EPS :: f32(0.001)
	if delta == 0 {
		return false
	}
	pos[axis] += delta
	hit := false
	for b in level {
		lo, hi := player_bounds(pos^)
		if !overlaps(lo, hi, b.min, b.max) do continue
		if delta > 0 {
			pos[axis] -= hi[axis] - b.min[axis] + EPS
		} else {
			pos[axis] += b.max[axis] - lo[axis] + EPS
		}
		hit = true
	}
	return hit
}

// 射线与关卡最近的交点距离；没有交点返回 max_dist。
ray_level :: proc(origin, dir: [3]f32, max_dist: f32) -> f32 {
	ray, ok := world.ray3d_make(origin, dir)
	if !ok {
		return max_dist
	}
	best := max_dist
	for b in level {
		if t, hit := world.ray3d_hit_aabb(ray, b.min, b.max); hit && t >= 0 && t < best {
			best = t
		}
	}
	return best
}

// 命中盒：身体与头分开，头部伤害更高。
Hit_Part :: enum u8 { None, Body, Head }

ray_player :: proc(origin, dir: [3]f32, pos: [3]f32) -> (f32, Hit_Part) {
	ray, ok := world.ray3d_make(origin, dir)
	if !ok {
		return 0, .None
	}
	head_lo := pos + {-0.22, PLAYER_HEIGHT - 0.42, -0.22}
	head_hi := pos + {0.22, PLAYER_HEIGHT + 0.02, 0.22}
	if t, hit := world.ray3d_hit_aabb(ray, head_lo, head_hi); hit && t >= 0 {
		return t, .Head
	}
	body_lo, body_hi := player_bounds(pos)
	body_hi.y -= 0.42
	if t, hit := world.ray3d_hit_aabb(ray, body_lo, body_hi); hit && t >= 0 {
		return t, .Body
	}
	return 0, .None
}

// 视线（用于机器人）：两点之间没有关卡遮挡。
line_of_sight :: proc(a, b: [3]f32) -> bool {
	d := b - a
	dist := linalg.length(d)
	if dist < 0.01 {
		return true
	}
	return ray_level(a, d / dist, dist) >= dist - 0.05
}
