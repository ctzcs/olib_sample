package main

import "core:fmt"

import foster "olib:foster"
import "olib:thirdparty/onet/objects"
import "olib:thirdparty/onet/rpc"
import nr "olib:thirdparty/onet/runtime"
import "olib:thirdparty/onet/session"
import sim "olib:thirdparty/onet/simulation"
import "olib:thirdparty/onet/transport"
import "olib:thirdparty/onet/transport/udp"

// ==============================================================================
// 网络生命周期：一个 Session + 一个 Runtime，由 Foster 的 update 单线程驱动
// ==============================================================================

Mode :: enum { Host, Server, Client }
CONNECT_TIMEOUT_MS :: 5000
// App 的 session 字段会遮住包名，字段类型用这个别名。
Lost_Reason :: session.Server_Disconnect_Reason

net_start :: proc(a: ^App) -> bool {
	s := &a.session
	session.init(s, TICK_MS)
	a.session_ready = true
	if !a.use_enet {
		// onet 原生 UDP（纯 Odin + 系统 socket），Windows/macOS/Linux 同一实现；Session 借用它，最后销毁。
		if !udp.init(&a.udp, udp.default_config()) || !session.set_driver(s, udp.driver(&a.udp)) {
			return false
		}
		a.udp_ready = true
	}
	if a.lag_ms > 0 {
		session.set_network_conditions(s, {seed = 1, latency_ms = a.lag_ms, jitter_ms = a.lag_ms / 5})
	}
	cfg: nr.Config
	if a.mode != .Client {
		objects.registry_init(&a.server_reg)
		objects.register_factory(&a.server_reg, PLAYER_TYPE, player_factory)
		cfg.server_registry = &a.server_reg
		a.server_ready = true
	}
	if a.mode != .Server {
		objects.registry_init(&a.client_reg, false)
		objects.register_factory(&a.client_reg, PLAYER_TYPE, player_factory)
		cfg.client_registry = &a.client_reg
		a.client_ready = true
	}
	if !nr.init(&a.runtime, s, cfg) {
		return false
	}
	a.runtime_ready = true
	s.userdata = a
	s.on_tick = on_tick
	s.on_client_connected = on_connected
	s.on_client_disconnected = on_disconnected
	s.on_server_disconnected = on_server_lost
	s.limits.connect_timeout_ms = CONNECT_TIMEOUT_MS
	if a.server_ready {
		if !bind_world(&a.runtime.server, &a.server_sim, true, a) do return false
		a.server_sim_ready = true
		m := &a.runtime.server.rpc
		m.userdata = a
		rpc.register(m, RPC_FIRE, on_fire)
		// 服务器自己发起的广播也会在本地调用一次 handler，handler 里按 authority 跳过。
		rpc.register(m, RPC_SHOT, on_shot, .Any_Observer)
		rpc.register(m, RPC_KILL, on_kill, .Any_Observer)
		rpc.register(m, RPC_VOICE, on_voice) // 只转发：说话人对象的 controller 才能发
	}
	if a.client_ready {
		if !bind_world(&a.runtime.client, &a.client_sim, false, a) do return false
		a.client_sim_ready = true
		m := &a.runtime.client.rpc
		m.userdata = a
		rpc.declare(m, RPC_FIRE)
		rpc.register(m, RPC_SHOT, on_shot, .Any_Observer)
		rpc.register(m, RPC_KILL, on_kill, .Any_Observer)
		rpc.register(m, RPC_VOICE, on_voice)
	}

	switch a.mode {
	case .Server:
		return session.start_server(s, a.port, MAX_PLAYERS)
	case .Client:
		return session.start_client(s, a.address, a.port)
	case .Host:
		return session.start_host(s, MAX_PLAYERS, a.port)
	}
	return false
}

bind_world :: proc(w: ^nr.World, world: ^sim.Simulation_World, authority: bool, a: ^App) -> bool {
	cfg := sim.World_Config{authority = authority, fixed_dt = f64(TICK_DT), capacity = 128}
	if sim.world_init(world, cfg) != .Ok {
		return false
	}
	return nr.bind_simulation(w, world) && nr.register_world_component(w, PLAYER_TYPE, build_player_system, a)
}

// 销毁顺序：Runtime（close 一次完成）→ Simulation_World → Registry → Session → UDP 后端。
net_stop :: proc(a: ^App) {
	if a.runtime_ready do nr.close(&a.runtime)
	if a.client_sim_ready do sim.world_destroy(&a.client_sim)
	if a.server_sim_ready do sim.world_destroy(&a.server_sim)
	if a.client_ready do objects.registry_destroy(&a.client_reg)
	if a.server_ready do objects.registry_destroy(&a.server_reg)
	if a.session_ready do session.destroy(&a.session)
	if a.udp_ready do udp.destroy(&a.udp)
	// 清零后可以从菜单再开一局；重复调用是空操作。
	a.session, a.server_reg, a.client_reg, a.runtime = {}, {}, {}, {}
	a.server_sim, a.client_sim, a.udp = {}, {}, {}
	a.udp_ready = false
	a.session_ready, a.server_ready, a.client_ready, a.runtime_ready = false, false, false, false
	a.server_sim_ready, a.client_sim_ready = false, false
	a.net_carry, a.jump_seq, a.move_bits, a.fire_timer = 0, 0, {}, 0
	a.lost, a.lost_reason = false, {}
}

net_lost :: proc(a: ^App) -> (reason: string, lost: bool) {
	if !a.lost {
		return "", false
	}
	#partial switch a.lost_reason {
	case .Connect_Failed: return fmt.tprintf("Could not reach %s:%d", a.address, a.port), true
	case .Denied: return "The host refused the connection", true
	}
	return "Disconnected from host", true
}

net_update :: proc(a: ^App, dt: f32) {
	a.net_carry += dt * 1000
	ms := int(a.net_carry)
	a.net_carry -= f32(ms)
	if ms > 0 {
		nr.update(&a.runtime, ms)
	}
}

on_tick :: proc(s: ^session.Session) {
	a := cast(^App)s.userdata
	if a.server_ready do server_tick(a)
}

on_connected :: proc(s: ^session.Session, conn: transport.Connection_Id) {
	a := cast(^App)s.userdata
	if a.server_ready do server_add_player(a, conn)
}

on_disconnected :: proc(s: ^session.Session, conn: transport.Connection_Id) {
	a := cast(^App)s.userdata
	if a.server_ready do server_remove_player(a, conn)
}

on_server_lost :: proc(s: ^session.Session, reason: session.Server_Disconnect_Reason) {
	a := cast(^App)s.userdata
	if reason != .Local {
		a.lost, a.lost_reason = true, reason
	}
}

local_player :: proc(a: ^App) -> (objects.Network_Id, ^Player) {
	if !a.client_ready do return 0, nil
	if obj, ok := objects.find_owned(&a.client_reg, a.session.client_server_id); ok {
		return obj.id, objects.component_data(obj, Player, PLAYER_TYPE)
	}
	return 0, nil
}

// 鼠标转视角、键盘移动；跳跃用计数，固定 tick 时由 sample_input 取走。
read_input :: proc(a: ^App, app: ^foster.App, dt: f32) {
	keys := &app.Input.State.Keyboard
	mouse := &app.Input.State.Mouse
	SENSITIVITY :: f32(0.0022)
	if !a.shot {
		// 截图模式由 autopilot 控制视角，不读鼠标，避免多个窗口弹出时的位移干扰。
		a.yaw -= mouse.Delta.X * SENSITIVITY
		a.pitch = clamp(a.pitch - mouse.Delta.Y * SENSITIVITY, -1.5, 1.5)
	}
	bits: Move_Bits
	if foster.KeyboardDown(keys, .W) || foster.KeyboardDown(keys, .Up) do bits += {.Forward}
	if foster.KeyboardDown(keys, .S) || foster.KeyboardDown(keys, .Down) do bits += {.Back}
	if foster.KeyboardDown(keys, .A) || foster.KeyboardDown(keys, .Left) do bits += {.Left}
	if foster.KeyboardDown(keys, .D) || foster.KeyboardDown(keys, .Right) do bits += {.Right}
	if foster.KeyboardPressed(keys, .Space) do a.jump_seq += 1
	a.move_bits = bits
	a.fire_timer = max(0, a.fire_timer - dt)
	a.want_fire = foster.MouseDown(mouse, .Left)
}

// 本地立即画曳光与枪口火光，再把这一枪交给服务器判定；服务器广播回来的同一枪不再重复画。
try_fire :: proc(a: ^App) {
	id, p := local_player(a)
	if id == 0 || p == nil || p.respawn > 0 || !a.want_fire || a.fire_timer > 0 do return
	a.fire_timer = FIRE_INTERVAL
	origin := eye_of(p.pos)
	dir := look_dir(a.yaw, a.pitch)
	end := ray_level(origin, dir, FIRE_RANGE)
	fx_shot(&a.view, origin, origin + dir * end, true)
	rpc.send_with(&a.runtime.client.rpc, RPC_FIRE, id, .Server, write_fire, a)
}

on_shot :: proc(ctx: ^rpc.Context, payload: []u8) {
	if ctx.manager.authority do return
	a := cast(^App)ctx.manager.userdata
	m, ok := read_shot(payload)
	if !ok do return
	my_id, me := local_player(a)
	if ctx.object != nil && ctx.object.id == my_id {
		if m.part != .None do a.view.hitmarker, a.view.hit_head = 1, m.part == .Head
		return
	}
	fx_shot(&a.view, m.from, m.to, false)
	if me != nil && m.victim_slot == me.slot do a.view.damage_flash = 1
}

on_kill :: proc(ctx: ^rpc.Context, payload: []u8) {
	if ctx.manager.authority do return
	a := cast(^App)ctx.manager.userdata
	m, ok := read_kill(payload)
	if !ok do return
	feed_push(&a.view, m)
}
