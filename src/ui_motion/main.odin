package main

import "core:fmt"
import "core:os"

import tween "olib:core/tween"
import foster "olib:foster"
import appkit "olib:kit/app"
import r2d "olib:kit/rendering/2d"
import mat "olib:kit/rendering/material"
import ui "olib:kit/ui"

import fonts "../../shared/msdf_font"

// 分区：状态与生命周期 / 更新与最终像素输出 / 自动验收

Demo :: struct {
	ctx: ui.UI_Context,
	theme: ui.UI_Theme,
	materials: mat.Material_Library,
	batch: r2d.Render2D,
	font: foster.MsdfFont,
	font_texture, icons: foster.Texture,
	target: foster.Target,
	tweens: tween.Tween_Manager,
	cards: [CARD_COUNT]Card,
	slots: [SLOT_COUNT]int, // 槽内卡牌序号，-1 为空
	slot_rects: [SLOT_COUNT]foster.Rect,
	hand_rects: [CARD_COUNT]foster.Rect,
	slot_glow: [SLOT_COUNT]f32,
	hand: [CARD_COUNT]int, // 托盘从左到右的卡牌顺序；行动槽里的卡仍占位，宽度为 0
	hand_open: [CARD_COUNT]f32, // 托盘卡位展开比例 0..1，按卡牌序号
	gap_open: [CARD_COUNT + 1]f32, // 各插入位置的空隙展开比例，按 hand 下标
	tray_rect: foster.Rect,
	card_size: foster.Vec2,
	rects_ready: bool,
	drag: Drag,
	playing, gate_opened: bool,
	play_slot: int,
	play_timer: f32,
	modal_open: bool,
	attacks, rewards, guards, frame: int,
	shot, scaled, failed: bool,
	script_from, script_to: foster.Vec2,
	dt: f32,
}

// ==============================================================================
// 状态与生命周期
// ==============================================================================

main :: proc() {
	s := new(Demo)
	s.shot = appkit.has_arg(os.args, "shot") || appkit.has_arg(os.args, "smoke")
	s.scaled = appkit.has_arg(os.args, "scaled")
	config := foster.DefaultAppConfig("olib - UI Motion | Drag cards into slots | Tab / Enter | Esc", 1200, 760)
	// 默认固定 60Hz 更新会在两帧之间 sleep，高刷新率显示器上帧间隔忽长忽短；交给 VSync 定节奏。
	config.UpdateMode = foster.UnlockedStep()
	if appkit.has_arg(os.args, "narrow") {
		config.Width = 760
	}
	if appkit.has_arg(os.args, "vulkan") {
		config.PreferredGraphicsDriver = .Vulkan
	}
	game: foster.App
	foster.InitApp(&game, config)
	foster.AppSetUserData(&game, s)
	game.StartupProc = startup
	game.UpdateProc = update
	game.RenderProc = render
	game.ShutdownProc = shutdown
	foster.Run(&game)
	foster.Dispose(&game)
	delete(game.GraphicsDevice.WindowRenderTarget.Attachments)
	failed := s.failed
	free(s)
	if failed do os.exit(1)
}

startup :: proc(g: ^foster.App) {
	s := foster.AppGetUserDataAs(g, Demo)
	if !ui.ui_init(&s.ctx, 1200, 760) {
		s.failed = true
		foster.Exit(g)
		return
	}
	font, texture, ok := fonts.load(&g.GraphicsDevice)
	if !ok {
		s.failed = true
		foster.Exit(g)
		return
	}
	s.font = font
	s.font_texture = texture
	ui.ui_register_font(&s.ctx, &s.font, texture, .MSDF)
	s.theme = ui.UI_THEME_DARK
	s.theme.text = PAPER
	s.theme.text_dim = MUTED
	s.theme.button = RED
	s.theme.button_hover = {175, 70, 53, 255}
	s.theme.button_press = {105, 39, 36, 255}
	s.theme.accent = GOLD
	s.theme.corner_radius = 8
	s.theme.padding = 12
	s.theme.body_font_size = 18
	s.theme.heading_font_size = 30
	s.tweens = tween.manager_make()
	cards_init(s)
	s.materials = {device = &g.GraphicsDevice}
	if reason := r2d.init(&s.batch, &s.materials); reason != "" {
		fmt.eprintln(reason)
		os.exit(1)
	}
	s.icons = make_icons(&g.GraphicsDevice)
}

shutdown :: proc(g: ^foster.App) {
	s := foster.AppGetUserDataAs(g, Demo)
	// 先取消指针绑定的 Tween，再释放 UI 和持有状态。
	tween.manager_delete(&s.tweens)
	ui.ui_dispose(&s.ctx)
	r2d.dispose(&s.batch)
	mat.material_library_dispose(&s.materials)
	foster.TargetDispose(&s.target)
	foster.TextureDispose(&s.icons)
	foster.TextureDispose(&s.font_texture)
	foster.MsdfFontDispose(&s.font)
}

// ==============================================================================
// 更新与最终像素输出
// ==============================================================================

update :: proc(g: ^foster.App) {
	s := foster.AppGetUserDataAs(g, Demo)
	s.dt = s.shot ? 1.0 / 60 : min(g.Time.Delta, 0.1)
	tween.manager_update(&s.tweens, s.dt)
	play_step(s, s.dt)
	if foster.KeyboardPressed(&g.Input.State.Keyboard, .Escape) {
		s.modal_open = false
	}
	if s.shot && s.frame == 248 {
		foster.SetWindowSize(&g.Window, {960, 800})
	}
}

render :: proc(g: ^foster.App) {
	s := foster.AppGetUserDataAs(g, Demo)
	pixels := foster.SizeInPixels(&g.Window)
	if pixels.X <= 0 || pixels.Y <= 0 do return
	if s.shot && (s.target.Width != pixels.X || s.target.Height != pixels.Y) {
		foster.TargetDispose(&s.target)
		foster.TargetInit(&s.target, &g.GraphicsDevice, pixels.X, pixels.Y)
	}
	w := f32(pixels.X)
	h := f32(pixels.Y)
	size := foster.Size(&g.Window)
	mouse := &g.Input.State.Mouse
	// 留出 12px 外边，验证 viewport 偏移；UI 直接绘制到最终 drawable 尺寸。
	ui.ui_set_viewport(&s.ctx, {12, 12, w - 24, h - 24}, s.scaled ? 1.25 : 1)
	ui.ui_set_pointer(&s.ctx, mouse.Position.X * w / f32(max(size.X, 1)),
		mouse.Position.Y * h / f32(max(size.Y, 1)), foster.MouseDown(mouse, .Left))
	nav: ui.UI_Navigation
	if foster.KeyboardPressed(&g.Input.State.Keyboard, .Tab) {
		nav.next = foster.KeyboardDown(&g.Input.State.Keyboard, .LeftShift) ? -1 : 1
	}
	nav.activate = foster.KeyboardPressed(&g.Input.State.Keyboard, .Enter)
	nav.cancel = s.drag.card >= 0 && foster.KeyboardPressed(&g.Input.State.Keyboard, .Escape)
	ui.ui_set_navigation(&s.ctx, nav)
	if s.shot {
		smoke_input(s)
	}
	cache_rects(s)
	ui.ui_set_modal(&s.ctx, s.modal_open ? "reward-modal" : "")
	ui.ui_begin(&s.ctx, s.dt)
	declare_ui(s)
	window := foster.DrawableTargetFromWindow(&g.Window)
	foster.GraphicsDeviceClear(&g.GraphicsDevice, window, INK)
	ui.ui_draw(&s.ctx, &s.batch)
	r2d.submit(&s.batch, {target = window})
	if s.shot {
		// 截图需要可回读的目标：submit 会清空记录，用同一批 UI 操作再记录一次。
		final := foster.DrawableTargetFromTarget(&s.target)
		foster.GraphicsDeviceClear(&g.GraphicsDevice, final, INK)
		ui.ui_render(&s.ctx, &s.batch, &s.ctx.ops)
		r2d.submit(&s.batch, {target = final})
		assert(s.ctx.error_count == 0 && !s.ctx.pool_overflow, "UI diagnostics")
		switch s.frame {
		case 3, 15, 30, 97, 160, 215, 223, 330, 370:
			save_frame(s)
		case 372:
			assert(s.slots == {-1, -1, 3} && s.rewards == 1 && !s.modal_open, "drag, swap, execute and resize")
			fmt.printf("UI MOTION PASS: drag into slot, click place, swap, execute queue, modal enter/exit, resize, reorder hand; %dx%d scale=%.2f\n",
				pixels.X, pixels.Y, s.ctx.scale)
			foster.Exit(g)
		}
	}
	s.frame += 1
}

// 上一帧布局的槽位与手牌矩形；卡牌在声明前就要知道自己的家。
cache_rects :: proc(s: ^Demo) {
	ready := true
	for id, i in SLOT_IDS {
		rect, ok := ui.ui_element_rect(&s.ctx, id)
		s.slot_rects[i] = rect
		ready = ready && ok
	}
	for id, i in HAND_IDS {
		rect, ok := ui.ui_element_rect(&s.ctx, id)
		s.hand_rects[i] = rect
		ready = ready && ok
	}
	s.tray_rect, _ = ui.ui_element_rect(&s.ctx, "tray")
	s.rects_ready = ready
}

// ==============================================================================
// 自动验收 —— 经 UI 输入入口拖动和点击实际显示位置，不直接调用业务动作
// ==============================================================================

smoke_input :: proc(s: ^Demo) {
	ui.ui_set_pointer(&s.ctx, -100, -100, false)
	switch s.frame {
	case 6..=24:
		smoke_drag(s, 0, 0, 6)
	case 55:
		assert(s.slots[0] == 0 && !s.cards[0].flying, "dragged card lands in slot 1")
	case 58, 59:
		smoke_point(s, card_center(s, 1), s.frame == 58)
	case 85:
		assert(s.slots[1] == 1, "click places card into the first empty slot")
	case 88..=106:
		smoke_drag(s, 2, 0, 88)
	case 135:
		assert(s.slots[0] == 2 && s.cards[2].slot == 0 && !s.cards[0].queued, "drop on occupied slot swaps")
	case 138, 139:
		smoke_point(s, element_center(s, "execute"), s.frame == 138)
	case 215:
		assert(s.modal_open && s.rewards == 1 && s.attacks == 0 && !s.playing, "queue played in order")
	case 218, 219:
		smoke_point(s, element_center(s, "close"), s.frame == 218)
	case 245:
		assert(!s.modal_open && s.slots == {-1, -1, -1}, "cards return to hand after execution")
		for card in s.cards {
			assert(!card.flying && card.motion.visual == ui.UI_VISUAL_DEFAULT, "cards settle at rest")
		}
	case 275..=293:
		// 窗口在 248 帧缩放，卡牌已飞到新布局；命中按新矩形计算。
		smoke_drag(s, 3, 2, 275)
	case 300..=338:
		// 托盘内重排：把最左的 ATTACK 拖到最后一张可见手牌右侧，停留等空隙展开后松开。
		if s.frame == 300 {
			last := s.hand_rects[2]
			s.script_to = {last.X + last.Width + s.card_size.x * 0.4, rect_center(s.tray_rect).y}
		}
		smoke_drag_to(s, 0, s.script_to, 300, 20)
	case 365:
		assert(s.hand == {1, 2, 3, 0} && !s.cards[0].flying && !s.cards[0].queued, "drop on tray inserts at gap")
	}
}

smoke_drag :: proc(s: ^Demo, index, slot, begin: int) {
	if s.frame == begin {
		s.script_to = rect_center(s.slot_rects[slot])
	}
	smoke_drag_to(s, index, s.script_to, begin, 0)
}

// 按下 -> 16 帧线性移动 -> 停留 hold 帧 -> 松开；起点在开始帧记录。
smoke_drag_to :: proc(s: ^Demo, index: int, to: foster.Vec2, begin, hold: int) {
	f := s.frame - begin
	if f == 0 {
		s.script_from = card_center(s, index)
	}
	switch {
	case f <= 1:
		smoke_point(s, s.script_from, f == 1)
	case f <= 17:
		t := f32(f - 1) / 16
		smoke_point(s, s.script_from + (to - s.script_from) * t, true)
	case f <= 17 + hold:
		smoke_point(s, to, true)
	case:
		smoke_point(s, to, false)
	}
}

smoke_point :: proc(s: ^Demo, logical: foster.Vec2, down: bool) {
	p := s.ctx.viewport_origin + logical * s.ctx.scale
	ui.ui_set_pointer(&s.ctx, p.x, p.y, down)
}

card_center :: proc(s: ^Demo, index: int) -> foster.Vec2 {
	return s.cards[index].pos + s.card_size * 0.5
}

element_center :: proc(s: ^Demo, id: string) -> foster.Vec2 {
	rect, ok := ui.ui_element_rect(&s.ctx, id)
	assert(ok)
	return rect_center(rect)
}

save_frame :: proc(s: ^Demo) {
	bytes := foster.TextureDownloadData(foster.TargetAttachment(&s.target))
	defer delete(bytes)
	image := foster.ImageMake(s.target.Width, s.target.Height)
	defer foster.ImageDispose(&image)
	assert(len(bytes) == len(image.Pixels) * 4, "final pixel readback")
	for &pixel, i in image.Pixels {
		pixel = {bytes[i * 4], bytes[i * 4 + 1], bytes[i * 4 + 2], bytes[i * 4 + 3]}
	}
	name := fmt.tprintf("build/ui-motion-%dx%d-%s-%03d.png", s.target.Width, s.target.Height,
		s.scaled ? "125" : "100", s.frame)
	assert(foster.ImageWritePng(&image, name))
	fmt.println(name)
}
