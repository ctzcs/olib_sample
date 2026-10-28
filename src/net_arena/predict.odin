package main

import "core:math"
import "core:math/linalg"

import "olib:thirdparty/onet/objects"
import sim "olib:thirdparty/onet/simulation"

// ==============================================================================
// 角色移动的整世界预测：服务器推进所有角色，客户端只预测自己，
// 权威状态到达后由 onet 回滚到该 tick 并重放之后的本地输入。
// ==============================================================================

// 布局或规则变化时必须换 schema，否则两端会按旧布局解码。
PLAYER_SCHEMA :: u32(0x4e41_0002)
// pos.xy vel.xy dash cooldown hit (f32 ×7) + last_dash (u8)
PLAYER_STATE_SIZE :: 7 * 4 + 1
// [方向位, 冲刺计数]
PLAYER_INPUT_SIZE :: 2

// 输入缺失时两字节都沿用上一帧：方向保持，冲刺计数不变也就不会重复触发。
PLAYER_DEFAULTS := [PLAYER_INPUT_SIZE]u8{}
PLAYER_CARRY := [PLAYER_INPUT_SIZE]u8{1, 1}

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
			input_user = user, // 本地按键在 App 上，不必放进组件
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
	sim.state_put_vec2(dst, &at, p.pos)
	sim.state_put_vec2(dst, &at, p.vel)
	sim.state_put_f32(dst, &at, p.dash)
	sim.state_put_f32(dst, &at, p.cooldown)
	sim.state_put_f32(dst, &at, p.hit)
	sim.state_put_u8(dst, &at, p.last_dash)
}

player_restore :: proc(user: rawptr, state: []u8) {
	p := cast(^Player)user
	at := 0
	p.pos, _ = sim.state_get_vec2(state, &at)
	p.vel, _ = sim.state_get_vec2(state, &at)
	p.dash, _ = sim.state_get_f32(state, &at)
	p.cooldown, _ = sim.state_get_f32(state, &at)
	p.hit, _ = sim.state_get_f32(state, &at)
	p.last_dash, _ = sim.state_get_u8(state, &at)
}

player_validate_state :: proc(user: rawptr, state: []u8, tick: sim.Tick) -> bool {
	if len(state) != PLAYER_STATE_SIZE {
		return false
	}
	at := 0
	for _ in 0 ..< 7 {
		v, _ := sim.state_get_f32(state, &at)
		if math.is_nan(v) || math.is_inf(v) || abs(v) > 1e5 {
			return false
		}
	}
	return true
}

player_validate_input :: proc(user: rawptr, input: []u8, tick: sim.Tick) -> bool {
	return len(input) == PLAYER_INPUT_SIZE && input[0] <= 0x0f
}

// 只对本机拥有的系统调用；user 是 input_user（App），按键在每帧 update 里写进去。
player_sample_input :: proc(user: rawptr, dst: []u8, tick: sim.Tick) {
	a := cast(^App)user
	dst[0] = transmute(u8)a.input_bits
	dst[1] = a.dash_seq
}

player_early :: proc(user: rawptr, step: ^sim.World_Step) {
	p := cast(^Player)user
	sim.world_try_last_state(step)
	dir := input_dir(transmute(Input_Bits)(step.input[0] & 0x0f))
	want_dash := step.input[1] != p.last_dash
	p.last_dash = step.input[1]
	if p.bot {
		// 机器人只在服务器上由 bot_think 驱动，客户端不预测它们。
		dir, want_dash = p.ai_dir, p.want_dash
		p.want_dash = false
	}
	player_move(p, dir, want_dash, f32(step.dt))
}

// 两端共用的确定性移动规则。
player_move :: proc(p: ^Player, dir: [2]f32, want_dash: bool, dt: f32) {
	if want_dash && p.cooldown <= 0 {
		d := dir
		if d == {} do d = linalg.normalize0(p.vel)
		if d == {} do d = {1, 0}
		p.vel = d * DASH_SPEED
		p.dash, p.cooldown = 1, DASH_COOLDOWN
	}
	p.vel += dir * ACCEL * dt
	p.vel *= math.exp(-FRICTION * dt)
	speed := linalg.length(p.vel)
	if p.dash < 0.3 && speed > MAX_SPEED {
		p.vel *= MAX_SPEED / speed
	}
	p.pos += p.vel * dt
	arena := ARENA
	for axis in 0 ..< 2 {
		if p.pos[axis] < PLAYER_RADIUS {
			p.pos[axis], p.vel[axis] = PLAYER_RADIUS, abs(p.vel[axis]) * 0.6
		} else if p.pos[axis] > arena[axis] - PLAYER_RADIUS {
			p.pos[axis], p.vel[axis] = arena[axis] - PLAYER_RADIUS, -abs(p.vel[axis]) * 0.6
		}
	}
	p.dash = max(0, p.dash - dt * 2.4)
	p.hit = max(0, p.hit - dt / HIT_GRACE)
	p.cooldown = max(0, p.cooldown - dt)
}
