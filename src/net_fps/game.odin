package main

import "core:math"
import "core:math/linalg"
import "core:math/rand"

import "olib:thirdparty/onet/core"
import "olib:thirdparty/onet/objects"
import "olib:thirdparty/onet/rpc"
import "olib:thirdparty/onet/transport"

// ==============================================================================
// 服务器规则：进出、射击判定（含延迟补偿）、伤害与重生、机器人
// ==============================================================================

FIRE_INTERVAL :: f32(0.16)
BOT_FIRE_INTERVAL :: f32(0.4)
FIRE_RANGE :: f32(120)
BODY_DAMAGE :: 25
HEAD_DAMAGE :: 70
MAX_REWIND_TICKS :: 25 // 最多回退 0.5 s，防止客户端报很旧的 tick

RPC_FIRE :: rpc.Id(1) // 客户端 → 服务器：[yaw f32, pitch f32, 看到的权威 tick u64]
RPC_SHOT :: rpc.Id(2) // 服务器 → 所有人：曳光与命中
RPC_KILL :: rpc.Id(3) // 服务器 → 所有人：击杀播报

Shot_Msg :: struct {
	from, to:    [3]f32,
	part:        Hit_Part,
	victim_slot: i32, // -1 无
}

Kill_Msg :: struct {
	killer, victim: i32,
	head:           bool,
}

server_add_player :: proc(a: ^App, conn: transport.Connection_Id, bot := false) {
	used: [MAX_PLAYERS]bool
	for _, obj in a.server_reg.objects {
		if p := objects.component_data(obj, Player, PLAYER_TYPE); p != nil do used[p.slot] = true
	}
	slot := -1
	for taken, i in used {
		if !taken {
			slot = i
			break
		}
	}
	if slot < 0 {
		return // 满员：不生成角色，客户端停在连接界面
	}
	obj := objects.spawn(&a.server_reg, conn)
	c := player_factory()
	append(&obj.components, c)
	p := cast(^Player)c.userdata
	p.slot, p.bot, p.health = i32(slot), bot, MAX_HEALTH
	place_at_spawn(a, p)
}

server_remove_player :: proc(a: ^App, conn: transport.Connection_Id) {
	if obj, ok := objects.find_owned(&a.server_reg, conn); ok {
		objects.despawn(&a.server_reg, obj.id)
	}
}

// 选离其他活着的玩家最远的出生点，朝向场地中心。
place_at_spawn :: proc(a: ^App, p: ^Player) {
	best, best_gap := SPAWN_POINTS[0], f32(-1)
	for spawn in SPAWN_POINTS {
		gap := f32(1e9)
		for _, obj in a.server_reg.objects {
			o := objects.component_data(obj, Player, PLAYER_TYPE)
			if o == nil || o == p || o.respawn > 0 do continue
			gap = min(gap, linalg.length(o.pos - spawn))
		}
		gap += rand.float32() * 3
		if gap > best_gap do best, best_gap = spawn, gap
	}
	p.pos, p.vel = best, {}
	p.yaw = math.atan2(best.x, best.z) // 面向原点
	p.pitch = 0
}

players_of :: proc(reg: ^objects.Registry) -> [dynamic]^Player {
	list := make([dynamic]^Player, context.temp_allocator)
	for _, obj in reg.objects {
		if p := objects.component_data(obj, Player, PLAYER_TYPE); p != nil do append(&list, p)
	}
	return list
}

server_tick :: proc(a: ^App) {
	dt := TICK_DT
	tick := a.server_sim.tick
	for id, obj in a.server_reg.objects {
		p := objects.component_data(obj, Player, PLAYER_TYPE)
		if p == nil do continue
		// 上一步模拟后的位置，射击时按客户端看到的 tick 回退。
		p.history[tick % HISTORY] = {tick, p.pos}
		p.fire_cooldown = max(0, p.fire_cooldown - dt)
		if p.respawn > 0 {
			p.respawn -= dt
			if p.respawn <= 0 {
				p.respawn, p.health = 0, MAX_HEALTH
				place_at_spawn(a, p)
			}
		}
		if p.bot && p.respawn <= 0 do bot_think(a, id, p, dt)
	}
}

rewound :: proc(p: ^Player, tick: u64) -> [3]f32 {
	best := p.pos
	best_tick: u64
	for h in p.history {
		if h.tick <= tick && h.tick > best_tick {
			best, best_tick = h.pos, h.tick
		}
	}
	return best
}

on_fire :: proc(ctx: ^rpc.Context, payload: []u8) {
	if !ctx.manager.authority do return
	a := cast(^App)ctx.manager.userdata
	p := objects.component_data(ctx.object, Player, PLAYER_TYPE)
	if p == nil || p.respawn > 0 || p.fire_cooldown > FIRE_INTERVAL * 0.25 do return
	r := rpc.reader(payload)
	yaw := core.read_raw_single(&r, 0)
	pitch := core.read_raw_single(&r, 0)
	view_tick := core.read_uint64(&r, .Loose)
	if r.err != .None || math.is_nan(yaw) || math.is_nan(pitch) do return
	p.fire_cooldown = FIRE_INTERVAL
	server_fire(a, ctx.object.id, p, yaw, clamp(pitch, -1.55, 1.55), view_tick)
}

// 射线先打关卡，再按客户端看到的 tick 回退其他玩家做命中判定。
server_fire :: proc(a: ^App, shooter_id: objects.Network_Id, p: ^Player, yaw, pitch: f32, view_tick: u64) {
	now := a.server_sim.tick
	tick := clamp(view_tick, now - min(now, MAX_REWIND_TICKS), now)
	origin := eye_of(p.pos)
	dir := look_dir(yaw, pitch)
	end := ray_level(origin, dir, FIRE_RANGE)
	victim: ^Player
	part := Hit_Part.None
	for _, obj in a.server_reg.objects {
		o := objects.component_data(obj, Player, PLAYER_TYPE)
		if o == nil || o == p || o.respawn > 0 do continue
		t, hit := ray_player(origin, dir, rewound(o, tick))
		if hit != .None && t < end {
			end, victim, part = t, o, hit
		}
	}
	msg := Shot_Msg{from = origin, to = origin + dir * end, part = part, victim_slot = -1}
	if victim != nil {
		msg.victim_slot = victim.slot
		victim.health -= part == .Head ? HEAD_DAMAGE : BODY_DAMAGE
		if victim.health <= 0 {
			victim.health, victim.respawn = 0, RESPAWN_SECONDS
			victim.deaths += 1
			p.kills += 1
			kill := Kill_Msg{p.slot, victim.slot, part == .Head}
			rpc.send_with(&a.runtime.server.rpc, RPC_KILL, shooter_id, .Observers, write_kill, &kill)
		}
	}
	rpc.send_with(&a.runtime.server.rpc, RPC_SHOT, shooter_id, .Observers, write_shot, &msg)
}

write_fire :: proc(w: ^core.Writer, user: rawptr) {
	a := cast(^App)user
	core.write_raw_single(w, a.yaw)
	core.write_raw_single(w, a.pitch)
	core.write_uint64(w, a.client_sim.applied_tick, .Loose)
}

write_shot :: proc(w: ^core.Writer, user: rawptr) {
	m := cast(^Shot_Msg)user
	for v in m.from do core.write_raw_single(w, v)
	for v in m.to do core.write_raw_single(w, v)
	core.write_uint8(w, u8(m.part), .Uncompressed)
	core.write_int32(w, m.victim_slot, .Loose)
}

read_shot :: proc(payload: []u8) -> (m: Shot_Msg, ok: bool) {
	r := rpc.reader(payload)
	for i in 0 ..< 3 do m.from[i] = core.read_raw_single(&r, 0)
	for i in 0 ..< 3 do m.to[i] = core.read_raw_single(&r, 0)
	m.part = Hit_Part(core.read_uint8(&r, .Uncompressed))
	m.victim_slot = core.read_int32(&r, .Loose)
	return m, r.err == .None && m.part <= .Head
}

write_kill :: proc(w: ^core.Writer, user: rawptr) {
	m := cast(^Kill_Msg)user
	core.write_int32(w, m.killer, .Loose)
	core.write_int32(w, m.victim, .Loose)
	core.write_boolean(w, m.head)
}

read_kill :: proc(payload: []u8) -> (m: Kill_Msg, ok: bool) {
	r := rpc.reader(payload)
	m.killer = core.read_int32(&r, .Loose)
	m.victim = core.read_int32(&r, .Loose)
	m.head = core.read_boolean(&r)
	return m, r.err == .None
}

//@region 机器人
Bot_Brain :: struct {
	bits:          Move_Bits,
	yaw, pitch:    f32,
	jump:          bool,
	think, strafe: f32,
	strafe_left:   bool,
	waypoint:      [3]f32,
	reaction:      f32,
}

// 看得见敌人就转身、横移并在瞄准误差够小时开火；否则在出生点之间巡逻，卡住时跳一下。
bot_think :: proc(a: ^App, id: objects.Network_Id, p: ^Player, dt: f32) {
	b := &p.ai
	eye := eye_of(p.pos)
	target: ^Player
	best := f32(40)
	for _, obj in a.server_reg.objects {
		o := objects.component_data(obj, Player, PLAYER_TYPE)
		if o == nil || o == p || o.respawn > 0 do continue
		d := linalg.length(o.pos - p.pos)
		if d < best && line_of_sight(eye, eye_of(o.pos) - {0, 0.3, 0}) {
			best, target = d, o
		}
	}
	b.think -= dt
	b.strafe -= dt
	if b.strafe <= 0 {
		b.strafe, b.strafe_left = rand.float32_range(0.4, 1.2), rand.float32() < 0.5
	}
	aim_at := b.waypoint + {0, EYE_HEIGHT, 0}
	b.bits = {.Forward}
	if target != nil {
		aim_at = target.pos + {0, 1.2, 0}
		b.bits = best > 9 ? {.Forward} : {}
		b.bits += b.strafe_left ? {.Left} : {.Right}
		b.reaction -= dt
	} else {
		b.reaction = rand.float32_range(0.25, 0.5)
		if b.think <= 0 || linalg.length((b.waypoint - p.pos).xz) < 1.5 {
			b.think = rand.float32_range(3, 6)
			b.waypoint = SPAWN_POINTS[rand.int_max(len(SPAWN_POINTS))] * rand.float32_range(0.3, 0.9)
		}
		if p.grounded && linalg.length(p.vel.xz) < 1 do b.jump = true
	}
	d := aim_at - eye
	want_yaw := math.atan2(-d.x, -d.z)
	want_pitch := math.atan2(d.y, linalg.length(d.xz))
	turn := math.mod(want_yaw - b.yaw + 3 * math.PI, math.TAU) - math.PI
	step := 7 * dt
	b.yaw += clamp(turn, -step, step)
	b.pitch += clamp(want_pitch - b.pitch, -step, step)
	if target != nil && abs(turn) < 0.08 && b.reaction <= 0 && p.fire_cooldown <= 0 {
		p.fire_cooldown = BOT_FIRE_INTERVAL
		spread := f32(0.035)
		server_fire(a, id, p, b.yaw + rand.float32_range(-spread, spread), b.pitch + rand.float32_range(-spread, spread), a.server_sim.tick)
	}
}
//@endregion
