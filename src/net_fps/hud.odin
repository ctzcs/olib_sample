package main

import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"

import foster "olib:foster"
import r2d "olib:kit/rendering/2d"
import "olib:thirdparty/onet/objects"
import nr "olib:thirdparty/onet/runtime"

// ==============================================================================
// 2D：字体与文字工具、准星、血量、击杀播报、计分板与各种遮罩
// ==============================================================================

BG :: foster.Color{12, 14, 24, 255}
BG_GLOW :: foster.Color{26, 30, 54, 255}
NEON :: foster.Color{94, 234, 212, 255}
WHITE :: foster.Color{255, 255, 255, 255}
INK :: foster.Color{0, 0, 0, 255}
DIM :: foster.Color{150, 160, 190, 255}
GOLD :: foster.Color{255, 209, 102, 255}
DANGER :: foster.Color{255, 90, 90, 255}
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

FEED_SECONDS :: f32(5)

Feed :: struct {
	using msg: Kill_Msg,
	life:      f32,
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

hud_init :: proc(v: ^View, app: ^foster.App) {
	if reason := r2d.init(&v.ui, &v.materials); reason != "" {
		v.error = reason
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

hud_destroy :: proc(v: ^View) {
	if v.has_font {
		foster.SpriteFontDispose(&v.font_big)
		foster.SpriteFontDispose(&v.font)
		foster.FontDispose(&v.font_source)
	}
	r2d.dispose(&v.ui)
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

feed_push :: proc(v: ^View, m: Kill_Msg) {
	append(&v.feed, Feed{m, FEED_SECONDS})
	if len(v.feed) > 5 do ordered_remove(&v.feed, 0)
}

slot_name :: proc(slot: i32) -> string {
	return fmt.tprintf("P%d", slot + 1)
}

Score_Row :: struct {
	slot, kills, deaths: i32,
	local:               bool,
}

draw_hud :: proc(a: ^App, w, h: f32) {
	v := &a.view
	b := &v.ui
	ui := clamp(min(w / 1280, h / 800), 0.6, 3)
	pad := 26 * ui
	my_id, me := local_player(a)
	reg := a.client_ready ? &a.client_reg : &a.server_reg
	center := [2]f32{w / 2, h / 2}

	// 受伤：四边红色渐变
	if v.damage_flash > 0 {
		edge := 120 * ui
		red := fade(DANGER, 0.55 * v.damage_flash)
		r2d.rect_gradient(b, foster.Rect{0, 0, w, edge}, red, red, CLEAR, CLEAR)
		r2d.rect_gradient(b, foster.Rect{0, h - edge, w, edge}, CLEAR, CLEAR, red, red)
		r2d.rect_gradient(b, foster.Rect{0, 0, edge, h}, red, CLEAR, CLEAR, red)
		r2d.rect_gradient(b, foster.Rect{w - edge, 0, edge, h}, CLEAR, red, red, CLEAR)
	}

	// 准星：开火后外扩；命中时叠加 X 形命中标记
	if me != nil && me.respawn <= 0 {
		gap := (6 + 10 * v.spread) * ui
		arm := 9 * ui
		th := 2.5 * ui
		for d in ([][2]f32{{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) {
			from := center + d * gap
			to := center + d * (gap + arm)
			r2d.line(b, foster.Vec2(from + {1, 1}), foster.Vec2(to + {1, 1}), th, fade(INK, 0.6))
			r2d.line(b, foster.Vec2(from), foster.Vec2(to), th, WHITE)
		}
		r2d.circle(b, foster.Vec2(center), 1.8 * ui, 8, WHITE)
		if v.hitmarker > 0 {
			color := fade(v.hit_head ? DANGER : WHITE, v.hitmarker)
			for d in ([][2]f32{{1, 1}, {-1, 1}, {1, -1}, {-1, -1}}) {
				r2d.line(b, foster.Vec2(center + d * 9 * ui), foster.Vec2(center + d * 17 * ui), 3 * ui, color)
			}
		}
	}

	// 左上：标题与连接
	status: string
	switch a.mode {
	case .Host: status = fmt.tprintf("HOSTING  :%d", a.port)
	case .Server: status = fmt.tprintf("SERVER  :%d  (spectating)", a.port)
	case .Client: status = fmt.tprintf("CLIENT  %s:%d", a.address, a.port)
	}
	rows := make([dynamic]Score_Row, context.temp_allocator)
	for id, obj in reg.objects {
		if p := objects.component_data(obj, Player, PLAYER_TYPE); p != nil {
			append(&rows, Score_Row{p.slot, p.kills, p.deaths, id == my_id})
		}
	}
	line := fmt.tprintf("%s   %d players", status, len(rows))
	if a.client_ready && a.session.client_authenticated && a.mode == .Client {
		line = fmt.tprintf("%s   ping %d ms", line, int(nr.stats(&a.runtime.client).rtt_ms))
	}
	panel_w := max(text_width(v, line, 17 * ui), text_width(v, "NET FPS", 30 * ui)) + 26 * ui
	round_rect(b, foster.Rect{pad - 12 * ui, 10 * ui, panel_w, 72 * ui}, 14 * ui, fade(BG, 0.55))
	text(v, "NET FPS", {pad, 16 * ui}, 30 * ui, WHITE)
	text(v, line, {pad, 52 * ui}, 17 * ui, DIM)

	// 右上：击杀播报
	for f, i in v.feed {
		alpha := min(1, f.life)
		killer, victim := slot_name(f.killer), slot_name(f.victim)
		mid := f.head ? "  HEADSHOT  " : "  >  "
		y := 18 * ui + f32(i) * 30 * ui
		total := text_width(v, killer, 18 * ui) + text_width(v, mid, 15 * ui) + text_width(v, victim, 18 * ui)
		x := w - pad - total
		round_rect(b, foster.Rect{x - 10 * ui, y - 3 * ui, total + 20 * ui, 28 * ui}, 8 * ui, fade(INK, 0.45 * alpha))
		text(v, killer, {x, y}, 18 * ui, fade(SLOT_COLORS[f.killer % MAX_PLAYERS], alpha))
		x += text_width(v, killer, 18 * ui)
		text(v, mid, {x, y + 3 * ui}, 15 * ui, fade(f.head ? DANGER : DIM, alpha))
		x += text_width(v, mid, 15 * ui)
		text(v, victim, {x, y}, 18 * ui, fade(SLOT_COLORS[f.victim % MAX_PLAYERS], alpha))
	}

	// 左下：血量；右下：击杀/死亡
	if me != nil {
		hp := max(me.health, 0)
		// 场景很亮，HUD 文字放在半透明深色底板上。
		round_rect(b, foster.Rect{pad - 14 * ui, h - 124 * ui, 290 * ui, 86 * ui}, 14 * ui, fade(BG, 0.6))
		round_rect(b, foster.Rect{w - pad - 196 * ui, h - 124 * ui, 210 * ui, 86 * ui}, 14 * ui, fade(BG, 0.6))
		bar := foster.Rect{pad, h - 58 * ui, 260 * ui, 12 * ui}
		r2d.rect(b, bar, fade(WHITE, 0.15))
		fill := bar
		fill.Width *= f32(hp) / MAX_HEALTH
		color := hp > 35 ? NEON : mix(DANGER, WHITE, 0.3 + 0.3 * math.sin(v.time * 10))
		if fill.Width > 1 do r2d.rect(b, fill, color)
		text(v, fmt.tprintf("%d", hp), {pad, h - 112 * ui}, 46 * ui, WHITE)
		text(v, "HEALTH", {pad + text_width(v, fmt.tprintf("%d", hp), 46 * ui) + 10 * ui, h - 88 * ui}, 15 * ui, DIM)
		score := fmt.tprintf("%d  /  %d", me.kills, me.deaths)
		text(v, score, {w - pad, h - 100 * ui}, 34 * ui, WHITE, 1)
		text(v, "KILLS / DEATHS", {w - pad, h - 58 * ui}, 15 * ui, DIM, 1)
	}
	if a.lag_ms > 0 && a.client_ready {
		st := nr.stats(&a.runtime.client)
		text(v, fmt.tprintf("lag %d ms   lead %d ticks   corrections %d", a.lag_ms, st.prediction_lead, st.corrections), {w / 2, h - 30 * ui}, 15 * ui, fade(NEON, 0.8), 0.5)
	} else {
		hint := "WASD move   SPACE jump   LMB fire   V talk   F1 voice check   TAB scores   ESC release mouse"
		hw := text_width(v, hint, 15 * ui)
		round_rect(b, foster.Rect{w / 2 - hw / 2 - 12 * ui, h - 34 * ui, hw + 24 * ui, 26 * ui}, 13 * ui, fade(BG, 0.5))
		text(v, hint, {w / 2, h - 32 * ui}, 15 * ui, fade(WHITE, 0.85), 0.5)
	}

	draw_voice_hud(a, w, h, ui)
	if a.voice.diag.show && a.client_ready do draw_voice_diag(a, w, h, ui)

	// 阵亡 / 连接中遮罩
	if me != nil && me.respawn > 0 {
		r2d.rect(b, foster.Rect{0, 0, w, h}, fade(foster.Color{60, 0, 0, 255}, 0.35))
		text(v, "ELIMINATED", {w / 2, h * 0.36}, 72 * ui, DANGER, 0.5)
		text(v, fmt.tprintf("respawning in %.1f", me.respawn), {w / 2, h * 0.36 + 90 * ui}, 22 * ui, WHITE, 0.5)
	} else if a.client_ready && my_id == 0 {
		r2d.rect(b, foster.Rect{0, 0, w, h}, fade(BG, 0.55))
		msg := a.session.client_authenticated ? "Server is full - spectating" : fmt.tprintf("Connecting to %s:%d", a.address, a.port)
		text(v, msg, center + {0, -20 * ui}, 28 * ui, WHITE, 0.5)
		text(v, "ESC  back to menu", center + {0, 30 * ui}, 16 * ui, DIM, 0.5)
	}

	if a.paused && a.client_ready {
		r2d.rect(b, foster.Rect{0, 0, w, h}, fade(BG, 0.5))
		text(v, "PAUSED", {w / 2, h * 0.36}, 64 * ui, WHITE, 0.5)
		text(v, "click to resume      ESC  leave to menu", {w / 2, h * 0.36 + 84 * ui}, 20 * ui, DIM, 0.5)
		draw_voice_devices(a, w, h, ui)
	}

	// 计分板：按住 Tab，或观战时常显
	if a.show_scores || a.mode == .Server {
		slice.sort_by(rows[:], proc(x, y: Score_Row) -> bool { return x.kills > y.kills || (x.kills == y.kills && x.deaths < y.deaths) })
		row_h := 34 * ui
		panel := foster.Rect{w / 2 - 220 * ui, h * 0.22, 440 * ui, 56 * ui + row_h * f32(len(rows))}
		round_rect(b, panel, 14 * ui, fade(foster.Color{8, 10, 20, 255}, 0.82))
		text(v, "PLAYER", {panel.X + 24 * ui, panel.Y + 16 * ui}, 14 * ui, DIM)
		text(v, "K", {panel.X + panel.Width - 110 * ui, panel.Y + 16 * ui}, 14 * ui, DIM, 0.5)
		text(v, "D", {panel.X + panel.Width - 50 * ui, panel.Y + 16 * ui}, 14 * ui, DIM, 0.5)
		for r, i in rows {
			y := panel.Y + 44 * ui + f32(i) * row_h
			if r.local do round_rect(b, foster.Rect{panel.X + 8 * ui, y - 4 * ui, panel.Width - 16 * ui, row_h - 2 * ui}, 8 * ui, fade(NEON, 0.15))
			r2d.circle(b, foster.Vec2{panel.X + 30 * ui, y + 12 * ui}, 7 * ui, 16, SLOT_COLORS[r.slot % MAX_PLAYERS])
			text(v, r.local ? fmt.tprintf("%s  you", slot_name(r.slot)) : slot_name(r.slot), {panel.X + 46 * ui, y}, 19 * ui, WHITE)
			text(v, fmt.tprintf("%d", r.kills), {panel.X + panel.Width - 110 * ui, y}, 19 * ui, GOLD, 0.5)
			text(v, fmt.tprintf("%d", r.deaths), {panel.X + panel.Width - 50 * ui, y}, 19 * ui, WHITE, 0.5)
		}
	}
	if v.error != "" {
		text(v, v.error, {pad, 80 * ui}, 16 * ui, DANGER)
	}
}

// 语音：说话时左下角麦克风与电平；左侧列出正在说话的人；不可用时给出原因。
draw_voice_hud :: proc(a: ^App, w, h, ui: f32) {
	v := &a.view
	b := &v.ui
	vo := &a.voice
	if !a.client_ready do return
	x, y := 26 * ui, h - 168 * ui
	if !vo.ready || vo.status != "" {
		status := vo.ready ? vo.status : (vo.status != "" ? vo.status : "voice off")
		text(v, status, {x, y + 8 * ui}, 14 * ui, fade(DIM, 0.9))
	}
	if vo.notice_time > 0 {
		alpha := min(1, vo.notice_time * 2)
		msg := fmt.tprintf("audio: %s", vo.notice)
		mw := text_width(v, msg, 16 * ui)
		round_rect(b, foster.Rect{w / 2 - mw / 2 - 14 * ui, 96 * ui, mw + 28 * ui, 30 * ui}, 12 * ui, fade(BG, 0.7 * alpha))
		text(v, msg, {w / 2, 100 * ui}, 16 * ui, fade(WHITE, alpha), 0.5)
	}
	if vo.talking && vo.silent_time > 1 {
		text(v, "Mic is silent - check Windows microphone privacy / mute, or press M to switch mic", {x, y - 26 * ui}, 15 * ui, DANGER)
	}
	if vo.talking {
		round_rect(b, foster.Rect{x - 12 * ui, y - 4 * ui, 200 * ui, 34 * ui}, 12 * ui, fade(BG, 0.6))
		r2d.circle(b, foster.Vec2{x + 6 * ui, y + 13 * ui}, 6 * ui, 16, mix(DANGER, WHITE, 0.2 + 0.2 * math.sin(v.time * 8)))
		text(v, "MIC", {x + 18 * ui, y + 2 * ui}, 16 * ui, WHITE)
		bar := foster.Rect{x + 62 * ui, y + 9 * ui, 110 * ui, 8 * ui}
		r2d.rect(b, bar, fade(WHITE, 0.15))
		bar.Width *= clamp(vo.level * 6, 0, 1)
		if bar.Width > 0.5 do r2d.rect(b, bar, NEON)
	}
	row := 0
	for id, _ in vo.receivers {
		if !voice_speaking(vo, id) do continue
		obj, ok := objects.get(&a.client_reg, id)
		if !ok do continue
		p := objects.component_data(obj, Player, PLAYER_TYPE)
		if p == nil do continue
		ry := h * 0.42 + f32(row) * 30 * ui
		round_rect(b, foster.Rect{x - 12 * ui, ry - 4 * ui, 150 * ui, 28 * ui}, 10 * ui, fade(BG, 0.55))
		for k in 0 ..< 3 {
			bh := (4 + 8 * abs(math.sin(v.time * 9 + f32(k) * 1.7))) * ui
			r2d.rect(b, foster.Rect{x + f32(k) * 6 * ui, ry + 18 * ui - bh, 4 * ui, bh}, SLOT_COLORS[p.slot % MAX_PLAYERS])
		}
		text(v, fmt.tprintf("%s  talking", slot_name(p.slot)), {x + 26 * ui, ry}, 16 * ui, WHITE)
		row += 1
	}
}

// 暂停画面：当前麦克风（含实时电平）与输出设备，M / O 切换。
draw_voice_devices :: proc(a: ^App, w, h, ui: f32) {
	v := &a.view
	b := &v.ui
	vo := &a.voice
	if !vo.ready do return
	panel := foster.Rect{w / 2 - 300 * ui, h * 0.36 + 140 * ui, 600 * ui, 150 * ui}
	round_rect(b, panel, 14 * ui, fade(foster.Color{8, 10, 20, 255}, 0.8))
	x := panel.X + 24 * ui
	y := panel.Y + 18 * ui
	text(v, "MICROPHONE   (M to switch)", {x, y}, 14 * ui, NEON)
	text(v, vo.test_tone ? "voicetest tone" : voice_device_name(vo.rec_names, vo.mic_choice), {x, y + 22 * ui}, 18 * ui, WHITE)
	bar := foster.Rect{panel.X + panel.Width - 180 * ui, y + 28 * ui, 150 * ui, 8 * ui}
	r2d.rect(b, bar, fade(WHITE, 0.15))
	fill := bar
	fill.Width *= clamp(vo.mic_level * 8, 0, 1)
	if fill.Width > 0.5 do r2d.rect(b, fill, NEON)
	if vo.has_mic && vo.mic_level == 0 && !vo.test_tone {
		text(v, "no signal", {bar.X + bar.Width, bar.Y - 22 * ui}, 13 * ui, DANGER, 1)
	}
	y += 70 * ui
	text(v, "OUTPUT   (O to switch, plays a short beep)      L  hear your own mic", {x, y}, 14 * ui, NEON)
	text(v, voice_device_name(vo.play_names, vo.out_choice), {x, y + 22 * ui}, 18 * ui, WHITE)
}
