package logic

import "core:math"

import "../data"
import "../def"

// 分区：可热修改的规则 / 世界校验与命令 / 模拟推进。
// 演示：保存后新速度与新奖励马上生效；已得分、已收集物品不重新计算。
MOVE_SPEED :: f32(220)
PICKUP_SCORE :: i64(10)

tuning :: proc() -> def.Tuning {
	return {move_speed = MOVE_SPEED, pickup_score = PICKUP_SCORE}
}

valid :: proc(w: ^data.World) -> bool {
	limits := def.WORLD_SIZE
	if len(w.trail) > 128 || w.score < 0 || w.elapsed < 0 ||
		math.is_nan(w.elapsed) || math.is_inf(w.elapsed) ||
		math.is_nan(w.distance) || math.is_inf(w.distance) || w.distance < 0 ||
		w.collected > 255 {
		return false
	}
	for v, i in w.position {
		if math.is_nan(v) || math.is_inf(v) || v < 0 || v > limits[i] do return false
	}
	for p in w.trail {
		for v, i in p {
			if math.is_nan(v) || math.is_inf(v) || v < 0 || v > limits[i] do return false
		}
	}
	return true
}

apply :: proc(w: ^data.World, commands: def.Commands) {
	if commands.new_run {
		data.world_dispose(w)
		data.world_init(w)
	} else if commands.toggle_pause {
		w.paused = !w.paused
	}
}

step :: proc(w: ^data.World, direction: [2]f32, dt: f32) {
	limits := def.WORLD_SIZE
	if w.paused do return
	w.steps += 1
	w.elapsed += f64(dt)
	n := math.sqrt(direction[0]*direction[0] + direction[1]*direction[1])
	if n > 0 {
		old := w.position
		for axis in 0..<2 {
			w.position[axis] = math.clamp(w.position[axis] + direction[axis]/n*MOVE_SPEED*dt,
				20, limits[axis]-20)
		}
		delta := w.position - old
		w.distance += math.sqrt(delta[0]*delta[0] + delta[1]*delta[1])
		last := w.trail[len(w.trail)-1]
		if d := w.position - last; d[0]*d[0] + d[1]*d[1] > 144 {
			if len(w.trail) == 128 {
				copy(w.trail[:127], w.trail[1:])
				resize(&w.trail, 127)
			}
			append(&w.trail, w.position)
		}
	}
	for p, i in def.PICKUPS {
		mask := u32(1) << u32(i)
		if w.collected & mask != 0 do continue
		d := p - w.position
		if d[0]*d[0] + d[1]*d[1] < 28*28 {
			w.collected |= mask
			w.score += PICKUP_SCORE
		}
	}
}
