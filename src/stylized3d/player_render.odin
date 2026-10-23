package main

import "core:math"
import r3d "olib:kit/rendering/3d"
import world "olib:kit/world"

// Small procedural character: feet and arms make motion legible, eyes show facing.
record_player :: proc(s: ^State) -> bool {
	p := s.player
	speed := math.sqrt(p.velocity.x*p.velocity.x + p.velocity.z*p.velocity.z)
	stride: f32 = p.grounded ? math.sin(p.gait) * min(speed / 4.2, 1) : 0
	bob: f32 = p.grounded ? math.abs(stride)*0.035 : 0
	transform := place(p.position, {1, 1, 1}, p.yaw)
	parts := [?]struct {position, scale: [3]f32, color: [4]f32} {
		{{0, 0.77 + bob, 0}, {0.30, 0.46, 0.25}, {0.60, 0.38, 0.72, 1}},
		{{0, 1.38 + bob, -0.02}, {0.29, 0.30, 0.28}, {1.0, 0.84, 0.72, 1}},
		{{0, 1.49 + bob, 0.07}, {0.32, 0.28, 0.28}, {0.90, 0.26, 0.28, 1}},
		{{-0.17, 0.16 + max(0, stride)*0.12, -stride*0.18}, {0.13, 0.16, 0.21}, {0.24, 0.21, 0.36, 1}},
		{{0.17, 0.16 + max(0, -stride)*0.12, stride*0.18}, {0.13, 0.16, 0.21}, {0.24, 0.21, 0.36, 1}},
		{{-0.34, 0.79 + bob, stride*0.16}, {0.11, 0.27, 0.12}, {0.66, 0.43, 0.77, 1}},
		{{0.34, 0.79 + bob, -stride*0.16}, {0.11, 0.27, 0.12}, {0.66, 0.43, 0.77, 1}},
		{{-0.10, 1.42 + bob, -0.275}, {0.035, 0.05, 0.025}, {0.13, 0.14, 0.22, 1}},
		{{0.10, 1.42 + bob, -0.275}, {0.035, 0.05, 0.025}, {0.13, 0.14, 0.22, 1}},
	}
	items: [len(parts)]r3d.Model_Item
	for part, i in parts {
		items[i] = {world.matrix4_multiply(place(part.position, part.scale), transform), part.color}
	}
	bounds := BALL_BOUNDS
	if r3d.models(&s.renderer, &s.ball, s.hero, items[:], &bounds) != .None do return false
	return r3d.models(&s.renderer, &s.ball, s.sun_caster, items[:], &bounds) == .None
}
