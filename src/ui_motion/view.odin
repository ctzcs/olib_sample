package main

import "core:fmt"
import "core:math/linalg"

import tween "olib:core/tween"
import foster "olib:foster"
import ui "olib:kit/ui"
import clay "olib:thirdparty/clay"

// 分区：配色与声明 / 行动槽与手牌托盘 / 卡牌 / 模态窗口 / 原创像素图标

INK :: foster.Color{24, 26, 30, 255}
PAPER :: foster.Color{237, 222, 191, 255}
MUTED :: foster.Color{163, 156, 139, 255}
GOLD :: foster.Color{219, 175, 89, 255}
RED :: foster.Color{147, 53, 43, 255}
FRAME :: foster.Color{95, 87, 72, 255}
WOOD :: foster.Color{112, 72, 46, 255}
WOOD_DARK :: foster.Color{66, 42, 30, 255}

@(rodata)
SLOT_IDS := [SLOT_COUNT]string{"slot-0", "slot-1", "slot-2"}
@(rodata)
HAND_IDS := [CARD_COUNT]string{"hand-0", "hand-1", "hand-2", "hand-3"}
@(rodata)
CARD_IDS := [CARD_COUNT]string{"card-0", "card-1", "card-2", "card-3"}
@(rodata)
POP_IDS := [CARD_COUNT]string{"pop-0", "pop-1", "pop-2", "pop-3"}
@(rodata)
SHADOW_IDS := [CARD_COUNT]string{"shadow-0", "shadow-1", "shadow-2", "shadow-3"}

// ==============================================================================
// 配色与声明
// ==============================================================================

declare_ui :: proc(s: ^Demo) {
	// 卡牌尺寸随逻辑视口收缩：窄窗口与 125% 缩放仍能放下四张手牌。
	k := clamp(min((s.ctx.width - 120) / 600, (s.ctx.height - 250) / 420), 0.6, 1)
	s.card_size = {124 * k, 186 * k}
	root := ui.ui_column_decl(u16(14 * k))
	root.layout.sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})}
	root.layout.padding = clay.PaddingAll(24)
	root.layout.childAlignment.x = .Center
	if clay.UI()(root) {
		header := ui.ui_column_decl(6)
		header.layout.sizing.width = clay.SizingGrow({})
		if clay.UI()(header) {
			ui.ui_label_ex(&s.ctx, &s.theme, "MOTION STUDY   /   02", GOLD, 14)
			ui.ui_label_ex(&s.ctx, &s.theme, "Drag. Drop. Strike.", PAPER, s.ctx.width < 700 ? 27 : 36)
			ui.ui_label_ex(&s.ctx, &s.theme, "拖动卡片放入行动槽，再点开始", MUTED, 16)
		}
		grow()
		queue_row(s, k)
		grow()
		tray(s, k)
		ui.ui_label_ex(&s.ctx, &s.theme,
			fmt.tprintf("ATTACKS  %02d     /     RELICS  %02d     /     GUARDS  %02d", s.attacks, s.rewards, s.guards),
			GOLD, 16)
		ui.ui_label_ex(&s.ctx, &s.theme, "Tab 选择   Enter 放入 / 取回   Esc 取消 / 关闭", MUTED, 14)
		// 卡牌浮在布局之上，位置由物理状态决定；声明在最后，读取的是上一帧的槽位矩形。
		for i in 0..<CARD_COUNT {
			card(s, i)
		}
	}
	modal(s)
}

grow :: proc() {
	if clay.UI()(clay.ElementDeclaration{
		layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})}},
	}) {}
}

font_size :: proc(size, k: f32) -> u16 {
	return u16(max(11, size * k))
}

// ==============================================================================
// 行动槽与手牌托盘 —— 只是放置目标，卡牌本身不在这里声明
// ==============================================================================

queue_row :: proc(s: ^Demo, k: f32) {
	row := ui.ui_row_decl(u16(14 * k))
	row.layout.sizing.width = clay.SizingFit({})
	if clay.UI()(row) {
		for slot in 0..<SLOT_COUNT {
			slot_socket(s, slot, k)
		}
		queued := 0
		for occupant in s.slots {
			if occupant >= 0 do queued += 1
		}
		if clay.UI()(clay.ElementDeclaration{layout = {sizing = {width = clay.SizingFixed(10 * k)}}}) {}
		label := s.playing ? "行动中..." : "开始 / GO"
		if ui.ui_button(&s.ctx, &s.theme, "execute", label, {disabled = s.playing || queued == 0}) {
			execute(s)
		}
	}
}

slot_socket :: proc(s: ^Demo, slot: int, k: f32) {
	id := SLOT_IDS[slot]
	target: f32 = s.drag.card >= 0 && s.drag.moved && s.drag.hover_slot == slot ? 1 : 0
	s.slot_glow[slot] = tween.approach(s.slot_glow[slot], target, 20, s.dt)
	glow := s.slot_glow[slot]
	ui.ui_motion(&s.ctx, id, target > 0 ? SLOT_HOVER : ui.UI_VISUAL_DEFAULT, MOTION_SLOT)
	border := lerp_color(FRAME, GOLD, glow)
	if s.playing && s.play_slot - 1 == slot && s.play_timer > 0 {
		border = GOLD
	}
	size := s.card_size + 14 * k
	outer := frame_outer(border, {2, 2, 2, 2}, 12 * k)
	outer.id = clay.ID(id)
	outer.layout.sizing = {width = clay.SizingFixed(size.x), height = clay.SizingFixed(size.y)}
	if clay.UI()(outer) {
		inner := frame_inner(lerp_color({30, 32, 36, 255}, {52, 46, 34, 255}, glow), 10 * k)
		inner.layout.layoutDirection = .TopToBottom
		inner.layout.padding = clay.PaddingAll(u16(10 * k))
		inner.layout.childAlignment = {x = .Center, y = .Center}
		inner.layout.childGap = 6
		if clay.UI()(inner) {
			ui.ui_label_ex(&s.ctx, &s.theme, fmt.tprintf("%d", slot + 1), FRAME, font_size(16, k))
			ui.ui_label_ex(&s.ctx, &s.theme, "+", lerp_color(FRAME, GOLD, glow), font_size(40, k))
		}
	}
}

// 托盘随手牌数量伸缩：离手（含拖动中）的卡位连同间距一起收窄到 0，回手时再展开。
tray :: proc(s: ^Demo, k: f32) {
	gap := 12 * k
	side := frame_side(WOOD_DARK, 4, 16 * k)
	side.id = clay.ID("tray")
	outer := frame_outer(WOOD_DARK, {3, 3, 3, 3}, 16 * k)
	if clay.UI()(side) do if clay.UI()(outer) {
	decl := frame_inner(WOOD, 13 * k)
	decl.layout.sizing = {}
	decl.layout.padding = clay.PaddingAll(u16(14 * k))
	decl.layout.padding.left = u16(14 * k - gap * 0.5)
	decl.layout.padding.right = decl.layout.padding.left
	if clay.UI()(decl) {
		size := s.card_size + 8 * k
		for i in 0..=CARD_COUNT {
			// 每个插入位置一个空隙；拖动卡牌悬停处展开，两侧卡座被推开。
			target: f32 = s.drag.card >= 0 && s.drag.moved && s.drag.insert == i ? 1 : 0
			s.gap_open[i] = snap_open(tween.approach(s.gap_open[i], target, 16, s.dt))
			hand_socket(s, "", s.gap_open[i], size, gap)
			if i == CARD_COUNT do break
			entry := s.hand[i]
			s.hand_open[entry] = snap_open(tween.approach(s.hand_open[entry], in_hand(s, entry) ? 1 : 0, 16, s.dt))
			hand_socket(s, HAND_IDS[entry], s.hand_open[entry], size, gap)
		}
	}
	}
}

snap_open :: proc(open: f32) -> f32 {
	return open < 0.002 ? 0 : (open > 0.998 ? 1 : open)
}

// 外层占卡位 + 间距，内层是不可见的卡座（只提供位置）；两者同比例收缩，相邻卡牌随之靠拢或让开。
hand_socket :: proc(s: ^Demo, id: string, open: f32, size: foster.Vec2, gap: f32) {
	if clay.UI()(clay.ElementDeclaration{
		layout = {
			sizing = {width = clay.SizingFixed((size.x + gap) * open), height = clay.SizingFixed(size.y)},
			childAlignment = {x = .Center},
		},
	}) {
		inner := clay.ElementDeclaration{
			layout = {sizing = {width = clay.SizingFixed(size.x * open), height = clay.SizingFixed(size.y)}},
		}
		if id != "" {
			inner.id = clay.ID(id)
		}
		if clay.UI()(inner) {}
	}
}

// 圆角描边：kit/ui 只画圆角填充，不画圆角描边。外层用描边色填充、按描边宽度留内边距，
// 内层再填底色并用略小的半径，叠出圆角边框。
frame_outer :: proc(line: foster.Color, width: clay.Padding, radius: f32) -> clay.ElementDeclaration {
	return {
		layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})}, padding = width},
		backgroundColor = ui.ui_clay_color(line),
		cornerRadius = clay.CornerRadiusAll(radius),
	}
}

// 厚度：最外层只在底部露出 depth 像素的深色，像略微俯视时看到的卡片侧面。
frame_side :: proc(face: foster.Color, depth: u16, radius: f32) -> clay.ElementDeclaration {
	return {
		layout = {padding = {bottom = depth}},
		backgroundColor = ui.ui_clay_color(darken(face, 0.45)),
		cornerRadius = clay.CornerRadiusAll(radius),
	}
}

darken :: proc(c: foster.Color, amount: f32) -> foster.Color {
	return lerp_color(c, {0, 0, 0, c.A}, amount)
}

frame_inner :: proc(fill: foster.Color, radius: f32) -> clay.ElementDeclaration {
	return {
		layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})}},
		backgroundColor = ui.ui_clay_color(fill),
		cornerRadius = clay.CornerRadiusAll(radius),
	}
}

lerp_color :: proc(a, b: foster.Color, t: f32) -> foster.Color {
	mix :: proc(x, y: u8, t: f32) -> u8 {
		return u8(f32(x) + (f32(y) - f32(x)) * clamp(t, 0, 1))
	}
	return {mix(a.R, b.R, t), mix(a.G, b.G, t), mix(a.B, b.B, t), mix(a.A, b.A, t)}
}

// ==============================================================================
// 卡牌 —— Root 浮动元素；按下开始拖动，移动超过阈值才算拖，否则视为点击
// ==============================================================================

card :: proc(s: ^Demo, index: int) {
	if !s.rects_ready do return
	id := CARD_IDS[index]
	state := ui.ui_interact(&s.ctx, id, {disabled = s.playing})
	pointer := foster.Vec2{s.ctx.pointer_x, s.ctx.pointer_y}
	if state.pressed && s.drag.card < 0 {
		s.drag = DRAG_NONE
		s.drag.card = index
		s.drag.grab = pointer - s.cards[index].pos
		s.drag.start = pointer
	}
	if s.drag.card == index {
		if state.active {
			if !s.drag.moved && linalg.length(pointer - s.drag.start) > 5 {
				s.drag.moved = true
			}
		} else if s.ctx.navigation.cancel {
			// Esc：放弃这次拖动，飞回原来的位置。
			s.cards[index].flying = true
			s.drag = DRAG_NONE
		} else {
			drop(s, index)
		}
	} else if state.clicked {
		toggle(s, index)
	}
	card_step(s, index, pointer, state.hovered && !s.playing, s.dt)

	c := &s.cards[index]
	z: i16 = s.drag.card == index ? 40 : (c.flying ? 30 : 20)
	visual := card_visual(c^)
	ui.ui_set_visual(&s.ctx, id, visual)
	shadow := visual
	shadow.offset += foster.Vec2{4, 6} + foster.Vec2{8, 14} * c.lift
	ui.ui_set_visual(&s.ctx, SHADOW_IDS[index], shadow)
	if clay.UI()(clay.ElementDeclaration{
		id = clay.ID(SHADOW_IDS[index]),
		layout = {sizing = {width = clay.SizingFixed(s.card_size.x), height = clay.SizingFixed(s.card_size.y)}},
		backgroundColor = {0, 0, 0, 0.28 + 0.14 * c.lift},
		cornerRadius = clay.CornerRadiusAll(12 * s.card_size.x / 124),
		floating = {attachTo = .Root, offset = {c.pos.x, c.pos.y}, zIndex = z - 1, pointerCaptureMode = .Passthrough},
	}) {}

	k := s.card_size.x / 124
	names := [Card_Kind]string{.Attack = "ATTACK", .Relic = "RELIC", .Gate = "GATE", .Guard = "GUARD"}
	verbs := [Card_Kind]string{.Attack = "出击", .Relic = "拾取", .Gate = "打开", .Guard = "结界"}
	powers := [Card_Kind]string{.Attack = "2", .Relic = "1", .Gate = "3", .Guard = "1"}
	colors := [Card_Kind]foster.Color{
		.Attack = RED, .Relic = {44, 78, 70, 255}, .Gate = {70, 58, 44, 255}, .Guard = {50, 60, 76, 255},
	}
	border := state.focused || s.drag.card == index ? GOLD : foster.Color{206, 190, 160, 255}
	side := frame_side(colors[c.kind], u16(max(3, 5 * k)), 12 * k)
	side.id = clay.ID(id)
	side.layout.sizing = {width = clay.SizingFixed(s.card_size.x), height = clay.SizingFixed(s.card_size.y)}
	side.floating = {attachTo = .Root, offset = {c.pos.x, c.pos.y}, zIndex = z, pointerCaptureMode = .Capture}
	ui.ui_motion(&s.ctx, POP_IDS[index], ui.UI_VISUAL_DEFAULT, MOTION_POP)
	outer := frame_outer(border, {2, 2, 2, 2}, 12 * k)
	outer.id = clay.ID(POP_IDS[index])
	inner := frame_inner(colors[c.kind], 10 * k)
	inner.layout.layoutDirection = .TopToBottom
	// 外框内边距会占布局（Clay 描边不占），内容收紧，避免溢出盖住底边。
	inner.layout.padding = {u16(8 * k), u16(8 * k), u16(4 * k), u16(4 * k)}
	inner.layout.childGap = u16(2 * k)
	inner.layout.childAlignment = {x = .Center, y = .Center}
	if clay.UI()(side) do if clay.UI()(outer) do if clay.UI()(inner) {
		ui.ui_label_ex(&s.ctx, &s.theme, names[c.kind], GOLD, font_size(14, k))
		sub := foster.SubtextureMake(&s.icons, {f32(int(c.kind) * 96), 0, 96, 96}, {0, 0, 96, 96})
		ui.ui_image(&s.ctx, sub, 78 * k, 78 * k)
		ui.ui_label_ex(&s.ctx, &s.theme, powers[c.kind], PAPER, font_size(28, k))
		ui.ui_label_ex(&s.ctx, &s.theme, verbs[c.kind], PAPER, font_size(14, k))
	}
}

// ==============================================================================
// 模态窗口 —— ui_presence 管进出场；退场中继续显示但不再接受输入
// ==============================================================================

modal :: proc(s: ^Demo) {
	alive, t := ui.ui_presence(&s.ctx, "reward-modal", s.modal_open, MODAL_ENTER, MODAL_EXIT)
	if !alive do return
	ui.ui_set_scope(&s.ctx, "reward-modal")
	defer ui.ui_set_scope(&s.ctx, "")
	decl := ui.ui_modal_decl(&s.ctx, "reward-modal")
	decl.backgroundColor = {0.04, 0.04, 0.05, 0.84 * clamp(t, 0, 1)}
	if clay.UI()(decl) {
		hidden := s.modal_open ? MODAL_HIDDEN_IN : MODAL_HIDDEN_OUT
		ui.ui_set_visual(&s.ctx, "reward-panel", ui.ui_visual_lerp(hidden, ui.UI_VISUAL_DEFAULT, t))
		side := frame_side(GOLD, 5, 16)
		side.id = clay.ID("reward-panel")
		outer := frame_outer(GOLD, {2, 2, 2, 2}, 16)
		panel := ui.ui_panel_decl(&s.theme, width = min(440, s.ctx.width - 60), gap = 18)
		panel.layout.padding = clay.PaddingAll(28)
		panel.layout.childAlignment.x = .Center
		panel.backgroundColor = ui.ui_clay_color({48, 45, 42, 255})
		panel.cornerRadius = clay.CornerRadiusAll(14)
		panel.border = {}
		if clay.UI()(side) do if clay.UI()(outer) do if clay.UI()(panel) {
			ui.ui_label_ex(&s.ctx, &s.theme, "A MOMENT OF VICTORY", GOLD, 16)
			ui.ui_image(&s.ctx, foster.SubtextureMake(&s.icons, {96, 0, 96, 96}, {0, 0, 96, 96}), 96, 96)
			ui.ui_heading(&s.ctx, &s.theme, "获得新的力量")
			ui.ui_label_ex(&s.ctx, &s.theme, "Ready for the next encounter.", MUTED, 16)
			if ui.ui_button(&s.ctx, &s.theme, "close", "CONTINUE / 继续") {
				s.modal_open = false
			}
		}
	}
}

// ==============================================================================
// 原创像素图标 —— 刀、玉石、门、盾；无外部图片依赖
// ==============================================================================

make_icons :: proc(device: ^foster.GraphicsDevice) -> foster.Texture {
	image := foster.ImageMake(128, 32)
	defer foster.ImageDispose(&image)
	for y in 0..<32 {
		for x in 0..<32 {
			// 斜刀与护手。
			if x >= 9 && x <= 24 && abs((31 - y) - x) <= 1 {
				foster.ImageSetPixel(&image, x, y, PAPER)
			}
			if x >= 6 && x <= 13 && abs(y - x - 12) <= 1 {
				foster.ImageSetPixel(&image, x, y, GOLD)
			}
			if x >= 4 && x <= 9 && abs((31 - y) - x) <= 1 {
				foster.ImageSetPixel(&image, x, y, GOLD)
			}
			// 菱形玉石，左右明暗区分。
			if abs(x - 16) * 2 + abs(y - 15) <= 14 {
				foster.ImageSetPixel(&image, x + 32, y, x <= 15 ? foster.Color{135, 189, 164, 255} : foster.Color{67, 121, 113, 255})
			}
			if y == 28 && x >= 9 && x <= 23 {
				foster.ImageSetPixel(&image, x + 32, y, GOLD)
			}
			// 门框和两层屋檐。
			if ((x == 10 || x == 11 || x == 21 || x == 22) && y >= 10 && y <= 27) ||
				(y >= 7 && y <= 9 && x >= 5 && x <= 27) ||
				(y == 14 && x >= 8 && x <= 24) {
				foster.ImageSetPixel(&image, x + 64, y, GOLD)
			}
			// 盾：上方方肩，下方收成尖；中线描金。
			half := y <= 17 ? 11 : 11 - (y - 17)
			if y >= 5 && half >= 0 && abs(x - 16) <= half {
				edge := abs(x - 16) >= half - 1 || y <= 6
				color := edge ? PAPER : (x <= 15 ? foster.Color{120, 140, 168, 255} : foster.Color{78, 94, 122, 255})
				if x == 16 && !edge {
					color = GOLD
				}
				foster.ImageSetPixel(&image, x + 96, y, color)
			}
		}
	}
	// 按显示尺寸生成像素块；最终 UI 不再放大低分辨率图标。
	full := foster.ImageMake(384, 96)
	defer foster.ImageDispose(&full)
	for y in 0..<96 {
		for x in 0..<384 {
			full.Pixels[y * 384 + x] = image.Pixels[(y / 3) * 128 + x / 3]
		}
	}
	return foster.TextureFromImage(device, &full, "motion study icons")
}
