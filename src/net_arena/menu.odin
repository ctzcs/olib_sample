package main

import "core:fmt"
import "core:math"
import "core:net"
import "core:slice"
import "core:strconv"
import "core:strings"

import foster "olib:foster"
import r2d "olib:kit/rendering/2d"
import mat "olib:kit/rendering/material"

// ==============================================================================
// 开始菜单：选择开房或加入，填写地址/端口，不需要命令行参数
// ==============================================================================

Menu_Tab :: enum { Host, Join }
Menu_Field :: enum { None, Address, Port }

Menu :: struct {
	tab:       Menu_Tab,
	focus:     Menu_Field,
	address:   [dynamic]u8,
	port:      [dynamic]u8,
	bots:      int,
	ips:       [dynamic]string, // 本机局域网 IPv4，开房时提示给朋友
	message:   [160]u8,
	message_n: int,
	size:      [2]f32, // 上一帧窗口像素尺寸，点击判定用
	pressed:   bool,   // 按下鼠标的那一帧，用于按钮按压效果
}

Menu_Layout :: struct {
	ui:                      f32,
	card, tab_host, tab_join: foster.Rect,
	field1, field2:          foster.Rect,
	minus, plus:             foster.Rect,
	button:                  foster.Rect,
}

menu_init :: proc(m: ^Menu, a: ^App) {
	append(&m.address, a.address)
	append(&m.port, fmt.tprintf("%d", a.port))
	m.bots = a.bots
	m.focus = .Port
	m.size = {1280, 800}
	interfaces, err := net.enumerate_interfaces(context.temp_allocator)
	if err != nil {
		return
	}
	// 给朋友看的地址：真实局域网网卡（私有网段且有网关）排前面，虚拟网卡排后面，
	// 代理 TUN 常用的 198.18.0.0/15 和回环、169.254 自动地址直接跳过。
	Candidate :: struct { text: string, score: int }
	found := make([dynamic]Candidate, context.temp_allocator)
	for itf in interfaces {
		virtual := false
		for tag in ([]string{"vEthernet", "VMware", "VirtualBox", "WSL", "Hyper-V", "Loopback"}) {
			virtual ||= strings.contains(itf.friendly_name, tag) || strings.contains(itf.description, tag)
		}
		for lease in itf.unicast {
			ip, ok := lease.address.(net.IP4_Address)
			if !ok || ip[0] == 127 || (ip[0] == 169 && ip[1] == 254) || (ip[0] == 198 && ip[1] & 0xfe == 18) do continue
			score := 0
			if ip[0] == 10 || (ip[0] == 172 && ip[1] & 0xf0 == 16) || (ip[0] == 192 && ip[1] == 168) do score += 2
			if ip[0] == 100 && ip[1] & 0xc0 == 64 do score += 1 // Tailscale 等虚拟局域网
			if len(itf.gateways) > 0 do score += 4
			if virtual do score -= 4
			append(&found, Candidate{fmt.tprintf("%d.%d.%d.%d", ip[0], ip[1], ip[2], ip[3]), score})
		}
	}
	slice.stable_sort_by(found[:], proc(x, y: Candidate) -> bool { return x.score > y.score })
	for c in found {
		if c.score < 0 || len(m.ips) >= 2 do break
		append(&m.ips, strings.clone(c.text))
	}
}

menu_destroy :: proc(m: ^Menu) {
	for ip in m.ips do delete(ip)
	delete(m.ips)
	delete(m.address)
	delete(m.port)
}

menu_set_message :: proc(m: ^Menu, text: string) {
	m.message_n = len(fmt.bprint(m.message[:], text))
}

menu_layout :: proc(size: [2]f32) -> Menu_Layout {
	l: Menu_Layout
	w, h := size.x, size.y
	l.ui = clamp(min(w / 1280, h / 800), 0.6, 3)
	ui := l.ui
	cw, ch := 520 * ui, 640 * ui
	l.card = {(w - cw) / 2, (h - ch) / 2 - 14 * ui, cw, ch}
	x, iw := l.card.X + 40 * ui, cw - 80 * ui
	tabs_y := l.card.Y + 150 * ui
	l.tab_host = {x, tabs_y, iw / 2, 52 * ui}
	l.tab_join = {x + iw / 2, tabs_y, iw / 2, 52 * ui}
	l.field1 = {x, l.card.Y + 266 * ui, iw, 52 * ui}
	l.field2 = {x, l.card.Y + 366 * ui, iw, 52 * ui}
	l.minus = {x + iw - 160 * ui, l.field2.Y, 52 * ui, 52 * ui}
	l.plus = {x + iw - 52 * ui, l.field2.Y, 52 * ui, 52 * ui}
	l.button = {x, l.card.Y + ch - 112 * ui, iw, 62 * ui}
	return l
}

inside :: proc(r: foster.Rect, p: [2]f32) -> bool {
	return p.x >= r.X && p.y >= r.Y && p.x < r.X + r.Width && p.y < r.Y + r.Height
}

// ==============================================================================
// 输入
// ==============================================================================

menu_update :: proc(a: ^App, app: ^foster.App) {
	m := &a.menu
	keys := &app.Input.State.Keyboard
	mouse := &app.Input.State.Mouse
	l := menu_layout(m.size)
	point := [2]f32{mouse.Position.X, mouse.Position.Y}
	m.pressed = foster.MouseDown(mouse, .Left) && inside(l.button, point)

	if foster.KeyboardPressed(keys, .Escape) {
		foster.Exit(app)
		return
	}
	if foster.MousePressed(mouse, .Left) {
		switch {
		case inside(l.tab_host, point):
			menu_switch(m, .Host)
		case inside(l.tab_join, point):
			menu_switch(m, .Join)
		case inside(l.field1, point):
			m.focus = m.tab == .Host ? .Port : .Address
		case m.tab == .Join && inside(l.field2, point):
			m.focus = .Port
		case m.tab == .Host && inside(l.minus, point):
			m.bots = max(0, m.bots - 1)
		case m.tab == .Host && inside(l.plus, point):
			m.bots = min(MAX_PLAYERS - 1, m.bots + 1)
		case inside(l.button, point):
			menu_start(a, app)
			return
		case:
			m.focus = .None
		}
	}
	if foster.KeyboardPressed(keys, .Tab) {
		if m.tab == .Join {
			m.focus = m.focus == .Address ? .Port : .Address
		} else {
			m.focus = .Port
		}
	}
	if foster.KeyboardPressed(keys, .Enter) || foster.KeyboardPressed(keys, .KeypadEnter) {
		menu_start(a, app)
		return
	}

	field := m.focus == .Address ? &m.address : m.focus == .Port ? &m.port : nil
	if field == nil {
		return
	}
	limit := m.focus == .Port ? 5 : 63
	typed := keys.Text
	if foster.KeyboardCtrl(keys) && foster.KeyboardPressed(keys, .V) {
		typed = foster.GetClipboardString(&app.Input)
		defer delete(typed)
		menu_type(field, typed, m.focus == .Port, limit)
	} else {
		menu_type(field, typed, m.focus == .Port, limit)
	}
	if foster.KeyboardPressed(keys, .Backspace) && len(field) > 0 {
		pop(field)
	}
}

menu_type :: proc(field: ^[dynamic]u8, typed: string, digits: bool, limit: int) {
	for c in transmute([]u8)typed {
		ok := c >= '0' && c <= '9'
		if !digits {
			ok ||= (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '.' || c == '-' || c == ':'
		}
		if ok && len(field) < limit {
			append(field, c)
		}
	}
}

menu_switch :: proc(m: ^Menu, tab: Menu_Tab) {
	m.tab = tab
	m.focus = tab == .Host ? .Port : .Address
	m.message_n = 0
}

menu_start :: proc(a: ^App, app: ^foster.App) {
	m := &a.menu
	port, ok := strconv.parse_uint(string(m.port[:]), 10)
	if !ok || port == 0 || port > 65535 {
		menu_set_message(m, "Port must be a number between 1 and 65535")
		m.focus = .Port
		return
	}
	if m.tab == .Join && len(m.address) == 0 {
		menu_set_message(m, "Enter the host's address")
		m.focus = .Address
		return
	}
	a.mode = m.tab == .Host ? .Host : .Client
	a.address = string(m.address[:]) // 进入游戏后菜单字段不再变化，可直接借用
	a.port = u16(port)
	a.bots = m.tab == .Host ? m.bots : 0
	if !start_game(a) {
		menu_set_message(m, fmt.tprintf("Could not open port %d - is it already in use?", port))
		return
	}
	m.message_n = 0
	foster.StopTextInput(&app.Window)
}

// ==============================================================================
// 绘制
// ==============================================================================

menu_render :: proc(a: ^App, app: ^foster.App, target: foster.DrawableTarget) {
	m := &a.menu
	v := &a.view
	b := &v.ui
	w, h := f32(target.WidthInPixels), f32(target.HeightInPixels)
	m.size = {w, h}
	l := menu_layout(m.size)
	ui := l.ui
	mouse := &app.Input.State.Mouse
	point := [2]f32{mouse.Position.X, mouse.Position.Y}

	foster.GraphicsDeviceClear(&app.GraphicsDevice, target, BG)
	r2d.circle_gradient(b, foster.Vec2{w / 2, h * 0.45}, max(w, h) * 0.75, 64, BG_GLOW, BG)
	draw_menu_backdrop(v, w, h, ui)

	card := l.card
	for i in 0 ..< 5 {
		g := f32(5 - i) * 8 * ui
		round_rect(b, foster.Rect{card.X - g, card.Y - g, card.Width + g * 2, card.Height + g * 2}, 26 * ui + g, fade(NEON, 0.03))
	}
	round_rect(b, card, 26 * ui, fade(foster.Color{16, 19, 34, 255}, 0.94))
	round_rect_line(b, card, 26 * ui, 2 * ui, fade(NEON, 0.45))

	cx := card.X + card.Width / 2
	text(v, "NET ARENA", {cx, card.Y + 30 * ui}, 64 * ui, WHITE, 0.5)
	text(v, "grab coins, dash into rivals, top the board", {cx, card.Y + 104 * ui}, 17 * ui, DIM, 0.5)

	// 页签
	track := foster.Rect{l.tab_host.X, l.tab_host.Y, l.tab_host.Width * 2, l.tab_host.Height}
	round_rect(b, track, 14 * ui, foster.Color{10, 12, 22, 255})
	active := m.tab == .Host ? l.tab_host : l.tab_join
	knob := foster.Rect{active.X + 4 * ui, active.Y + 4 * ui, active.Width - 8 * ui, active.Height - 8 * ui}
	round_rect(b, knob, 11 * ui, fade(NEON, 0.2))
	round_rect_line(b, knob, 11 * ui, 1.5 * ui, fade(NEON, 0.7))
	for tab in Menu_Tab {
		r := tab == .Host ? l.tab_host : l.tab_join
		label := tab == .Host ? "HOST A GAME" : "JOIN A GAME"
		color := m.tab == tab ? WHITE : inside(r, point) ? mix(DIM, WHITE, 0.5) : DIM
		text(v, label, {r.X + r.Width / 2, mid_y(r, 18 * ui)}, 18 * ui, color, 0.5)
	}

	// 表单
	if m.tab == .Host {
		draw_field(v, l.field1, "PORT", string(m.port[:]), m.focus == .Port, point, ui)
		label_y := l.field2.Y - 28 * ui
		text(v, "BOTS", {l.field2.X, label_y}, 15 * ui, DIM)
		text(v, "AI players to fill the arena", {l.field2.X, mid_y(l.field2, 17 * ui)}, 17 * ui, fade(DIM, 0.8))
		draw_step_button(v, l.minus, "-", m.bots > 0, point, ui)
		draw_step_button(v, l.plus, "+", m.bots < MAX_PLAYERS - 1, point, ui)
		count := foster.Rect{l.minus.X + l.minus.Width, l.minus.Y, l.plus.X - l.minus.X - l.minus.Width, l.minus.Height}
		text(v, fmt.tprintf("%d", m.bots), {count.X + count.Width / 2, mid_y(count, 26 * ui)}, 26 * ui, WHITE, 0.5)

		info_y := l.field2.Y + l.field2.Height + 22 * ui
		port := string(m.port[:])
		if len(m.ips) > 0 {
			text(v, "Friends on your network join with", {cx, info_y}, 15 * ui, DIM, 0.5)
			text(v, fmt.tprintf("%s : %s", m.ips[0], port), {cx, info_y + 22 * ui}, 22 * ui, NEON, 0.5)
			if len(m.ips) > 1 {
				text(v, fmt.tprintf("or  %s : %s", m.ips[1], port), {cx, info_y + 52 * ui}, 15 * ui, fade(NEON, 0.6), 0.5)
			}
		} else {
			text(v, fmt.tprintf("Friends join with your IP and port %s", port), {cx, info_y + 10 * ui}, 15 * ui, DIM, 0.5)
		}
	} else {
		draw_field(v, l.field1, "HOST ADDRESS", string(m.address[:]), m.focus == .Address, point, ui)
		draw_field(v, l.field2, "PORT", string(m.port[:]), m.focus == .Port, point, ui)
		text(v, "Ask the host for the address shown on their menu", {cx, l.field2.Y + l.field2.Height + 30 * ui}, 15 * ui, DIM, 0.5)
	}

	// 主按钮
	btn := l.button
	hover := inside(btn, point)
	if m.pressed {
		btn.Y += 2 * ui
	}
	glow := hover ? 0.5 : 0.3 + 0.1 * math.sin(v.time * 3)
	round_rect(b, foster.Rect{btn.X - 6 * ui, btn.Y - 2 * ui, btn.Width + 12 * ui, btn.Height + 14 * ui}, 20 * ui, fade(NEON, glow * 0.25))
	top_c := hover ? foster.Color{120, 245, 225, 255} : NEON
	round_rect(b, btn, 16 * ui, mix(top_c, foster.Color{30, 160, 140, 255}, 0.25))
	round_rect(b, foster.Rect{btn.X, btn.Y, btn.Width, btn.Height * 0.55}, 16 * ui, fade(WHITE, 0.12))
	label := m.tab == .Host ? "START HOSTING" : "JOIN GAME"
	text(v, label, {btn.X + btn.Width / 2, mid_y(btn, 24 * ui)}, 24 * ui, foster.Color{8, 30, 28, 255}, 0.5)

	if m.message_n > 0 {
		text(v, string(m.message[:m.message_n]), {cx, l.button.Y + l.button.Height + 16 * ui}, 16 * ui, DANGER, 0.5)
	}
	text(v, "ENTER  start      TAB  next field      CTRL+V  paste      ESC  quit", {w / 2, h - 34 * ui}, 15 * ui, fade(DIM, 0.8), 0.5)

	if err := r2d.submit(b, {target = target, time = v.time}); err != .None {
		fmt.eprintln("net_arena:", mat.draw_error_text(err))
	}
}

// 文字绘制位置是顶边，这里按字号估算把文字放到矩形竖直居中。
mid_y :: proc(r: foster.Rect, size: f32) -> f32 {
	return r.Y + (r.Height - size * 1.3) / 2
}

draw_field :: proc(v: ^View, r: foster.Rect, label, value: string, focused: bool, point: [2]f32, ui: f32) {
	b := &v.ui
	text(v, label, {r.X, r.Y - 28 * ui}, 15 * ui, focused ? NEON : DIM)
	round_rect(b, r, 12 * ui, foster.Color{9, 11, 20, 255})
	edge := focused ? NEON : inside(r, point) ? fade(WHITE, 0.35) : fade(WHITE, 0.14)
	round_rect_line(b, r, 12 * ui, (focused ? 2 : 1.5) * ui, edge)
	size := 22 * ui
	x := r.X + 18 * ui
	text(v, value, {x, mid_y(r, size)}, size, WHITE)
	if focused && math.mod(v.time, 1) < 0.55 {
		cx := x + text_width(v, value, size) + 3 * ui
		r2d.rect(b, foster.Rect{cx, r.Y + 13 * ui, 2.5 * ui, r.Height - 26 * ui}, NEON)
	}
}

draw_step_button :: proc(v: ^View, r: foster.Rect, label: string, enabled: bool, point: [2]f32, ui: f32) {
	b := &v.ui
	hover := enabled && inside(r, point)
	round_rect(b, r, 12 * ui, hover ? fade(NEON, 0.25) : foster.Color{9, 11, 20, 255})
	round_rect_line(b, r, 12 * ui, 1.5 * ui, fade(enabled ? NEON : WHITE, enabled ? 0.6 : 0.12))
	text(v, label, {r.X + r.Width / 2, mid_y(r, 28 * ui)}, 28 * ui, enabled ? WHITE : fade(DIM, 0.4), 0.5)
}

// 背景里游荡的角色和金币，只是装饰。
draw_menu_backdrop :: proc(v: ^View, w, h, ui: f32) {
	b := &v.ui
	t := v.time
	v.origin, v.scale = {}, ui * 1.4
	for i in 0 ..< 10 {
		fi := f32(i)
		p := [2]f32{
			w * 0.5 + math.cos(t * 0.11 * (1 + fi * 0.07) + fi * 2.1) * w * 0.44,
			h * 0.5 + math.sin(t * 0.09 * (1 + fi * 0.05) + fi * 1.3) * h * 0.42,
		}
		bob := math.sin(t * 2 + fi) * 4 * ui
		r2d.circle_gradient(b, foster.Vec2{p.x, p.y + bob}, 26 * ui, 24, fade(GOLD, 0.12), CLEAR)
		r2d.circle(b, foster.Vec2{p.x, p.y + bob}, 7 * ui, 16, fade(GOLD, 0.35))
	}
	for i in 0 ..< MAX_PLAYERS {
		fi := f32(i)
		speed := 0.07 + fi * 0.013
		angle := t * speed + fi * 0.785
		p := [2]f32{w * 0.5 + math.cos(angle) * w * (0.36 + 0.05 * math.sin(fi)), h * 0.5 + math.sin(angle * 1.3) * h * 0.38}
		vel := [2]f32{-math.sin(angle) * w * 0.36, math.cos(angle * 1.3) * h * 0.38 * 1.3}
		r2d.circle(b, foster.Vec2{p.x, p.y + PLAYER_RADIUS * 0.8 * v.scale}, PLAYER_RADIUS * v.scale * 0.9, 24, fade(INK, 0.25))
		push_local(v, p / v.scale, {1, 1}, math.atan2(vel.y, vel.x))
		draw_blob_body(b, slot_color(i32(i)))
		r2d.pop_matrix(b)
	}
}
