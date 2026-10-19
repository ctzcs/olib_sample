// 游戏模块：编译成 DLL，保存本文件后由宿主自动替换。方块的位置在替换时保留。
package game

import reload "olib:core/hotreload"
import foster "olib:foster"

import "../contract"

// 试试改这三个值再保存：方块立刻变快、变大、变色，位置不变。
SPEED :: f32(240)
SIZE :: f32(64)
COLOR :: foster.Color{100, 229, 185, 255}

// 状态：只放可以按字节复制的数据（没有指针、切片、字符串），热重载时库自动保存和恢复。
State :: struct {
	position: [2]f32,
}

// 不属于状态的资源放包级变量：每个版本的 DLL 有自己的一份，卸载时随之释放。
batcher: foster.Batcher

// 照抄即可：告诉库这个模块的状态类型和各个回调。
@(export)
olib_game_api :: proc "c" (version: u32, size: int, api: ^reload.API) -> bool {
	return reload.simple_api(version, size, api, State, contract.Services,
		reset, start, stop, update, render, host_version = contract.HOST_VERSION)
}

// 第一次启动时调用一次（热重载时不调用，状态由库恢复）。
reset :: proc(state: ^State, host: ^contract.Services) {
	state.position = {200, 200}
}

// 每次加载新版本时调用：创建资源。
start :: proc(state: ^State, host: ^contract.Services) {
	foster.BatcherInit(&batcher, &host.app.GraphicsDevice, "hotreload sample")
}

// 每次卸载旧版本时调用：释放资源。
stop :: proc(state: ^State, host: ^contract.Services) {
	foster.BatcherDispose(&batcher)
}

update :: proc(state: ^State, host: ^contract.Services, dt: f64) {
	state.position += host.move * SPEED * f32(dt)
}

render :: proc(state: ^State, host: ^contract.Services, dt: f64) {
	foster.BatcherClear(&batcher)
	foster.BatcherRect(&batcher, foster.Rect{state.position.x, state.position.y, SIZE, SIZE}, COLOR)
	foster.BatcherRender(&batcher, foster.DrawableTargetFromWindow(&host.app.Window))
}
