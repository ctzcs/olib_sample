// 宿主（EXE）和游戏模块（DLL）共享的协议。改这里要升级 HOST_VERSION 并重启宿主。
package contract

import foster "olib:foster"

HOST_VERSION :: u64(1)

// 宿主持有并保证地址稳定；模块只在回调里借用。
Services :: struct {
	app: ^foster.App,
	move: [2]f32, // 方向键 / WASD 输入，每个分量 -1..1
}
