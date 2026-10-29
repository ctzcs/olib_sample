package main

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:math/rand"
import "core:os"
import "core:slice"

import foster "olib:foster"
import r2d "olib:kit/rendering/2d"
import mat "olib:kit/rendering/material"
import "olib:thirdparty/onet/objects"
import nr "olib:thirdparty/onet/runtime"

// ==============================================================================
// 表现层：只读复制下来的状态，平滑、拖尾、粒子都只存在于本地
// ==============================================================================

TRAIL :: 14

Visual :: struct {
	pos:        [2]f32,
	facing:     f32,
	score:      i32,
	trail:      [TRAIL][2]f32,
	trail_head: int,
	trail_len:  int,
	trail_t:    f32,
	seen:       bool,
}

Coin_Visual :: struct {
	pos:   [2]f32,
	value: i32,
	age:   f32,
	seen:  bool,
}

Particle :: struct {
	pos, vel:              [2]f32,
	life, max_life, size: f32,
	color:                 foster.Color,
}

Popup :: struct {
	pos:   [2]f32,
	value: i32,
	life:  f32,
}

View :: struct {
	materials:   mat.Material_Library, // Render2D 借用；默认精灵材质够用，不登记自定义 Shader
	ui:          r2d.Render2D,
	font_source: foster.Font,
	font:        foster.SpriteFont,
	font_big:    foster.SpriteFont,
	has_font:    bool,
	players:     map[objects.Network_Id]Visual,
	coins:       map[objects.Network_Id]Coin_Visual,
	particles:   [dynamic]Particle,
	popups:      [dynamic]Popup,
	time, shake: f32,
	origin:      [2]f32, // 竞技场逻辑坐标 → 屏幕：origin + p * scale
	scale:       f32,
}

BG :: foster.Color{12, 14, 24, 255}
BG_GLOW :: foster.Color{26, 30, 54, 255}
FLOOR :: foster.Color{20, 24, 40, 255}
GRID :: foster.Color{32, 38, 62, 255}
NEON :: foster.Color{94, 234, 212, 255}
WHITE :: foster.Color{255, 255, 255, 255}
INK :: foster.Color{0, 0, 0, 255}
DIM :: foster.Color{140, 150, 180, 255}
GOLD :: foster.Color{255, 209, 102, 255}
GOLD_DARK :: foster.Color{214, 140, 38, 255}
GEM :: foster.Color{232, 121, 249, 255}
GEM_DARK :: foster.Color{147, 51, 234, 255}
DANGER :: foster.Color{255, 99, 99, 255}
CLEAR :: foster.Color{}

SLOT_COLORS := [MAX_PLAYERS]foster.Color {
	{255, 107, 107, 255},
	{77, 171, 247, 255},
	{105, 219, 124, 255},
	{252, 196, 25, 255},
	{151, 117, 250, 255},
	{240, 101, 149, 255},
	{56, 217, 169, 255},
	{255, 146, 43, 255},
}

// 默认材质为预乘混合，透明色要把 RGB 一起乘上 alpha。
fade :: proc(c: foster.Color, alpha: f32) -> foster.Color {
	t := clamp(alpha, 0, 1)
	return {u8(f32(c.R) * t), u8(f32(c.G) * t), u8(f32(c.B) * t), u8(f32(c.A) * t)}
}

mix :: proc(a, b: foster.Color, t: f32) -> foster.Color {
	l :: proc(x, y: u8, t: f32) -> u8 { return u8(f32(x) + (f32(y) - f32(x)) * t) }
	return {l(a.R, b.R, t), l(a.G, b.G, t), l(a.B, b.B, t), l(a.A, b.A, t)}
}

slot_color :: proc(slot: i32) -> foster.Color {
	return SLOT_COLORS[int(slot) % MAX_PLAYERS]
}

view_init :: proc(v: ^View, app: ^foster.App) {
	v.materials = {device = &app.GraphicsDevice}
	if reason := r2d.init(&v.ui, &v.materials); reason != "" {
		fmt.eprintln("net_arena:", reason)
	}
	for path in ([]string{"C:/Windows/Fonts/segoeuib.ttf", "C:/Windows/Fonts/segoeui.ttf",
		"/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", "/System/Library/Fonts/Supplemental/Arial Bold.ttf"}) {
		if !os.exists(path) do continue
		v.font_source = foster.FontLoadFile(path)
		v.font = foster.SpriteFontMakeGPU(&app.GraphicsDevice, &v.font_source, 22)
		v.font_big = foster.SpriteFontMakeGPU(&app.GraphicsDevice, &v.font_source, 72)
		v.has_font = len(v.font.Characters) > 0
		break
	}
}

view_destroy :: proc(v: ^View) {
	if v.has_font {
		foster.SpriteFontDispose(&v.font_big)
		foster.SpriteFontDispose(&v.font)
		foster.FontDispose(&v.font_source)
	}
	r2d.dispose(&v.ui)
	mat.material_library_dispose(&v.materials)
	delete(v.players)
	delete(v.coins)
	delete(v.particles)
	delete(v.popups)
}

// 离开一局时清掉本地表现，下次进入从空白开始。
view_reset :: proc(v: ^View) {
	clear(&v.players)
	clear(&v.coins)
	clear(&v.particles)
	clear(&v.popups)
	v.shake = 0
}

view_registry :: proc(a: ^App) -> ^objects.Registry {
	return a.client_ready ? &a.client_reg : &a.server_reg
}

find_match :: proc(reg: ^objects.Registry) -> ^Match {
	for _, obj in reg.objects {
		if m := objects.component_data(obj, Match, MATCH_TYPE); m != nil {
			return m
		}
	}
	return nil
}

burst :: proc(v: ^View, pos: [2]f32, color: foster.Color, count: int, speed: f32) {
	for _ in 0 ..< count {
		angle := rand.float32() * math.TAU
		s := speed * rand.float32_range(0.35, 1)
		life := rand.float32_range(0.35, 0.8)
		append(&v.particles, Particle{
			pos = pos, vel = {math.cos(angle), math.sin(angle)} * s,
			life = life, max_life = life, size = rand.float32_range(2, 4.5), color = color,
		})
	}
}

// ==============================================================================
// 每帧：把复制状态同步到本地表现，并根据变化生成特效
// ==============================================================================

view_update :: proc(a: ^App, dt: f32) {
	v := &a.view
	v.shake = max(0, v.shake - dt * 3)
	reg := view_registry(a)
	local_id := local_player(a)
	// 远端角色按复制状态平滑；本地角色由预测逐 tick 推进，只留很轻的平滑吸收校正跳变。
	follow := 1 - math.exp(-18 * dt)
	follow_local := 1 - math.exp(-45 * dt)

	for _, &pv in v.players do pv.seen = false
	for _, &cv in v.coins do cv.seen = false
	for id, obj in reg.objects {
		if p := objects.component_data(obj, Player, PLAYER_TYPE); p != nil {
			if id not_in v.players {
				v.players[id] = Visual{pos = p.pos, score = p.score}
				burst(v, p.pos, slot_color(p.slot), 24, 260)
			}
			pv := &v.players[id]
			pv.seen = true
			pv.pos = linalg.lerp(pv.pos, p.pos, id == local_id ? follow_local : follow)
			if linalg.length(p.vel) > 25 {
				pv.facing = math.atan2(p.vel.y, p.vel.x)
			}
			if p.score != pv.score {
				delta := p.score - pv.score
				append(&v.popups, Popup{pos = pv.pos - {0, PLAYER_RADIUS + 10}, value = delta, life = 1})
				if delta < 0 {
					burst(v, pv.pos, DANGER, 18, 320)
					if id == local_id do v.shake = 1
				}
				pv.score = p.score
			}
			pv.trail_t -= dt
			if pv.trail_t <= 0 {
				pv.trail_t = 1.0 / 60
				pv.trail[pv.trail_head] = pv.pos
				pv.trail_head = (pv.trail_head + 1) % TRAIL
				pv.trail_len = min(pv.trail_len + 1, TRAIL)
			}
		} else if c := objects.component_data(obj, Coin, COIN_TYPE); c != nil {
			if id not_in v.coins {
				v.coins[id] = Coin_Visual{pos = c.pos, value = c.value}
			}
			cv := &v.coins[id]
			cv.seen, cv.pos, cv.value = true, c.pos, c.value
			cv.age += dt
		}
	}

	gone := make([dynamic]objects.Network_Id, context.temp_allocator)
	for id, cv in v.coins {
		if cv.seen do continue
		append(&gone, id)
		burst(v, cv.pos, cv.value > 1 ? GEM : GOLD, cv.value > 1 ? 26 : 14, 220)
	}
	for id in gone do delete_key(&v.coins, id)
	clear(&gone)
	for id, pv in v.players {
		if pv.seen do continue
		append(&gone, id)
		burst(v, pv.pos, WHITE, 30, 300)
	}
	for id in gone do delete_key(&v.players, id)

	for i := len(v.particles) - 1; i >= 0; i -= 1 {
		p := &v.particles[i]
		p.life -= dt
		if p.life <= 0 {
			unordered_remove(&v.particles, i)
			continue
		}
		p.pos += p.vel * dt
		p.vel *= math.exp(-4 * dt)
	}
	for i := len(v.popups) - 1; i >= 0; i -= 1 {
		p := &v.popups[i]
		p.life -= dt * 0.9
		p.pos.y -= 46 * dt
		if p.life <= 0 do ordered_remove(&v.popups, i)
	}
}

// ==============================================================================
// 绘制：竞技场在逻辑坐标中按窗口缩放，HUD 在屏幕坐标中绘制
// ==============================================================================

view_render :: proc(a: ^App, app: ^foster.App, target: foster.DrawableTarget) {
	v := &a.view
	b := &v.ui
	w, h := f32(target.WidthInPixels), f32(target.HeightInPixels)
	foster.GraphicsDeviceClear(&app.GraphicsDevice, target, BG)

	ui := clamp(min(w / 1280, h / 800), 0.6, 3)
	top, bottom, pad := 92 * ui, 46 * ui, 28 * ui
	scale := min((w - pad * 2) / ARENA.x, (h - top - bottom) / ARENA.y)
	origin := [2]f32{(w - ARENA.x * scale) / 2, top + (h - top - bottom - ARENA.y * scale) / 2}
	if v.shake > 0 {
		origin += [2]f32{math.sin(v.time * 93), math.cos(v.time * 71)} * v.shake * v.shake * 7 * ui
	}
	r2d.circle_gradient(b, foster.Vec2{w / 2, h * 0.45}, max(w, h) * 0.75, 64, BG_GLOW, BG)
	v.origin, v.scale = origin, scale

	reg := view_registry(a)
	local_id := local_player(a)
	match := find_match(reg)

	r2d.push_matrix_trs(b, origin, foster.Vec2{scale, scale}, 0)
	draw_arena(v, match)
	draw_coins(v)
	for &p in v.particles {
		t := p.life / p.max_life
		r2d.circle(b, p.pos, p.size * (0.4 + 0.6 * t), 8, fade(p.color, t))
	}
	draw_players(v, reg, local_id)
	r2d.pop_matrix(b)

	// 世界空间文字换算到屏幕坐标、按最终像素字号绘制，避免小字号栅格被缩放。
	draw_labels(v, reg, local_id)
	for p in v.popups {
		label := fmt.tprintf("%+d", p.value)
		color := p.value > 0 ? (p.value > 1 ? GEM : GOLD) : DANGER
		at := to_screen(v, p.pos)
		size := 24 * v.scale * (1 + 0.3 * max(0, p.life - 0.7) / 0.3)
		text(v, label, at + {1, 2}, size, fade(INK, p.life * 0.6), 0.5)
		text(v, label, at, size, fade(color, p.life), 0.5)
	}

	draw_hud(a, v, match, local_id, w, h, ui, origin, scale)
	if err := r2d.submit(b, {target = target, time = v.time}); err != .None {
		fmt.eprintln("net_arena:", mat.draw_error_text(err))
	}
}

to_screen :: proc(v: ^View, p: [2]f32) -> [2]f32 {
	return v.origin + p * v.scale
}

// 直接合成“竞技场 × 局部 TRS”并以绝对矩阵压栈；菜单背景把 origin/scale 设为屏幕空间复用它。
push_local :: proc(v: ^View, pos, scale: [2]f32, rotation: f32) {
	c, s, k := math.cos(rotation), math.sin(rotation), v.scale
	at := to_screen(v, pos)
	m := [16]f32{
		k * c * scale.x, k * s * scale.x, 0, 0,
		-k * s * scale.y, k * c * scale.y, 0, 0,
		0, 0, 1, 0,
		at.x, at.y, 0, 1,
	}
	r2d.push_matrix_raw(&v.ui, m, false)
}

text :: proc(v: ^View, s: string, pos: [2]f32, size: f32, color: foster.Color, align: f32 = 0) {
	if !v.has_font do return
	font := size > 34 ? &v.font_big : &v.font
	x := pos.x - foster.SpriteFontWidthOf(font, s, size) * align
	r2d.text(&v.ui, font, s, foster.Vec2{x, pos.y}, color, size)
}

text_width :: proc(v: ^View, s: string, size: f32) -> f32 {
	if !v.has_font do return 0
	return foster.SpriteFontWidthOf(size > 34 ? &v.font_big : &v.font, s, size)
}

draw_arena :: proc(v: ^View, match: ^Match) {
	b := &v.ui
	r := foster.Rect{0, 0, ARENA.x, ARENA.y}
	edge := NEON
	if match != nil && Phase(match.phase) == .Playing && match.time_left < 10 {
		edge = mix(NEON, DANGER, 0.5 + 0.5 * math.sin(v.time * 8))
	}
	for i in 0 ..< 5 {
		g := f32(5 - i) * 7
		round_rect(b, foster.Rect{-g, -g, ARENA.x + g * 2, ARENA.y + g * 2}, 22 + g, fade(edge, 0.035))
	}
	round_rect(b, r, 22, FLOOR)
	for x := f32(40); x < ARENA.x; x += 40 {
		r2d.line(b, foster.Vec2{x, 6}, foster.Vec2{x, ARENA.y - 6}, 1, GRID)
	}
	for y := f32(40); y < ARENA.y; y += 40 {
		r2d.line(b, foster.Vec2{6, y}, foster.Vec2{ARENA.x - 6, y}, 1, GRID)
	}
	center := ARENA * 0.5
	r2d.circle_line(b, center, 110, 3, 72, fade(edge, 0.18))
	r2d.circle(b, center, 10, 24, fade(edge, 0.25))
	r2d.line(b, foster.Vec2{center.x, 0}, foster.Vec2{center.x, ARENA.y}, 3, fade(edge, 0.12))
	round_rect_line(b, r, 22, 4, edge)
}

draw_coins :: proc(v: ^View) {
	b := &v.ui
	for _, cv in v.coins {
		gem := cv.value > 1
		t := min(cv.age * 3.5, 1)
		pop := 1 + 2.2 * math.pow(t - 1, 3) + 1.2 * math.pow(t - 1, 2) // ease-out-back
		radius := (gem ? COIN_RADIUS * 1.35 : COIN_RADIUS) * pop
		phase := cv.pos.x * 0.031 + cv.pos.y * 0.017
		p := cv.pos + {0, math.sin(v.time * 3 + phase) * 3}
		light, dark := gem ? GEM : GOLD, gem ? GEM_DARK : GOLD_DARK

		r2d.circle(b, cv.pos + {0, radius + 6}, radius * 0.7, 16, fade(INK, 0.3))
		r2d.circle_gradient(b, p, radius * (gem ? 3.2 : 2.4), 24, fade(light, gem ? 0.35 : 0.25), CLEAR)
		spin := 0.3 + 0.7 * abs(math.cos(v.time * 2.4 + phase))
		push_local(v, p, {spin, 1}, 0)
		if gem {
			s := radius * 1.25
			r2d.triangle(b, foster.Vec2{0, -s}, foster.Vec2{s, 0}, foster.Vec2{-s, 0}, light)
			r2d.triangle(b, foster.Vec2{-s, 0}, foster.Vec2{s, 0}, foster.Vec2{0, s}, dark)
			r2d.triangle(b, foster.Vec2{0, -s}, foster.Vec2{s * 0.35, -s * 0.2}, foster.Vec2{-s * 0.35, -s * 0.2}, fade(WHITE, 0.7))
		} else {
			r2d.circle(b, foster.Vec2{}, radius, 24, dark)
			r2d.circle(b, foster.Vec2{}, radius * 0.78, 24, light)
			r2d.circle(b, foster.Vec2{-radius * 0.25, -radius * 0.3}, radius * 0.25, 12, fade(WHITE, 0.75))
		}
		r2d.pop_matrix(b)
	}
}

draw_players :: proc(v: ^View, reg: ^objects.Registry, local_id: objects.Network_Id) {
	b := &v.ui
	R := PLAYER_RADIUS
	for id, pv in v.players {
		obj, ok := objects.get(reg, id)
		if !ok do continue
		p := objects.component_data(obj, Player, PLAYER_TYPE)
		if p == nil do continue
		col := slot_color(p.slot)
		pos := pv.pos

		for k in 0 ..< pv.trail_len {
			idx := (pv.trail_head - 1 - k + TRAIL * 2) % TRAIL
			t := 1 - f32(k) / f32(TRAIL)
			r2d.circle(b, pv.trail[idx], R * (0.35 + 0.55 * t), 20, fade(col, t * (0.06 + 0.3 * p.dash)))
		}
		r2d.circle(b, pos + {0, R * 0.55}, R * 0.95, 24, fade(INK, 0.35))
		if p.dash > 0 {
			r2d.circle_gradient(b, pos, R * 3, 32, fade(col, 0.55 * p.dash), CLEAR)
		}
		if id == local_id {
			ring := R + 9 + math.sin(v.time * 5) * 2
			r2d.circle_line(b, pos, ring, 2.5, 48, fade(WHITE, 0.55))
		}

		// 沿速度方向拉伸，角色“看向”移动方向。
		stretch := clamp(linalg.length(p.vel) / 1800, 0, 0.25)
		push_local(v, pos, {1 + stretch, 1 - stretch * 0.8}, pv.facing)
		draw_blob_body(b, col)
		if p.hit > 0 && math.sin(v.time * 38) > 0 {
			r2d.circle(b, foster.Vec2{}, R + 1, 40, fade(WHITE, 0.65 * p.hit))
		}
		r2d.pop_matrix(b)
	}
}

// 角色本体：在已压好的局部矩阵原点绘制，眼睛朝 +X。
draw_blob_body :: proc(b: ^r2d.Render2D, col: foster.Color) {
	R := PLAYER_RADIUS
	r2d.circle_gradient(b, foster.Vec2{}, R, 40, mix(col, WHITE, 0.35), col)
	r2d.circle_line(b, foster.Vec2{}, R, 3, 40, mix(col, INK, 0.35))
	for side in ([]f32{-1, 1}) {
		eye := foster.Vec2{R * 0.38, side * R * 0.34}
		r2d.circle(b, eye, 6.5, 16, WHITE)
		r2d.circle(b, eye + {2.2, 0}, 3.2, 12, foster.Color{20, 22, 36, 255})
	}
}

draw_labels :: proc(v: ^View, reg: ^objects.Registry, local_id: objects.Network_Id) {
	b := &v.ui
	for id, pv in v.players {
		obj, ok := objects.get(reg, id)
		if !ok do continue
		p := objects.component_data(obj, Player, PLAYER_TYPE)
		if p == nil do continue
		size := 16 * v.scale
		name := id == local_id ? fmt.tprintf("P%d  YOU", p.slot + 1) : fmt.tprintf("P%d", p.slot + 1)
		nw := text_width(v, name, size)
		// 贴近上边时标签放到角色下方，避免压住 HUD。
		above := pv.pos.y > PLAYER_RADIUS + 40
		at := to_screen(v, pv.pos + {0, above ? -(PLAYER_RADIUS + 22) : PLAYER_RADIUS + 26})
		tag := foster.Rect{at.x - nw / 2 - 8 * v.scale, at.y - 11 * v.scale, nw + 16 * v.scale, 22 * v.scale}
		round_rect(b, tag, tag.Height / 2, fade(INK, 0.55))
		text(v, name, {at.x, tag.Y + 1 * v.scale}, size, id == local_id ? WHITE : mix(slot_color(p.slot), WHITE, 0.4), 0.5)
	}
}

Row :: struct {
	slot, score: i32,
	local:       bool,
}

draw_hud :: proc(a: ^App, v: ^View, match: ^Match, local_id: objects.Network_Id, w, h, ui: f32, origin: [2]f32, scale: f32) {
	b := &v.ui
	reg := view_registry(a)
	rows := make([dynamic]Row, context.temp_allocator)
	for id, obj in reg.objects {
		if p := objects.component_data(obj, Player, PLAYER_TYPE); p != nil {
			append(&rows, Row{p.slot, p.score, id == local_id})
		}
	}
	slice.sort_by(rows[:], proc(x, y: Row) -> bool { return x.score > y.score || (x.score == y.score && x.slot < y.slot) })

	// 标题与连接信息
	pad := 28 * ui
	text(v, "NET ARENA", {pad, 18 * ui}, 34 * ui, WHITE)
	status: string
	switch a.mode {
	case .Host: status = fmt.tprintf("HOSTING  :%d", a.port)
	case .Server: status = fmt.tprintf("SERVER  :%d  (spectating)", a.port)
	case .Client: status = fmt.tprintf("CLIENT  %s:%d", a.address, a.port)
	}
	r2d.circle(b, foster.Vec2{pad + 5 * ui, 66 * ui}, 5 * ui, 12, NEON)
	line := fmt.tprintf("%s   %d online", status, len(rows))
	stats: nr.Net_Stats
	if a.client_ready do stats = nr.stats(&a.runtime.client)
	if a.mode == .Client && a.session.client_authenticated {
		line = fmt.tprintf("%s   ping %d ms", line, int(stats.rtt_ms))
		if a.lag_ms > 0 do line = fmt.tprintf("%s   lead %d ticks", line, stats.prediction_lead)
	}
	text(v, line, {pad + 16 * ui, 56 * ui}, 18 * ui, DIM)
	if a.lag_ms > 0 {
		// 调试：模拟延迟与预测校正次数
		text(v, fmt.tprintf("lag %d ms   corrections %d", a.lag_ms, stats.corrections), {pad, h - 34 * ui}, 15 * ui, fade(NEON, 0.7))
	}

	// 回合计时
	if match != nil {
		secs := int(math.ceil(match.time_left))
		clock := fmt.tprintf("%d:%02d", secs / 60, secs % 60)
		urgent := Phase(match.phase) == .Playing && match.time_left < 10
		color := urgent ? mix(WHITE, DANGER, 0.5 + 0.5 * math.sin(v.time * 8)) : WHITE
		text(v, clock, {w / 2, 8 * ui}, 54 * ui, color, 0.5)
		text(v, fmt.tprintf("ROUND %d", match.round), {w / 2, 64 * ui}, 16 * ui, DIM, 0.5)
	}

	// 计分板
	panel_w := 210 * ui
	row_h := 30 * ui
	px := w - pad - panel_w
	py := 16 * ui
	if len(rows) > 0 {
		panel := foster.Rect{px, py, panel_w, row_h * f32(len(rows)) + 14 * ui}
		panel.Y = origin.y + 14 * ui
		panel.X = origin.x + ARENA.x * scale - panel_w - 14 * ui
		round_rect(b, panel, 12 * ui, fade(foster.Color{8, 10, 20, 255}, 0.72))
		for row, i in rows {
			y := panel.Y + 7 * ui + f32(i) * row_h
			col := slot_color(row.slot)
			if row.local {
				round_rect(b, foster.Rect{panel.X + 6 * ui, y, panel_w - 12 * ui, row_h - 2 * ui}, 8 * ui, fade(col, 0.22))
			}
			r2d.circle(b, foster.Vec2{panel.X + 22 * ui, y + row_h * 0.47}, 7 * ui, 16, col)
			label := row.local ? fmt.tprintf("P%d  you", row.slot + 1) : fmt.tprintf("P%d", row.slot + 1)
			text(v, label, {panel.X + 38 * ui, y + 4 * ui}, 18 * ui, WHITE)
			text(v, fmt.tprintf("%d", row.score), {panel.X + panel_w - 16 * ui, y + 4 * ui}, 18 * ui, GOLD, 1)
		}
	}

	hint := "WASD / ARROWS  move      SPACE  dash      dash into rivals to knock coins loose      ESC  menu"
	text(v, hint, {w / 2, h - 34 * ui}, 16 * ui, fade(DIM, 0.9), 0.5)

	arena := foster.Rect{origin.x, origin.y, ARENA.x * scale, ARENA.y * scale}
	center := [2]f32{arena.X + arena.Width / 2, arena.Y + arena.Height / 2}
	if match != nil && Phase(match.phase) == .Results {
		round_rect(b, arena, 22 * scale, fade(foster.Color{6, 8, 16, 255}, 0.7))
		title := "DRAW"
		color := WHITE
		if match.winner >= 0 {
			title = fmt.tprintf("P%d WINS", match.winner + 1)
			color = slot_color(match.winner)
		}
		pulse := 1 + 0.04 * math.sin(v.time * 6)
		text(v, title, center + {0, -110 * ui}, 84 * ui * pulse, color, 0.5)
		for row, i in rows {
			if i >= 5 do break
			y := center.y + f32(i) * 34 * ui - 10 * ui
			r2d.circle(b, foster.Vec2{center.x - 90 * ui, y + 13 * ui}, 8 * ui, 16, slot_color(row.slot))
			text(v, fmt.tprintf("P%d", row.slot + 1), {center.x - 70 * ui, y}, 22 * ui, WHITE)
			text(v, fmt.tprintf("%d", row.score), {center.x + 100 * ui, y}, 22 * ui, GOLD, 1)
		}
		text(v, fmt.tprintf("next round in %d", int(math.ceil(match.time_left))), {center.x, arena.Y + arena.Height - 60 * ui}, 18 * ui, DIM, 0.5)
	} else if a.client_ready && local_id == 0 {
		round_rect(b, arena, 22 * scale, fade(foster.Color{6, 8, 16, 255}, 0.55))
		msg := a.session.client_authenticated ? "Arena is full - spectating" : fmt.tprintf("Connecting to %s:%d", a.address, a.port)
		text(v, msg, center + {0, -20 * ui}, 28 * ui, WHITE, 0.5)
		text(v, "ESC  back to menu", center + {0, 64 * ui}, 16 * ui, DIM, 0.5)
		for i in 0 ..< 3 {
			t := 0.5 + 0.5 * math.sin(v.time * 5 - f32(i) * 0.8)
			r2d.circle(b, foster.Vec2{center.x + (f32(i) - 1) * 22 * ui, center.y + 32 * ui}, (4 + 3 * t) * ui, 16, fade(NEON, 0.4 + 0.6 * t))
		}
	}
}
