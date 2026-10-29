package main

import "core:math"
import "core:math/linalg"

import "olib:thirdparty/onet/objects"
import sim "olib:thirdparty/onet/simulation"
import "olib:thirdparty/onet/transport"

// ==============================================================================
// 玩家：生命/击杀等规则字段走对象成员；位置、速度、朝向走整世界预测
// ==============================================================================

MAX_PLAYERS :: 8
TICK_MS :: 20
TICK_DT :: f32(TICK_MS) / 1000

PLAYER_RADIUS :: f32(0.35)
PLAYER_HEIGHT :: f32(1.8)
EYE_HEIGHT :: f32(1.6)
MOVE_SPEED :: f32(7)
GROUND_ACCEL :: f32(60)
AIR_ACCEL :: f32(14)
JUMP_SPEED :: f32(7.2)
GRAVITY :: f32(20)
MAX_HEALTH :: 100
RESPAWN_SECONDS :: f32(2.5)

PLAYER_TYPE :: objects.Component_Type_Id(1)

Move_Bit :: enum u8 { Forward, Back, Left, Right }
Move_Bits :: bit_set[Move_Bit; u8]

// 机器人没有真实连接，用远离真实 ID 的占位 owner。
BOT_OWNER_BASE :: transport.Connection_Id(0x7fff_0000)

HISTORY :: 32 // 服务器保留的位置历史（tick），用于延迟补偿，约 0.64 s

Player :: struct {
	// 对象成员：服务器规则
	slot, health:  i32,
	kills, deaths: i32,
	respawn:       f32, // >0 表示阵亡，剩余秒数
	// 模拟状态：预测
	pos, vel:      [3]f32,
	yaw, pitch:    f32,
	grounded:      bool,
	last_jump:     u8,
	// 仅服务器
	bot:           bool,
	ai:            Bot_Brain,
	fire_cooldown: f32,
	history:       [HISTORY]Snapshot_Pos,
}

Snapshot_Pos :: struct {
	tick: u64,
	pos:  [3]f32,
}

player_factory :: proc() -> ^objects.Component {
	p := new(Player)
	c := objects.component_make(PLAYER_TYPE)
	c.userdata, c.destroy_userdata = p, proc(p: rawptr) { free(p) }
	objects.member_i32(c, &p.slot)
	objects.member_i32(c, &p.health)
	objects.member_i32(c, &p.kills)
	objects.member_i32(c, &p.deaths)
	objects.member_f32(c, &p.respawn)
	return c
}

look_dir :: proc(yaw, pitch: f32) -> [3]f32 {
	cp := math.cos(pitch)
	return {-math.sin(yaw) * cp, math.sin(pitch), -math.cos(yaw) * cp}
}

eye_of :: proc(pos: [3]f32) -> [3]f32 {
	return pos + {0, EYE_HEIGHT, 0}
}

//@region 预测系统
// 布局或规则变化时必须换 schema。
PLAYER_SCHEMA :: u32(0x4650_0001)
// pos.xyz vel.xyz yaw pitch (f32 ×8) + grounded, last_jump (u8 ×2)
PLAYER_STATE_SIZE :: 8 * 4 + 2
// [移动位, 跳跃计数, yaw u16, pitch i16]
PLAYER_INPUT_SIZE :: 6

PLAYER_DEFAULTS := [PLAYER_INPUT_SIZE]u8{}
// 输入缺失时全部沿用上一帧：继续同方向移动、保持朝向，跳跃计数不变不会重复起跳。
PLAYER_CARRY := [PLAYER_INPUT_SIZE]u8{1, 1, 1, 1, 1, 1}

build_player_system :: proc(user: rawptr, obj: ^objects.Network_Object) -> (sim.System_Config, bool) {
	p := objects.component_data(obj, Player, PLAYER_TYPE)
	if p == nil {
		return {}, false
	}
	return sim.System_Config{
		schema = PLAYER_SCHEMA,
		state_size = PLAYER_STATE_SIZE,
		input_size = PLAYER_INPUT_SIZE,
		defaults = PLAYER_DEFAULTS[:],
		carry_mask = PLAYER_CARRY[:],
		callbacks = {
			user = p,
			input_user = user,
			capture = player_capture,
			restore = player_restore,
			validate_state = player_validate_state,
			validate_input = player_validate_input,
			sample_input = player_sample_input,
			early = player_early,
		},
	}, true
}

player_capture :: proc(user: rawptr, dst: []u8) {
	p := cast(^Player)user
	at := 0
	for v in p.pos do sim.state_put_f32(dst, &at, v)
	for v in p.vel do sim.state_put_f32(dst, &at, v)
	sim.state_put_f32(dst, &at, p.yaw)
	sim.state_put_f32(dst, &at, p.pitch)
	sim.state_put_u8(dst, &at, u8(p.grounded))
	sim.state_put_u8(dst, &at, p.last_jump)
}

player_restore :: proc(user: rawptr, state: []u8) {
	p := cast(^Player)user
	at := 0
	for i in 0 ..< 3 do p.pos[i], _ = sim.state_get_f32(state, &at)
	for i in 0 ..< 3 do p.vel[i], _ = sim.state_get_f32(state, &at)
	p.yaw, _ = sim.state_get_f32(state, &at)
	p.pitch, _ = sim.state_get_f32(state, &at)
	grounded, _ := sim.state_get_u8(state, &at)
	p.grounded = grounded != 0
	p.last_jump, _ = sim.state_get_u8(state, &at)
}

player_validate_state :: proc(user: rawptr, state: []u8, tick: sim.Tick) -> bool {
	if len(state) != PLAYER_STATE_SIZE {
		return false
	}
	at := 0
	for _ in 0 ..< 8 {
		v, _ := sim.state_get_f32(state, &at)
		if math.is_nan(v) || math.is_inf(v) || abs(v) > 1e4 {
			return false
		}
	}
	return state[32] <= 1
}

player_validate_input :: proc(user: rawptr, input: []u8, tick: sim.Tick) -> bool {
	return len(input) == PLAYER_INPUT_SIZE && input[0] <= 0x0f
}

// 只对本机拥有的系统调用；user 是 input_user（App）。
player_sample_input :: proc(user: rawptr, dst: []u8, tick: sim.Tick) {
	a := cast(^App)user
	encode_input(dst, a.move_bits, a.jump_seq, a.yaw, a.pitch)
}

encode_input :: proc(dst: []u8, bits: Move_Bits, jump: u8, yaw, pitch: f32) {
	turn := math.mod(yaw, math.TAU)
	if turn < 0 do turn += math.TAU
	y := u16(turn / math.TAU * 65535)
	pt := i16(clamp(pitch / (math.PI / 2), -1, 1) * 32767)
	dst[0], dst[1] = transmute(u8)bits, jump
	dst[2], dst[3] = u8(y), u8(y >> 8)
	dst[4], dst[5] = u8(u16(pt)), u8(u16(pt) >> 8)
}

decode_input :: proc(src: []u8) -> (bits: Move_Bits, jump: u8, yaw, pitch: f32) {
	bits, jump = transmute(Move_Bits)(src[0] & 0x0f), src[1]
	yaw = f32(u16(src[2]) | u16(src[3]) << 8) / 65535 * math.TAU
	pitch = f32(i16(u16(src[4]) | u16(src[5]) << 8)) / 32767 * (math.PI / 2)
	return
}

player_early :: proc(user: rawptr, step: ^sim.World_Step) {
	p := cast(^Player)user
	sim.world_try_last_state(step)
	bits, jump, yaw, pitch := decode_input(step.input)
	want_jump := jump != p.last_jump
	p.last_jump = jump
	if p.bot {
		// 机器人只在服务器上由 bot_think 驱动，客户端不预测它们。
		bits, yaw, pitch, want_jump = p.ai.bits, p.ai.yaw, p.ai.pitch, p.ai.jump
		p.ai.jump = false
	}
	p.yaw, p.pitch = yaw, pitch
	if p.respawn > 0 {
		p.vel = {}
		return
	}
	player_move(p, bits, want_jump, f32(step.dt))
}

// 两端共用的确定性移动：地面/空中加速度不同，按 x、z、y 轴依次移动并推出盒子。
player_move :: proc(p: ^Player, bits: Move_Bits, want_jump: bool, dt: f32) {
	f, r: f32
	if .Forward in bits do f += 1
	if .Back in bits do f -= 1
	if .Right in bits do r += 1
	if .Left in bits do r -= 1
	forward := [3]f32{-math.sin(p.yaw), 0, -math.cos(p.yaw)}
	right := [3]f32{math.cos(p.yaw), 0, -math.sin(p.yaw)}
	wish := linalg.normalize0(forward * f + right * r) * MOVE_SPEED
	delta := [2]f32{wish.x - p.vel.x, wish.z - p.vel.z}
	limit := (p.grounded ? GROUND_ACCEL : AIR_ACCEL) * dt
	if l := linalg.length(delta); l > limit do delta *= limit / l
	p.vel.x += delta.x
	p.vel.z += delta.y
	if want_jump && p.grounded {
		p.vel.y = JUMP_SPEED
	}
	p.vel.y = max(p.vel.y - GRAVITY * dt, -30)

	if move_axis(&p.pos, p.vel.x * dt, 0) do p.vel.x = 0
	if move_axis(&p.pos, p.vel.z * dt, 2) do p.vel.z = 0
	p.grounded = false
	if move_axis(&p.pos, p.vel.y * dt, 1) {
		p.grounded = p.vel.y < 0
		p.vel.y = 0
	}
}
//@endregion
