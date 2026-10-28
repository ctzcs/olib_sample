package main

import "core:fmt"
import "core:os"
import "core:strconv"

import foster "olib:foster"
import "olib:thirdparty/onet/objects"
import nr "olib:thirdparty/onet/runtime"
import "olib:thirdparty/onet/session"
import sim "olib:thirdparty/onet/simulation"
import "olib:thirdparty/onet/transport"
import "olib:thirdparty/onet/transport/udp"

// 不带参数启动时显示开始菜单，在菜单里选择开房或加入。
// 命令行可跳过菜单：
//   net_arena host [port]             开房并以本地玩家加入（默认 7777）
//   net_arena server [port]           纯服务器，窗口为观战视角
//   net_arena client [address] [port] 加入别人的房间
// 附加：bots <n> 由服务器加入 n 个机器人；join 让菜单默认停在加入页；
//       udp 改用原生 UDP 后端；lag <ms> 让本进程出站包延迟 ms（任一后端，两端都设置）；
//       shot 运行几秒后截图到 library/screenshots 并退出

DEFAULT_PORT :: 7777

Screen :: enum { Menu, Game }

App :: struct {
	screen:        Screen,
	menu:          Menu,
	mode:          Mode,
	address:       string,
	port:          u16,
	session:       session.Session,
	server_reg:    objects.Registry,
	client_reg:    objects.Registry,
	runtime:       nr.Runtime,
	session_ready, server_ready, client_ready, runtime_ready: bool,
	net_carry:     f32,
	lost:          bool,
	lost_reason:   Lost_Reason,
	// 服务器
	match:         ^Match,
	coin_timer:    f32,
	server_sim, client_sim: sim.Simulation_World,
	server_sim_ready, client_sim_ready: bool,
	udp:           udp.Transport,
	udp_ready:     bool,
	use_udp:       bool,
	lag_ms:        int,
	// 客户端输入
	dash_seq:      u8,
	input_bits:    Input_Bits,
	view:          View,
	bots:          int,
	join_tab:      bool,
	clock:         f32,
	shot:          bool,
	shot_target:   foster.Target,
	shot_pending:  bool,
	status_timer:  f32,
}

main :: proc() {
	if !run() do os.exit(1)
}

run :: proc() -> bool {
	a := new(App) // Runtime/Session/Registry 必须地址稳定
	defer free(a)
	explicit, ok := parse_args(a, os.args[1:])
	if !ok {
		fmt.eprintln("usage: net_arena [host [port] | server [port] | client [address] [port]] [bots <n>] [join] [shot]")
		return false
	}
	defer net_stop(a)
	if explicit && !start_game(a) {
		fmt.eprintfln("net_arena: failed to start %v on port %d", a.mode, a.port)
		return false
	}

	config := foster.DefaultAppConfig("NetArena", 1280, 800)
	config.WindowTitle = "olib - Net Arena"
	app: foster.App
	foster.InitApp(&app, config)
	defer foster.Dispose(&app)
	foster.AppSetUserData(&app, a)
	app.StartupProc = startup
	app.ShutdownProc = shutdown
	app.UpdateProc = update
	app.RenderProc = render
	foster.Run(&app)
	return true
}

// 返回 explicit=true 表示命令行指定了模式，直接进入游戏。
parse_args :: proc(a: ^App, args: []string) -> (explicit, ok: bool) {
	a.mode, a.address, a.port = .Host, "127.0.0.1", DEFAULT_PORT
	positional := make([dynamic]string, context.temp_allocator)
	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case "shot":
			a.shot = true
		case "join":
			a.join_tab = true
		case "udp":
			a.use_udp = true
		case "lag":
			if i + 1 >= len(args) do return false, false
			ms, ms_ok := strconv.parse_int(args[i + 1], 10)
			if !ms_ok || ms < 0 || ms > 2000 do return false, false
			a.lag_ms = ms
			i += 1
		case "bots":
			if i + 1 >= len(args) do return false, false
			n, n_ok := strconv.parse_int(args[i + 1], 10)
			if !n_ok || n < 0 || n > MAX_PLAYERS - 1 do return false, false
			a.bots = n
			i += 1
		case:
			append(&positional, args[i])
		}
	}
	rest := positional[:]
	if len(rest) == 0 {
		return false, true
	}
	switch rest[0] {
	case "host": a.mode = .Host
	case "server": a.mode = .Server
	case "client": a.mode = .Client
	case: return false, false
	}
	rest = rest[1:]
	if a.mode == .Client && len(rest) > 0 {
		a.address = rest[0]
		rest = rest[1:]
	}
	if len(rest) > 0 {
		port, port_ok := strconv.parse_uint(rest[0], 10)
		if !port_ok || port == 0 || port > 65535 do return false, false
		a.port = u16(port)
	}
	return true, true
}

start_game :: proc(a: ^App) -> bool {
	if !net_start(a) {
		net_stop(a)
		return false
	}
	fmt.printfln("net_arena: %v on %s:%d", a.mode, a.mode == .Client ? a.address : "*", a.port)
	if a.server_ready {
		for i in 0 ..< a.bots {
			server_add_player(a, BOT_OWNER_BASE + transport.Connection_Id(i), true)
		}
	}
	a.screen = .Game
	return true
}

leave_game :: proc(a: ^App, app: ^foster.App, reason: string) {
	net_stop(a)
	view_reset(&a.view)
	a.screen = .Menu
	a.menu.message_n = 0
	if reason != "" {
		fmt.println("net_arena:", reason)
		menu_set_message(&a.menu, reason)
	}
	a.clock = 0 // shot 从回到菜单起重新计时，截下带原因的菜单
	foster.StartTextInput(&app.Window)
}

startup :: proc(app: ^foster.App) {
	a := foster.AppGetUserDataAs(app, App)
	view_init(&a.view, app)
	menu_init(&a.menu, a)
	if a.join_tab do menu_switch(&a.menu, .Join)
	if a.screen == .Menu do foster.StartTextInput(&app.Window)
}

shutdown :: proc(app: ^foster.App) {
	a := foster.AppGetUserDataAs(app, App)
	if a.shot do foster.TargetDispose(&a.shot_target)
	menu_destroy(&a.menu)
	view_destroy(&a.view)
}

update :: proc(app: ^foster.App) {
	a := foster.AppGetUserDataAs(app, App)
	dt := min(app.Time.Delta, 0.1)
	a.clock += dt
	a.view.time += dt
	if a.screen == .Menu {
		menu_update(a, app)
		return
	}
	keys := &app.Input.State.Keyboard
	if foster.KeyboardPressed(keys, .Escape) {
		leave_game(a, app, "")
		return
	}
	net_update(a, dt)
	if a.mode == .Server {
		// 纯服务器定期报告规模：开启 reclaim_despawned 后对象表不随金币生成/拾取增长。
		a.status_timer += dt
		if a.status_timer >= 30 {
			a.status_timer = 0
			fmt.printfln("net_arena: %d objects (%d active), %d connections", len(a.server_reg.objects), objects.active_object_count(&a.server_reg), session.connection_count(&a.session))
		}
	}
	if reason, lost := net_lost(a); lost {
		leave_game(a, app, reason)
		return
	}
	if a.client_ready {
		read_input(a, keys)
	}
	view_update(a, dt)
}

render :: proc(app: ^foster.App) {
	a := foster.AppGetUserDataAs(app, App)
	window := foster.DrawableTargetFromWindow(&app.Window)
	if !a.shot {
		draw_screen(a, app, window)
		return
	}
	// 截图：先渲染进离屏目标，下一帧读回并写 PNG。
	if a.shot_pending {
		save_shot(a)
		foster.Exit(app)
		return
	}
	if a.clock < (a.screen == .Menu ? 1.5 : 7) {
		draw_screen(a, app, window)
		return
	}
	w, h := window.WidthInPixels, window.HeightInPixels
	foster.TargetInit(&a.shot_target, &app.GraphicsDevice, w, h, "NetArenaShot")
	draw_screen(a, app, foster.DrawableTargetFromTarget(&a.shot_target))
	a.shot_pending = true
}

draw_screen :: proc(a: ^App, app: ^foster.App, target: foster.DrawableTarget) {
	if a.screen == .Menu {
		menu_render(a, app, target)
	} else {
		view_render(a, app, target)
	}
}

save_shot :: proc(a: ^App) {
	tex := foster.TargetAttachment(&a.shot_target, 0)
	bytes := foster.TextureDownloadData(tex)
	defer delete(bytes)
	w, h := tex.Width, tex.Height
	if len(bytes) < w * h * 4 {
		fmt.eprintln("net_arena: capture readback failed")
		return
	}
	image := foster.ImageMake(w, h)
	defer foster.ImageDispose(&image)
	for &pixel, i in image.Pixels {
		pixel = {bytes[i * 4], bytes[i * 4 + 1], bytes[i * 4 + 2], bytes[i * 4 + 3]}
	}
	directory :: #directory + "/../../library/screenshots"
	os.make_directory_all(directory)
	suffix := a.screen == .Menu ? (a.menu.tab == .Host ? "menu_host" : "menu_join") : fmt.tprintf("%v", a.mode)
	name := fmt.tprintf("%s/net_arena_%s.png", directory, suffix)
	fmt.println(name, foster.ImageWritePng(&image, name))
}
