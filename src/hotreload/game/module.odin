// 动态库入口：组装纯模拟与表现，所有私有对象均在卸载前释放。
package game

import "core:mem"

import reload "olib:core/hotreload"
import foster "olib:foster"

import "../contract"
import "../data"
import "../logic"
import "../view"

// 分区：协议 / 候选生命周期 / 快照 / 帧回调。
Instance :: struct {
	world: data.World,
	view: view.View,
}

@(export)
olib_game_api :: proc "c" (version: u32, size: int, api: ^reload.API) -> bool {
	if version != reload.API_VERSION || size != size_of(reload.API) do return false
	api^ = {host_version = contract.HOST_VERSION, state_version = 1,
		load = load, unload = unload, snapshot_size = snapshot_size, save = save, update = update, render = render}
	return true
}

load :: proc "c" (call: ^reload.Call, snapshot: reload.Snapshot) -> bool {
	context = call.host_context^
	s := new(Instance)
	call.instance = s
	if snapshot.version == 0 {
		data.world_init(&s.world)
	} else {
		if snapshot.version != 1 || !data.decode(snapshot.data, &s.world) do return false
		if !logic.valid(&s.world) || len(s.world.trail) == 0 do return false
	}
	host := cast(^contract.Services)call.services
	return view.init(&s.view, &host.app.GraphicsDevice, host.font, host.font_texture)
}

unload :: proc "c" (call: ^reload.Call) {
	context = call.host_context^
	s := cast(^Instance)call.instance
	if s == nil do return
	view.dispose(&s.view)
	data.world_dispose(&s.world)
	free(s)
}

snapshot_size :: proc "c" (call: ^reload.Call) -> int {
	context = call.host_context^
	s := cast(^Instance)call.instance
	bytes, ok := data.encode(&s.world, context.temp_allocator)
	return ok ? len(bytes) : -1
}

save :: proc "c" (call: ^reload.Call, destination: []u8) -> bool {
	context = call.host_context^
	s := cast(^Instance)call.instance
	bytes, ok := data.encode(&s.world, context.temp_allocator)
	if !ok || len(bytes) != len(destination) do return false
	mem.copy(raw_data(destination), raw_data(bytes), len(bytes))
	return true
}

update :: proc "c" (call: ^reload.Call, dt: f64) {
	context = call.host_context^
	s := cast(^Instance)call.instance
	host := cast(^contract.Services)call.services
	if host.input.toggle_pause do logic.apply(&s.world, {toggle_pause = true})
	move := host.input.move
	if s.view.ctx.input.keyboard do move = {}
	logic.step(&s.world, move, f32(dt))
}

render :: proc "c" (call: ^reload.Call, dt: f64) {
	context = call.host_context^
	s := cast(^Instance)call.instance
	host := cast(^contract.Services)call.services
	target := foster.DrawableTargetFromWindow(&host.app.Window)
	input := host.input
	commands := view.layout(&s.view, &s.world, logic.tuning(), f32(target.WidthInPixels),
		f32(target.HeightInPixels), host.scale, input.mouse, input.mouse_down,
		input.wheel, input.navigation, f32(dt))
	logic.apply(&s.world, commands)
	view.draw(&s.view, &s.world, target)
}
