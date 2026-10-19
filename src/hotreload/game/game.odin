// 游戏模块：编译成 DLL，保存本文件后由宿主自动替换。方块的位置在替换时保留。
package game

import "core:mem"

import reload "olib:core/hotreload"
import foster "olib:foster"

import "../contract"

// 试试改这三个值再保存：方块立刻变快、变大、变色，位置不变。
SPEED :: f32(240)
SIZE :: f32(64)
COLOR :: foster.Color{100, 229, 185, 255}

// 状态：只放可以按字节复制的数据（没有指针、切片、字符串），热重载时直接按字节保存和恢复。
State :: struct {
	position: [2]f32,
}

// 模块私有对象。GPU 对象（Batcher）每个版本自己创建、自己释放，不跨版本保留。
Instance :: struct {
	state: State,
	batcher: foster.Batcher,
	ready: bool,
}

// 宿主通过这个导出函数认出模块；照抄即可，只需要改 state_version（状态格式变了就加一）。
@(export)
olib_game_api :: proc "c" (version: u32, size: int, api: ^reload.API) -> bool {
	if version != reload.API_VERSION || size != size_of(reload.API) do return false
	api^ = {
		host_version = contract.HOST_VERSION, state_version = 1,
		load = load, unload = unload, snapshot_size = snapshot_size, save = save,
		update = update, render = render,
	}
	return true
}

// snapshot.version == 0 是第一次启动；否则恢复上一版保存的状态。失败也会调用 unload。
load :: proc "c" (call: ^reload.Call, snapshot: reload.Snapshot) -> bool {
	context = call.host_context^
	s := new(Instance)
	call.instance = s
	if snapshot.version == 0 {
		s.state.position = {200, 200}
	} else {
		if len(snapshot.data) != size_of(State) do return false
		mem.copy(&s.state, raw_data(snapshot.data), size_of(State))
	}
	host := cast(^contract.Services)call.services
	foster.BatcherInit(&s.batcher, &host.app.GraphicsDevice, "hotreload sample")
	s.ready = true
	return true
}

unload :: proc "c" (call: ^reload.Call) {
	context = call.host_context^
	s := cast(^Instance)call.instance
	if s == nil do return
	if s.ready do foster.BatcherDispose(&s.batcher)
	free(s)
}

// 保存状态：先报告长度，再写入宿主给的缓冲。
snapshot_size :: proc "c" (call: ^reload.Call) -> int {
	return size_of(State)
}

save :: proc "c" (call: ^reload.Call, destination: []u8) -> bool {
	s := cast(^Instance)call.instance
	if len(destination) != size_of(State) do return false
	mem.copy(raw_data(destination), &s.state, size_of(State))
	return true
}

update :: proc "c" (call: ^reload.Call, dt: f64) {
	s := cast(^Instance)call.instance
	host := cast(^contract.Services)call.services
	s.state.position += host.move * SPEED * f32(dt)
}

render :: proc "c" (call: ^reload.Call, dt: f64) {
	context = call.host_context^
	s := cast(^Instance)call.instance
	host := cast(^contract.Services)call.services
	foster.BatcherClear(&s.batcher)
	foster.BatcherRect(&s.batcher, foster.Rect{s.state.position.x, s.state.position.y, SIZE, SIZE}, COLOR)
	foster.BatcherRender(&s.batcher, foster.DrawableTargetFromWindow(&host.app.Window))
}
