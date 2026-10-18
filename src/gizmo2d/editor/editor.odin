package editor

import "core:math"

import foster "olib:foster"
import gizmo "olib:kit/gizmo"
import world "olib:kit/world"

// 三个固定对象、三个视口共用一份会话。槽位不删除、不复用；完整值快照归会话所有。
// 分区：文档事务 / 视口输入
Values :: [3]gizmo.Transform2D
Edit :: struct {
	before, after: Values,
}
Session :: struct {
	values, saved: Values,
	cameras: [3]world.Camera2D,
	handles: [3]gizmo.Transform_Gizmo2D,
	history: [dynamic]Edit,
	before: Values,
	cursor, target: int,
	version: u64,
	active, dirty, cancel_tools: bool,
}

// ==============================================================================
// 文档事务
// ==============================================================================

initial_values :: proc() -> Values {
	return {{rotation = 0.25, scale = {1.2, 0.8}},
		{rotation = 0.25, scale = {1.2, 0.8}}, {rotation = 0.25, scale = {1.2, 0.8}}}
}

init :: proc(e: ^Session) {
	e.values = initial_values()
	e.saved = e.values
	reset_cameras(e)
}

destroy :: proc(e: ^Session) {
	cancel(e)
	delete(e.history)
	e^ = {}
}

@(private)
assign :: proc(e: ^Session, values: Values) {
	if e.values == values do return
	e.values = values
	e.version += 1
	e.dirty = values != e.saved
}

begin :: proc(e: ^Session, target: int) -> bool {
	if e.active || target < 0 || target >= len(e.values) do return false
	e.before = e.values
	e.target = target
	e.active = true
	return true
}

apply :: proc(e: ^Session, values: Values) -> bool {
	if !e.active do return false
	for v in values {
		for n in ([5]f32{v.position.x, v.position.y, v.rotation, v.scale.x, v.scale.y}) {
			if math.is_nan(n) || math.is_inf(n) do return false
		}
		if v.scale.x <= 0 || v.scale.y <= 0 do return false
	}
	assign(e, values)
	return true
}

commit :: proc(e: ^Session) {
	if !e.active do return
	e.active = false
	if e.before == e.values do return
	resize(&e.history, e.cursor)
	append(&e.history, Edit{e.before, e.values})
	e.cursor = len(e.history)
}

cancel :: proc(e: ^Session) {
	if e.active do assign(e, e.before)
	e.active = false
	e.cancel_tools = true
}

undo :: proc(e: ^Session) {
	cancel(e)
	if e.cursor <= 0 do return
	e.cursor -= 1
	assign(e, e.history[e.cursor].before)
}

redo :: proc(e: ^Session) {
	cancel(e)
	if e.cursor >= len(e.history) do return
	assign(e, e.history[e.cursor].after)
	e.cursor += 1
}

reset :: proc(e: ^Session) {
	cancel(e)
	begin(e, 0)
	apply(e, initial_values())
	commit(e)
	reset_cameras(e)
}

reset_cameras :: proc(e: ^Session) {
	cancel(e)
	for &c in e.cameras {
		world.camera2d_init(&c, 1, 1)
		world.camera2d_set_ppu(&c, 54)
		world.camera2d_set_rotation(&c, 0.15)
	}
}

// ==============================================================================
// 视口输入
// ==============================================================================

accept :: proc(e: ^Session, i: int, result: gizmo.Transform_Result2D) {
	if result.started do begin(e, i)
	if result.cancelled {
		cancel(e)
	} else {
		if result.changed && e.active && e.target == i {
			values := e.values
			values[i] = result.transform
			apply(e, values)
		}
		if result.ended do commit(e)
	}
}

input :: proc(e: ^Session, viewports: [3]foster.Rect, input: gizmo.Translation_Input, scale: f32) {
	captured := false
	for g in e.handles do captured = captured || g.captured
	cancel_tools := e.cancel_tools
	e.cancel_tools = false
	for i in 0..<3 {
		event := input
		event.allow_start = input.allow_start && !captured && !e.active
		event.cancel = input.cancel || cancel_tools
		// 松开帧也先接受最后的有效位置，再结束事务；取消总是优先。
		if e.handles[i].dragging && !event.down {
			last := event
			last.down = true
			last.pressed = false
			accept(e, i, gizmo.transform2d_update(&e.handles[i], &e.cameras[i],
				e.values[i], viewports[i], gizmo.Mode(i), last, scale))
		}
		r := gizmo.transform2d_update(&e.handles[i], &e.cameras[i], e.values[i], viewports[i],
			gizmo.Mode(i), event, scale)
		accept(e, i, r)
		captured = captured || r.captured
	}
}
