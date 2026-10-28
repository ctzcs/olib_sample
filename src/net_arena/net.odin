package main

import "core:fmt"

import foster "olib:foster"
import "olib:thirdparty/onet/objects"
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
	if a.use_udp {
		// 可选的原生 UDP 后端；Session 借用它，最后销毁。
		if !udp.init(&a.udp, udp.default_config()) || !session.set_driver(s, udp.driver(&a.udp)) {
			return false
		}
		a.udp_ready = true
	}
	if a.lag_ms > 0 {
		// 后端无关的出站延迟/抖动，用来验证预测；两端都设置才是对称往返延迟。
		session.set_network_conditions(s, {seed = 1, latency_ms = a.lag_ms, jitter_ms = a.lag_ms / 5})
	}
	cfg: nr.Config
	if a.mode != .Client {
		objects.registry_init(&a.server_reg)
		register_factories(&a.server_reg)
		a.server_reg.reclaim_despawned = true // 金币持续生成/拾取，确认后回收条目
		cfg.server_registry = &a.server_reg
		a.server_ready = true
	}
	if a.mode != .Server {
		objects.registry_init(&a.client_reg, false)
		register_factories(&a.client_reg)
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
	// 每个 Runtime World 绑定自己的 Simulation_World；Player 组件出现时自动注册为系统。
	if a.server_ready {
		if !bind_world(&a.runtime.server, &a.server_sim, true, a) do return false
		a.server_sim_ready = true
		server_start_match(a)
	}
	if a.client_ready {
		if !bind_world(&a.runtime.client, &a.client_sim, false, a) do return false
		a.client_sim_ready = true
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
	a.session_ready, a.server_ready, a.client_ready, a.runtime_ready = false, false, false, false
	a.server_sim_ready, a.client_sim_ready, a.udp_ready = false, false, false
	a.match, a.coin_timer, a.net_carry = nil, 0, 0
	a.dash_seq, a.input_bits = 0, {}
	a.lost, a.lost_reason = false, {}
}

// 连接失败或断开时返回原因，由调用方退回菜单；本地主动退出不算。
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
	if a.server_ready {
		server_tick(a)
	}
}

on_connected :: proc(s: ^session.Session, conn: transport.Connection_Id) {
	a := cast(^App)s.userdata
	if a.server_ready {
		server_add_player(a, conn)
	}
}

on_disconnected :: proc(s: ^session.Session, conn: transport.Connection_Id) {
	a := cast(^App)s.userdata
	if a.server_ready {
		server_remove_player(a, conn)
	}
}

on_server_lost :: proc(s: ^session.Session, reason: session.Server_Disconnect_Reason) {
	a := cast(^App)s.userdata
	if reason != .Local {
		a.lost, a.lost_reason = true, reason
	}
}

// owner 随快照复制：本连接拥有的角色就是本地玩家。
local_player :: proc(a: ^App) -> objects.Network_Id {
	if obj, ok := objects.find_owned(&a.client_reg, a.session.client_server_id); ok {
		return obj.id
	}
	return 0
}

// 每帧记录按键；Simulation_World 在固定 tick 通过 sample_input 取走并随输入帧上传。
// 冲刺用计数而不是“本帧按下”，两个 tick 之间按下也不会丢。
read_input :: proc(a: ^App, keys: ^foster.KeyboardState) {
	bits: Input_Bits
	if foster.KeyboardDown(keys, .W) || foster.KeyboardDown(keys, .Up) do bits += {.Up}
	if foster.KeyboardDown(keys, .S) || foster.KeyboardDown(keys, .Down) do bits += {.Down}
	if foster.KeyboardDown(keys, .A) || foster.KeyboardDown(keys, .Left) do bits += {.Left}
	if foster.KeyboardDown(keys, .D) || foster.KeyboardDown(keys, .Right) do bits += {.Right}
	if foster.KeyboardPressed(keys, .Space) || foster.KeyboardPressed(keys, .LeftShift) {
		a.dash_seq += 1
	}
	a.input_bits = bits
}
