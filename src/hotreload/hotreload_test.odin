#+test
package main

import "core:testing"

import "data"
import "def"
import "logic"

// 无窗口回归：快照值与所有权、暂停和规则。
@(test)
snapshot_roundtrip_owns_dynamic_trail :: proc(t: ^testing.T) {
	w: data.World
	data.world_init(&w)
	defer data.world_dispose(&w)
	logic.step(&w, {1, 0}, 0.25)
	w.score = 37
	w.collected = 3
	w.paused = true
	bytes, ok := data.encode(&w)
	testing.expect(t, ok)
	defer delete(bytes)
	restored: data.World
	defer data.world_dispose(&restored)
	testing.expect(t, data.decode(bytes, &restored) && logic.valid(&restored))
	testing.expect(t, data.fingerprint(&restored) == data.fingerprint(&w))
	testing.expect(t, raw_data(restored.trail) != raw_data(w.trail))
	restored.trail[0] = {999, 639}
	testing.expect(t, w.trail[0] == [2]f32{140, 320})
	testing.expect(t, w.score == 37 && w.collected == 3 && w.paused)
}

@(test)
pause_pickup_and_reset :: proc(t: ^testing.T) {
	w: data.World
	data.world_init(&w)
	defer data.world_dispose(&w)
	w.position = def.PICKUPS[0]
	logic.step(&w, {}, 0.1)
	testing.expect(t, w.score == logic.PICKUP_SCORE && w.collected == 1)
	logic.step(&w, {}, 0.1)
	testing.expect(t, w.score == logic.PICKUP_SCORE, "each node is collected once")
	logic.apply(&w, {toggle_pause = true})
	before := data.fingerprint(&w)
	logic.step(&w, {1, 0}, 1)
	testing.expect(t, data.fingerprint(&w) == before, "pause freezes the entire simulation")
	logic.apply(&w, {new_run = true})
	testing.expect(t, w.score == 0 && w.collected == 0 && !w.paused && len(w.trail) == 1)
	logic.step(&w, {1, 0}, 0.25)
	testing.expect(t, abs(w.position[0]-(140+logic.MOVE_SPEED*0.25)) < 0.001)
	w.position[0] = -1
	testing.expect(t, !logic.valid(&w), "invalid restored positions must be rejected")
}
