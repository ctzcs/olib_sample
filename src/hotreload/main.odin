// 最简热重载宿主：窗口和图形设备常驻，游戏在 game/ 里编译成 DLL，保存源码后自动替换。
package main

import "core:fmt"
import "core:os"
import "core:path/filepath"

import reload "olib:core/hotreload"
import foster "olib:foster"

import SDL "vendor:sdl3"

import "contract"

Host :: struct {
	services: contract.Services,
	hot: reload.Hot,
	failed: bool,
}

main :: proc() {
	host := new(Host) // Hot 和 Services 的地址必须稳定，所以放在堆上
	defer free(host)
	app: foster.App
	foster.InitApp(&app, foster.DefaultAppConfig("olib / hot reload - WASD: move, F5: retry, Esc: quit", 960, 640))
	foster.AppSetUserData(&app, host)
	defer {
		foster.Dispose(&app)
		delete(app.GraphicsDevice.WindowRenderTarget.Attachments)
	}
	app.StartupProc = startup
	app.UpdateProc = update
	app.RenderProc = render
	app.ShutdownProc = shutdown
	foster.Run(&app)
	if host.failed do os.exit(1)
}

startup :: proc(app: ^foster.App) {
	host := foster.AppGetUserDataAs(app, Host)
	host.services.app = app
	sample_root, _ := filepath.abs(#directory + "/../..")
	defer delete(sample_root)
	// 后台编译 game/ 为 DLL；保存源码后重新编译，成功就在 hot_update 里替换。
	ok := reload.hot_init(&host.hot, {
		source = "src/hotreload/game",
		collections = {"olib=../olib"},
		working_directory = sample_root,
		services = &host.services,
		host_version = contract.HOST_VERSION,
		before_swap = wait_for_gpu, // 替换前等旧版本的 GPU 工作做完
		user_data = app,
	})
	if !ok {
		fmt.eprintln("hotreload: cannot start the reload session")
		host.failed = true
		foster.Exit(app)
	}
}

wait_for_gpu :: proc(user_data: rawptr) {
	app := cast(^foster.App)user_data
	_ = SDL.WaitForGPUIdle(app.GraphicsDevice.Device)
}

update :: proc(app: ^foster.App) {
	host := foster.AppGetUserDataAs(app, Host)
	if host.failed do return
	keys := &app.Input.State.Keyboard
	if foster.KeyboardPressed(keys, .Escape) do foster.Exit(app)
	if foster.KeyboardPressed(keys, .F5) do reload.hot_retry(&host.hot)

	move: [2]f32
	if foster.KeyboardDown(keys, .A) || foster.KeyboardDown(keys, .Left) do move.x -= 1
	if foster.KeyboardDown(keys, .D) || foster.KeyboardDown(keys, .Right) do move.x += 1
	if foster.KeyboardDown(keys, .W) || foster.KeyboardDown(keys, .Up) do move.y -= 1
	if foster.KeyboardDown(keys, .S) || foster.KeyboardDown(keys, .Down) do move.y += 1
	host.services.move = move

	// 检查编译结果、必要时替换游戏，然后转发游戏的 update。
	reload.hot_update(&host.hot, f64(min(app.Time.Delta, 0.05)))
}

render :: proc(app: ^foster.App) {
	host := foster.AppGetUserDataAs(app, Host)
	if host.failed || !app.GraphicsDevice.InFrame do return
	foster.GraphicsDeviceClear(&app.GraphicsDevice, foster.DrawableTargetFromWindow(&app.Window), {12, 18, 26, 255})
	reload.hot_render(&host.hot, f64(app.Time.Delta))
}

shutdown :: proc(app: ^foster.App) {
	wait_for_gpu(app)
	reload.hot_dispose(&foster.AppGetUserDataAs(app, Host).hot)
}
