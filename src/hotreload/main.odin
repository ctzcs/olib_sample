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
	session: reload.Session,
	watch: reload.Watch,
	last_status: reload.Build_Status,
	failed: bool,
}

main :: proc() {
	// Session / Watch / Services 的地址必须稳定，所以放在堆上。
	host := new(Host)
	defer free(host)
	app: foster.App
	foster.InitApp(&app, foster.DefaultAppConfig("olib / hot reload - WASD: move, Esc: quit", 960, 640))
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
	if !reload.init(&host.session, contract.HOST_VERSION, &host.services) {
		fail(app, "cannot start the reload session")
		return
	}
	// 后台编译 game/ 为 DLL；源码保存后重新编译，成功后在 update 里替换。
	sample_root, _ := filepath.abs(#directory + "/../..")
	library_root, _ := filepath.abs(#directory + "/../../../olib")
	game_root, _ := filepath.abs(#directory + "/game")
	defer delete(sample_root)
	defer delete(library_root)
	defer delete(game_root)
	if !reload.watch_init(&host.watch, {
		working_directory = sample_root,
		command = {"odin", "build", game_root, "-build-mode:dll",
			fmt.tprintf("-collection:olib=%s", library_root), "-out:{output}"},
		roots = {game_root},
	}) {
		fail(app, "cannot start the source watcher")
		return
	}
	fmt.println("Compiling the first version... then edit and save src/hotreload/game/game.odin")
}

update :: proc(app: ^foster.App) {
	host := foster.AppGetUserDataAs(app, Host)
	if host.failed do return
	keys := &app.Input.State.Keyboard
	if foster.KeyboardPressed(keys, .Escape) {
		foster.Exit(app)
		return
	}

	// 1. 检查编译结果。新版本编译好后，在这里（帧开始）替换游戏模块。
	reload.watch_update(&host.watch, f64(app.Time.Delta))
	if host.watch.status == .Ready {
		_ = SDL.WaitForGPUIdle(app.GraphicsDevice.Device) // 旧版本的 GPU 工作做完再卸载
		if reload.watch_apply(&host.watch, &host.session) == .Success {
			fmt.printfln("LIVE version %d", host.session.revision)
		} else {
			fmt.eprintln(host.session.diagnostic)
		}
	}
	if host.watch.status == .Error && host.last_status != .Error {
		fmt.eprintln(host.watch.diagnostic) // 编译失败：继续运行旧版本，修好后保存即可
	}
	host.last_status = host.watch.status

	// 2. 把输入交给游戏模块并更新它。
	move: [2]f32
	if foster.KeyboardDown(keys, .A) || foster.KeyboardDown(keys, .Left) do move.x -= 1
	if foster.KeyboardDown(keys, .D) || foster.KeyboardDown(keys, .Right) do move.x += 1
	if foster.KeyboardDown(keys, .W) || foster.KeyboardDown(keys, .Up) do move.y -= 1
	if foster.KeyboardDown(keys, .S) || foster.KeyboardDown(keys, .Down) do move.y += 1
	host.services.move = move
	reload.update(&host.session, f64(min(app.Time.Delta, 0.05)))
}

render :: proc(app: ^foster.App) {
	host := foster.AppGetUserDataAs(app, Host)
	if host.failed || !app.GraphicsDevice.InFrame do return
	target := foster.DrawableTargetFromWindow(&app.Window)
	foster.GraphicsDeviceClear(&app.GraphicsDevice, target, {12, 18, 26, 255})
	reload.render(&host.session, f64(app.Time.Delta))
}

shutdown :: proc(app: ^foster.App) {
	host := foster.AppGetUserDataAs(app, Host)
	_ = SDL.WaitForGPUIdle(app.GraphicsDevice.Device)
	reload.dispose(&host.session) // 先停止游戏模块，再等编译任务结束
	reload.watch_dispose(&host.watch)
}

fail :: proc(app: ^foster.App, message: string) {
	fmt.eprintln("hotreload:", message)
	foster.AppGetUserDataAs(app, Host).failed = true
	foster.Exit(app)
}
