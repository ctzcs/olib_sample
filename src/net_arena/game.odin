package main

import "core:math"
import "core:math/linalg"
import "core:math/rand"

import "olib:thirdparty/onet/objects"
import "olib:thirdparty/onet/transport"

// ==============================================================================
// 复制 schema：服务器与客户端注册相同的工厂和成员次序
// ==============================================================================

ARENA :: [2]f32{1200, 680}
PLAYER_RADIUS :: f32(22)
COIN_RADIUS :: f32(11)
MAX_PLAYERS :: 8
TICK_MS :: 20
TICK_DT :: f32(TICK_MS) / 1000

ACCEL :: f32(2600)
FRICTION :: f32(5.5)
MAX_SPEED :: f32(380)
DASH_SPEED :: f32(980)
DASH_COOLDOWN :: f32(1.1)
HIT_GRACE :: f32(1.2)
COIN_TARGET :: 14
GEM_CHANCE :: f32(0.12)
ROUND_SECONDS :: f32(#config(NET_ARENA_ROUND, 60))
RESULT_SECONDS :: f32(5)

PLAYER_TYPE :: objects.Component_Type_Id(1)
COIN_TYPE :: objects.Component_Type_Id(2)
MATCH_TYPE :: objects.Component_Type_Id(3)

Input_Bit :: enum u8 { Up, Down, Left, Right }
Input_Bits :: bit_set[Input_Bit; u8]

Player :: struct {
	// 预测状态：只随 Simulation_World 快照同步，不再重复注册成对象成员。
	// dash/hit 是冲刺/受击的 0..1 余量，客户端用来做特效。
	pos, vel:  [2]f32,
	dash, hit: f32,
	cooldown:  f32,
	last_dash: u8,
	// 复制成员（不参与预测）
	slot:      i32,
	score:     i32,
	// 仅服务器
	want_dash: bool,
	bot:       bool,
	ai_dir:    [2]f32,
	ai_think:  f32,
}

// 机器人没有真实连接，用远离真实 ID 的占位 owner。
BOT_OWNER_BASE :: transport.Connection_Id(0x7fff_0000)

Coin :: struct {
	pos:   [2]f32,
	value: i32,
}

Phase :: enum i32 { Playing, Results }

Match :: struct {
	time_left: f32,
	phase:     i32,
	round:     i32,
	winner:    i32, // 胜者 slot，-1 为无
}

free_state :: proc(p: rawptr) { free(p) }

player_factory :: proc() -> ^objects.Component {
	p := new(Player)
	c := objects.component_make(PLAYER_TYPE)
	c.userdata, c.destroy_userdata = p, free_state
	objects.member_i32(c, &p.slot)
	objects.member_i32(c, &p.score)
	return c
}

coin_factory :: proc() -> ^objects.Component {
	coin := new(Coin)
	c := objects.component_make(COIN_TYPE)
	c.userdata, c.destroy_userdata = coin, free_state
	objects.member_vec2(c, &coin.pos)
	objects.member_i32(c, &coin.value)
	return c
}

match_factory :: proc() -> ^objects.Component {
	m := new(Match)
	c := objects.component_make(MATCH_TYPE)
	c.userdata, c.destroy_userdata = m, free_state
	objects.member_f32(c, &m.time_left)
	objects.member_i32(c, &m.phase)
	objects.member_i32(c, &m.round)
	objects.member_i32(c, &m.winner)
	return c
}

register_factories :: proc(reg: ^objects.Registry) {
	objects.register_factory(reg, PLAYER_TYPE, player_factory)
	objects.register_factory(reg, COIN_TYPE, coin_factory)
	objects.register_factory(reg, MATCH_TYPE, match_factory)
}

spawn_with :: proc(reg: ^objects.Registry, owner: transport.Connection_Id, factory: objects.Component_Factory) -> (^objects.Network_Object, rawptr) {
	obj := objects.spawn(reg, owner)
	if obj == nil {
		return nil, nil
	}
	c := factory()
	append(&obj.components, c)
	return obj, c.userdata
}

// ==============================================================================
// 服务器权威逻辑：连接进出、输入 RPC、固定 tick 模拟
// ==============================================================================

server_start_match :: proc(a: ^App) {
	_, data := spawn_with(&a.server_reg, objects.SERVER_OWNED, match_factory)
	a.match = cast(^Match)data
	a.match^ = {time_left = ROUND_SECONDS, phase = i32(Phase.Playing), round = 1, winner = -1}
}

server_add_player :: proc(a: ^App, conn: transport.Connection_Id, bot := false) {
	used: [MAX_PLAYERS]bool
	for _, obj in a.server_reg.objects {
		if p := objects.component_data(obj, Player, PLAYER_TYPE); p != nil {
			used[p.slot] = true
		}
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
	_, data := spawn_with(&a.server_reg, conn, player_factory)
	p := cast(^Player)data
	p.slot, p.bot = i32(slot), bot
	p.pos = random_spot(a)
	p.hit = 1 // 出生无敌闪烁
}

server_remove_player :: proc(a: ^App, conn: transport.Connection_Id) {
	if obj, ok := objects.find_owned(&a.server_reg, conn); ok {
		objects.despawn(&a.server_reg, obj.id)
	}
}

input_dir :: proc(bits: Input_Bits) -> [2]f32 {
	d: [2]f32
	if .Up in bits do d.y -= 1
	if .Down in bits do d.y += 1
	if .Left in bits do d.x -= 1
	if .Right in bits do d.x += 1
	return linalg.normalize0(d)
}

random_spot :: proc(a: ^App) -> [2]f32 {
	margin := f32(60)
	best: [2]f32
	best_gap := f32(-1)
	// 取若干候选里离玩家最远的点，避免金币或出生点贴脸。
	for _ in 0 ..< 6 {
		c := [2]f32{rand.float32_range(margin, ARENA.x - margin), rand.float32_range(margin, ARENA.y - margin)}
		gap := f32(1e9)
		for _, obj in a.server_reg.objects {
			if p := objects.component_data(obj, Player, PLAYER_TYPE); p != nil {
				gap = min(gap, linalg.length(p.pos - c))
			}
		}
		if gap > best_gap {
			best, best_gap = c, gap
		}
	}
	return best
}

spawn_coin :: proc(a: ^App, pos: [2]f32, value: i32) {
	_, data := spawn_with(&a.server_reg, objects.SERVER_OWNED, coin_factory)
	if data == nil {
		return
	}
	coin := cast(^Coin)data
	coin.pos = {clamp(pos.x, 30, ARENA.x - 30), clamp(pos.y, 30, ARENA.y - 30)}
	coin.value = value
}

server_tick :: proc(a: ^App) {
	m := a.match
	dt := TICK_DT
	players := make([dynamic]^Player, context.temp_allocator)
	coins := make([dynamic]objects.Network_Id, context.temp_allocator)
	for id, obj in a.server_reg.objects {
		if p := objects.component_data(obj, Player, PLAYER_TYPE); p != nil {
			append(&players, p)
		} else if objects.component_data(obj, Coin, COIN_TYPE) != nil {
			append(&coins, id)
		}
	}

	m.time_left = max(0, m.time_left - dt)
	playing := Phase(m.phase) == .Playing
	if m.time_left <= 0 {
		if playing {
			m.phase, m.time_left, m.winner = i32(Phase.Results), RESULT_SECONDS, -1
			best := i32(-1)
			for p in players {
				if p.score > best {
					best, m.winner = p.score, p.slot
				}
			}
		} else {
			m.phase, m.time_left = i32(Phase.Playing), ROUND_SECONDS
			m.round += 1
			for p in players {
				p.score, p.vel, p.hit = 0, {}, 1
				p.pos = random_spot(a)
			}
		}
	}

	// 移动在 Simulation_World 的 early 里推进（见 predict.odin）；这里只做机器人决策和规则。
	for p in players {
		if p.bot do bot_think(a, p, players[:], coins[:], dt)
	}

	// 玩家间弹性碰撞；冲刺中撞到未冲刺的人会撞掉对方最多 3 枚金币。
	for i in 0 ..< len(players) {
		for j in i + 1 ..< len(players) {
			pa, pb := players[i], players[j]
			delta := pb.pos - pa.pos
			dist := linalg.length(delta)
			if dist >= PLAYER_RADIUS * 2 || dist <= 0.0001 {
				continue
			}
			n := delta / dist
			push := (PLAYER_RADIUS * 2 - dist) * 0.5
			pa.pos -= n * push
			pb.pos += n * push
			vn := linalg.dot(pb.vel - pa.vel, n)
			if vn < 0 {
				impulse := -vn * 0.9
				pa.vel -= n * impulse
				pb.vel += n * impulse
			}
			if playing {
				if pa.dash > 0.5 && pb.dash <= 0.5 do knock(a, pb, n)
				if pb.dash > 0.5 && pa.dash <= 0.5 do knock(a, pa, -n)
			}
		}
	}

	if playing {
		for id in coins {
			obj, _ := objects.get(&a.server_reg, id)
			coin := objects.component_data(obj, Coin, COIN_TYPE)
			if coin == nil do continue
			for p in players {
				if linalg.length(p.pos - coin.pos) < PLAYER_RADIUS + COIN_RADIUS {
					p.score += coin.value
					objects.despawn(&a.server_reg, id)
					break
				}
			}
		}
		a.coin_timer -= dt
		if len(coins) < COIN_TARGET && a.coin_timer <= 0 {
			a.coin_timer = 0.35
			spawn_coin(a, random_spot(a), rand.float32() < GEM_CHANCE ? 5 : 1)
		}
	}
}

knock :: proc(a: ^App, victim: ^Player, away: [2]f32) {
	if victim.hit > 0 {
		return
	}
	victim.hit = 1
	victim.vel += away * 520
	lost := min(victim.score, 3)
	victim.score -= lost
	for k in 0 ..< lost {
		angle := math.atan2(away.y, away.x) + (f32(k) - f32(lost - 1) * 0.5) * 0.9
		spawn_coin(a, victim.pos + [2]f32{math.cos(angle), math.sin(angle)} * 70, 1)
	}
}

// 简单机器人：追性价比最高的金币，身边有人且冲刺就绪时偶尔撞过去。
bot_think :: proc(a: ^App, p: ^Player, players: []^Player, coins: []objects.Network_Id, dt: f32) {
	p.ai_think -= dt
	if p.ai_think > 0 {
		return
	}
	p.ai_think = rand.float32_range(0.12, 0.3)
	target := ARENA * 0.5
	best := f32(1e9)
	for id in coins {
		obj, _ := objects.get(&a.server_reg, id)
		coin := objects.component_data(obj, Coin, COIN_TYPE)
		if coin == nil do continue
		cost := linalg.length(coin.pos - p.pos) / math.sqrt(f32(coin.value)) + rand.float32() * 60
		if cost < best {
			best, target = cost, coin.pos
		}
	}
	for other in players {
		if other == p || other.hit > 0 || other.score == 0 do continue
		gap := linalg.length(other.pos - p.pos)
		if gap < 170 && p.cooldown <= 0 && rand.float32() < 0.25 {
			target = other.pos
			p.want_dash = true
			break
		}
	}
	jitter := [2]f32{rand.float32_range(-0.25, 0.25), rand.float32_range(-0.25, 0.25)}
	p.ai_dir = linalg.normalize0(linalg.normalize0(target - p.pos) + jitter)
}
