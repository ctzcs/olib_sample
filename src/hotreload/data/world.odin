// 世界与快照存储。JSON 拥有值内容，不跨 DLL 保存地址或类型信息。
package data

import "core:encoding/json"

World :: struct {
	position: [2]f32,
	score: i64,
	collected: u32,
	steps: u64,
	elapsed: f64,
	paused: bool,
	distance: f32,
	trail: [dynamic][2]f32,
}

world_init :: proc(w: ^World) {
	w^ = {position = {140, 320}, trail = make([dynamic][2]f32)}
	append(&w.trail, w.position)
}

world_dispose :: proc(w: ^World) {
	delete(w.trail)
	w^ = {}
}

encode :: proc(w: ^World, allocator := context.allocator) -> ([]u8, bool) {
	bytes, err := json.marshal(w^, allocator = allocator)
	return bytes, err == nil
}

// 只能恢复到零值 World；失败后的部分分配仍由调用方 world_dispose 释放。
decode :: proc(bytes: []u8, w: ^World) -> bool {
	return json.unmarshal(bytes, w) == nil
}

fingerprint :: proc(w: ^World) -> u64 {
	bytes, ok := encode(w, context.temp_allocator)
	if !ok do return 0
	hash: u64 = 1469598103934665603
	for b in bytes do hash = (hash ~ u64(b)) * 1099511628211
	return hash
}
