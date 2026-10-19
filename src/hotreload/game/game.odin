// 游戏模块：编译成 DLL，保存本文件后由宿主自动替换。方块的位置和拖尾在替换时保留。
package game

import reload "olib:core/hotreload"
import foster "olib:foster"
import mat "olib:kit/rendering/material"
import r2d "olib:kit/rendering/2d"

import "../contract"

// 试试改这几个值再保存：方块立刻变快、变大、变色，位置和拖尾不变。
SPEED :: f32(240)
SIZE :: f32(64)
COLOR :: foster.Color{100, 229, 185, 255}
TRAIL_LENGTH :: 24

// 状态可以放数组和 Render2D：热重载时整个 State 交给新版本，数组原样保留，
// Render2D 在 start 里重新创建。不要放字符串字面量、函数指针这类指向 DLL 自己数据的指针。
State :: struct {
	position: [2]f32,
	trail: [dynamic][2]f32, // 堆上的数组：新旧版本共用，退出时在 drop 里释放
	materials: mat.Material_Library,
	batcher: r2d.Render2D, // 资源：每个版本自己创建（start）和释放（stop）
}

// 把各个回调交给库；填 nil 的回调表示不需要。
hooks := reload.Game_Hooks(State, contract.Services){
	reset = reset, update = update, render = render,
	start = start, stop = stop, drop = drop,
	host_version = contract.HOST_VERSION,
}

// 照抄即可。
@(export)
olib_game_api :: proc "c" (version: u32, size: int, api: ^reload.API) -> bool {
	return reload.simple_api(version, size, api, &hooks)
}

// 第一次启动时调用一次（热重载时不调用，状态由库交接）。
reset :: proc(state: ^State, host: ^contract.Services) {
	state.position = {200, 200}
	state.trail = make([dynamic][2]f32)
}

// 每次加载新版本时调用：创建资源（会覆盖交接过来的旧 Render2D）。
start :: proc(state: ^State, host: ^contract.Services) {
	state.materials = {device = &host.app.GraphicsDevice}
	assert(r2d.init(&state.batcher, &state.materials) == "")
}

// 每次卸载旧版本时调用：释放这个版本的资源。
stop :: proc(state: ^State, host: ^contract.Services) {
	r2d.dispose(&state.batcher)
	mat.material_library_dispose(&state.materials)
}

// 游戏真正结束时调用一次：释放 State 拥有的堆数据。
drop :: proc(state: ^State, host: ^contract.Services) {
	delete(state.trail)
}

update :: proc(state: ^State, host: ^contract.Services, dt: f64) {
	state.position += host.move * SPEED * f32(dt)
	append(&state.trail, state.position)
	if len(state.trail) > TRAIL_LENGTH do ordered_remove(&state.trail, 0)
}

render :: proc(state: ^State, host: ^contract.Services, dt: f64) {
	r2d.reset(&state.batcher)
	for point, i in state.trail {
		fade := u8(40 + 100 * i / TRAIL_LENGTH)
		r2d.rect(&state.batcher, foster.Rect{point.x, point.y, SIZE, SIZE}, {COLOR.R, COLOR.G, COLOR.B, fade})
	}
	r2d.rect(&state.batcher, foster.Rect{state.position.x, state.position.y, SIZE, SIZE}, COLOR)
	r2d.submit(&state.batcher, {target = foster.DrawableTargetFromWindow(&host.app.Window)})
}
