package main

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:os"
import "core:strconv"

import foster "olib:foster"
import "olib:thirdparty/onet/objects"
import nr "olib:thirdparty/onet/runtime"
import "olib:thirdparty/onet/session"
import sim "olib:thirdparty/onet/simulation"
import "olib:thirdparty/onet/transport"
import "olib:thirdparty/onet/transport/udp"

// 联网第一人称射击示例：onet（复制、整世界预测、RPC、延迟补偿）+ Render3D。
// 不带参数启动时显示开始菜单；命令行可跳过菜单：
//   net_fps host [port]             开房并以本地玩家加入（默认 7778）
//   net_fps server [port]           纯服务器，窗口为观战视角
//   net_fps client [address] [port] 加入别人的房间
// 附加：bots <n> 由服务器加入 n 个机器人；join 让菜单默认停在加入页；
//       voicetest 用 440 Hz 正弦代替麦克风并一直发送，验证语音链路；openmic 不按 V 也一直发送；diag 启动即打开语音诊断（F1）；
//       mic <名称片段> / out <名称片段> 按设备名选麦克风与输出（如 mic USB、out Allure）；
//       enet 改用 ENet 后端（默认是 onet 原生 UDP，两端须一致）；
//       lag <ms> 让本进程出站包延迟 ms（两端都设置）；shot 运行几秒后截图并退出

DEFAULT_PORT :: 7778

Screen :: enum { Menu, Game }

App :: struct {
	screen:        Screen,
	menu:          Menu,
	view:          View,
	voice:         Voice,
	mode:          Mode,
	address:       string,
	port:          u16,
	session:       session.Session,
	server_reg:    objects.Registry,
	client_reg:    objects.Registry,
	runtime:       nr.Runtime,
	server_sim, client_sim: sim.Simulation_World,
	session_ready, server_ready, client_ready, runtime_ready: bool,
	server_sim_ready, client_sim_ready: bool,
	net_carry:     f32,
	lost:          bool,
	lost_reason:   Lost_Reason,
	// 本地输入
	move_bits:     Move_Bits,
	jump_seq:      u8,
	yaw, pitch:    f32,
	want_fire:     bool,
	fire_timer:    f32,
	show_scores:   bool,
	alive:         bool, // 上一帧本地角色是否活着，用于出生/重生时接过服务器给的朝向
	mouse_held:    bool,
	paused:        bool, // 鼠标已释放：Esc 第一次只暂停，点击窗口恢复，再按 Esc 回菜单
	had_focus:     bool,
	// 选项
	bots:          int,
	lag_ms:        int,
	join_tab:      bool,
	use_enet:      bool, // 默认用 onet 原生 UDP，各平台同一后端、无外部库
	udp:           udp.Transport,
	udp_ready:     bool,
	clock:         f32,
	shot:          bool,
	shot_target:   foster.Target,
	shot_pending:  bool,
	shot_ready:    bool, // 截图模式：画面里有可见对手
}

main :: proc() {
	if !run() do os.exit(1)
}

run :: proc() -> bool {
	a := new(App) // Runtime/Session/Registry 必须地址稳定
	defer free(a)
	level_build()
	defer delete(level)
	explicit, ok := parse_args(a, os.args[1:])
	if !ok {
		fmt.eprintln("usage: net_fps [host [port] | server [port] | client [address] [port]] [bots <n>] [lag <ms>] [join] [shot]")
		return false
	}
	defer net_stop(a)
	if explicit && !start_game(a) {
		fmt.eprintfln("net_fps: failed to start %v on port %d", a.mode, a.port)
		return false
	}

	config := foster.DefaultAppConfig("NetFps", 1280, 800)
	config.WindowTitle = "olib - Net FPS"
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

parse_args :: proc(a: ^App, args: []string) -> (explicit, ok: bool) {
	a.mode, a.address, a.port = .Host, "127.0.0.1", DEFAULT_PORT
	positional := make([dynamic]string, context.temp_allocator)
	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case "shot":
			a.shot = true
		case "voicetest":
			a.voice.test_tone = true
		case "openmic":
			a.voice.open_mic = true
		case "diag":
			a.voice.diag.show = true
		case "mic", "out":
			if i + 1 >= len(args) do return false, false
			if args[i] == "mic" do a.voice.mic_pick = args[i + 1]
			else do a.voice.out_pick = args[i + 1]
			i += 1
		case "join":
			a.join_tab = true
		case "enet":
			a.use_enet = true
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
	fmt.printfln("net_fps: %v on %s:%d", a.mode, a.mode == .Client ? a.address : "*", a.port)
	if a.server_ready {
		for i in 0 ..< a.bots {
			server_add_player(a, BOT_OWNER_BASE + transport.Connection_Id(i), true)
		}
	}
	a.screen = .Game
	a.alive, a.paused = false, false
	return true
}

leave_game :: proc(a: ^App, app: ^foster.App, reason: string) {
	net_stop(a)
	view_reset(&a.view)
	voice_reset(&a.voice)
	a.screen = .Menu
	a.menu.message_n = 0
	if reason != "" {
		fmt.println("net_fps:", reason)
		menu_set_message(&a.menu, reason)
	}
	a.clock = 0
	capture_mouse(a, app, false)
	foster.StartTextInput(&app.Window)
}

capture_mouse :: proc(a: ^App, app: ^foster.App, on: bool) {
	if a.mouse_held == on do return
	a.mouse_held = on
	foster.SetMouseRelativeMode(&app.Window, on)
}

startup :: proc(app: ^foster.App) {
	a := foster.AppGetUserDataAs(app, App)
	view_init(&a.view, app)
	voice_init(&a.voice, a)
	menu_init(&a.menu, a)
	if a.join_tab do menu_switch(&a.menu, .Join)
	if a.screen == .Menu do foster.StartTextInput(&app.Window)
}

shutdown :: proc(app: ^foster.App) {
	a := foster.AppGetUserDataAs(app, App)
	capture_mouse(a, app, false)
	if a.shot do foster.TargetDispose(&a.shot_target)
	menu_destroy(&a.menu)
	voice_shutdown(&a.voice)
	view_destroy(&a.view)
}

update :: proc(app: ^foster.App) {
	a := foster.AppGetUserDataAs(app, App)
	dt := min(app.Time.Delta, 0.1)
	a.clock += dt
	a.view.time += dt
	if a.screen == .Menu {
		menu_update(a, app)
		if a.screen == .Game do a.alive = false
		return
	}
	keys := &app.Input.State.Keyboard
	mouse := &app.Input.State.Mouse
	if foster.KeyboardPressed(keys, .Escape) {
		if a.paused || !a.client_ready {
			leave_game(a, app, "")
			return
		}
		a.paused = true
	}
	// 切走窗口（Alt+Tab 等）也释放鼠标；回到游戏要点一下窗口。
	// 只认“有焦点 → 失去焦点”的变化：窗口刚打开的几帧本来就没有焦点，不算暂停。
	focused := foster.Focused(&app.Window)
	if !a.shot && a.had_focus && !focused do a.paused = true
	a.had_focus = focused
	resumed := false
	if a.paused && foster.MousePressed(mouse, .Left) {
		a.paused, resumed = false, true
	}
	capture_mouse(a, app, !a.shot && a.client_ready && !a.paused && focused)
	a.show_scores = foster.KeyboardDown(keys, .Tab)
	if a.client_ready && (a.paused || resumed) {
		// 暂停时不转视角、不移动、不开火；网络照常推进。恢复的那次点击不算开枪。
		a.move_bits, a.want_fire = {}, false
	} else if a.client_ready {
		read_input(a, app, dt)
		_, me := local_player(a)
		alive := me != nil && me.respawn <= 0
		if alive && !a.alive {
			// 出生/重生：接过服务器给的朝向，之后由鼠标控制。
			a.yaw, a.pitch = me.yaw, me.pitch
		}
		a.alive = alive
		if a.shot do autopilot(a)
		try_fire(a)
	}
	net_update(a, dt)
	if reason, lost := net_lost(a); lost {
		leave_game(a, app, reason)
		return
	}
	// M / O 切换麦克风与输出设备（暂停画面列出当前设备与电平）。
	// 截图模式不读这些键：自动测试窗口弹出时会抢焦点，避免把别处的按键当成输入。
	if !a.shot {
		if foster.KeyboardPressed(keys, .M) do voice_cycle_mic(&a.voice)
		if foster.KeyboardPressed(keys, .O) do voice_cycle_output(&a.voice)
		if foster.KeyboardPressed(keys, .L) do voice_toggle_monitor(&a.voice)
		if foster.KeyboardPressed(keys, .F1) do a.voice.diag.show = !a.voice.diag.show
		if foster.KeyboardPressed(keys, .T) do voice_beep(&a.voice)
	}
	// 暂停时不发言，但继续播放别人的声音。
	if a.client_ready do voice_update(a, dt, !a.shot && !a.paused && foster.KeyboardDown(keys, .V))
	view_update(a, dt)
}

// 截图模式：3 秒后转向最近的可见对手并持续开火，覆盖射击、广播与命中反馈整条链路。
autopilot :: proc(a: ^App) {
	_, me := local_player(a)
	a.shot_ready = false
	if me == nil || a.clock < 3 do return
	eye := eye_of(me.pos)
	best := f32(1e9)
	for _, r in a.view.remotes {
		d := linalg.length(r.pos - me.pos)
		if d < best && line_of_sight(eye, r.pos + {0, 1.2, 0}) {
			best = d
			to := r.pos + {0, 1.2, 0} - eye
			a.yaw = math.atan2(-to.x, -to.z)
			a.pitch = math.atan2(to.y, linalg.length(to.xz))
		}
	}
	a.want_fire = best < 1e9
	a.shot_ready = a.want_fire && me.respawn <= 0
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
	// 游戏画面等到 6 s 后、画面里有对手时再截（最迟 12 s）。
	waiting := a.screen == .Menu ? a.clock < 1.5 : a.clock < 6 || (!a.shot_ready && a.clock < 12)
	if waiting {
		draw_screen(a, app, window)
		return
	}
	w, h := window.WidthInPixels, window.HeightInPixels
	foster.TargetInit(&a.shot_target, &app.GraphicsDevice, w, h, "NetFpsShot")
	draw_screen(a, app, foster.DrawableTargetFromTarget(&a.shot_target))
	a.shot_pending = true
}

draw_screen :: proc(a: ^App, app: ^foster.App, target: foster.DrawableTarget) {
	if a.screen == .Menu {
		menu_render(a, app, target)
	} else {
		render_game(a, app, target)
	}
}

save_shot :: proc(a: ^App) {
	tex := foster.TargetAttachment(&a.shot_target, 0)
	bytes := foster.TextureDownloadData(tex)
	defer delete(bytes)
	w, h := tex.Width, tex.Height
	if len(bytes) < w * h * 4 {
		fmt.eprintln("net_fps: capture readback failed")
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
	name := fmt.tprintf("%s/net_fps_%s.png", directory, suffix)
	fmt.println(name, foster.ImageWritePng(&image, name))
	vo := &a.voice
	fmt.printfln("net_fps: voice ready=%v rnnoise=%v sent=%d received=%d talkers=%d playback_peak=%.2f %s", vo.ready, vo.has_rnnoise, vo.sent, vo.received, len(vo.receivers), vo.peak, vo.status)
}
