package main

import "core:fmt"

import foster "olib:foster"
import ui "olib:kit/ui"
import clay "olib:thirdparty/clay-odin"

// 分区：配色与声明 / 动作卡片 / 模态窗口 / 原创像素图标

INK :: foster.Color{24, 26, 30, 255}
PAPER :: foster.Color{237, 222, 191, 255}
MUTED :: foster.Color{163, 156, 139, 255}
GOLD :: foster.Color{219, 175, 89, 255}
RED :: foster.Color{147, 53, 43, 255}

// ==============================================================================
// 配色与声明
// ==============================================================================

declare_ui :: proc(s: ^Demo) {
	headings := [3]string{"01 / REBOUND", "02 / JUMP", "03 / REVEAL"}
	captions := [3]string{"按下蓄力 / 松开回弹", "起跳 / 倾斜 / 落地", "快速出现 / 轻轻收稳"}
	compact := s.ctx.height < 660
	root := ui.ui_column_decl(compact ? 12 : 20)
	root.layout.sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})}
	root.layout.padding = clay.PaddingAll(24)
	if clay.UI()(root) {
		ui.ui_label_ex(&s.ctx, &s.theme, "MOTION STUDY   /   01", GOLD, 14)
		ui.ui_label_ex(&s.ctx, &s.theme, "A little weight. A little life.", PAPER,
			s.ctx.width < 700 ? 27 : 38)
		ui.ui_label_ex(&s.ctx, &s.theme, "点击卡片，感受短促的回弹、跳跃与入场", MUTED, 16)
		spacer(compact ? 8 : 28)
		row := ui.ui_row_decl(16)
		row.layout.sizing.width = clay.SizingGrow({})
		if clay.UI()(row) {
			for index in 0..<3 {
				column := ui.ui_column_decl(20)
				column.layout.sizing.width = clay.SizingFixed((s.ctx.width - 80) / 3)
				column.layout.childAlignment.x = .Center
				if clay.UI()(column) {
					ui.ui_label_ex(&s.ctx, &s.theme,
						headings[index], MUTED, 14)
					tile(s, index)
					ui.ui_label_ex(&s.ctx, &s.theme,
						captions[index], MUTED, 14)
				}
			}
		}
		spacer(compact ? 4 : 16)
		ui.ui_label_ex(&s.ctx, &s.theme,
			fmt.tprintf("ATTACKS  %02d     /     RELICS  %02d", s.attacks, s.rewards), GOLD, 18)
		ui.ui_label_ex(&s.ctx, &s.theme, "Tab 选择   Enter 确认   Esc 关闭弹窗", MUTED, 14)
	}
	// 以本帧已设置的模态 ID 声明，避免打开同帧显示与输入隔离错位。
	if s.ctx.modal_id != 0 {
		modal(s)
	}
}

spacer :: proc(height: f32) {
	if clay.UI()(clay.ElementDeclaration{
		layout = {sizing = {height = clay.SizingFixed(height)}},
	}) {}
}

// ==============================================================================
// 动作卡片 —— 背景、图标、文字、边框属于同一个动画子树
// ==============================================================================

tile :: proc(s: ^Demo, index: int) {
	ids := [3]string{"attack", "item", "open"}
	numbers := [3]string{"I", "II", "III"}
	labels := [3]string{"ATTACK", "RELIC", "REWARD"}
	verbs := [3]string{"出击", "拾取", "打开"}
	id := ids[index]
	state := ui.ui_interact(&s.ctx, id)
	tile_feedback(s, index, state)
	ui.ui_set_visual(&s.ctx, id, s.tiles[index].visual)
	border := state.hovered || state.focused ? GOLD : foster.Color{95, 87, 72, 255}
	bg := index == 0 ? RED : foster.Color{43, 45, 47, 255}
	if state.active {
		bg = {80, 42, 36, 255}
	}
	if clay.UI()(clay.ElementDeclaration{
		id = clay.ID(id),
		layout = {
			sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(s.ctx.height < 660 ? 200 : 240)},
			layoutDirection = .TopToBottom,
			padding = clay.PaddingAll(14), childGap = s.ctx.height < 660 ? 8 : 14,
			childAlignment = {x = .Center, y = .Center},
		},
		backgroundColor = ui.ui_clay_color(bg),
		border = {color = ui.ui_clay_color(border), width = {left = 2, right = 2, top = 2, bottom = 4}},
	}) {
		ui.ui_label_ex(&s.ctx, &s.theme, numbers[index], GOLD, 16)
		sub := foster.SubtextureMake(&s.icons, {f32(index * 96), 0, 96, 96}, {0, 0, 96, 96})
		ui.ui_image(&s.ctx, sub, 96, 96)
		ui.ui_label_ex(&s.ctx, &s.theme, labels[index], PAPER, 22)
		ui.ui_label_ex(&s.ctx, &s.theme, verbs[index], PAPER, 16)
	}
}

// ==============================================================================
// 模态窗口 —— 退场完成前继续声明并阻挡背景输入
// ==============================================================================

modal :: proc(s: ^Demo) {
	ui.ui_set_scope(&s.ctx, "reward-modal")
	defer ui.ui_set_scope(&s.ctx, "")
	decl := ui.ui_modal_decl(&s.ctx, "reward-modal")
	decl.backgroundColor = {0.04, 0.04, 0.05, 0.84 * s.modal.visual.opacity}
	if clay.UI()(decl) {
		ui.ui_set_visual(&s.ctx, "reward-panel", s.modal.visual)
		panel := ui.ui_panel_decl(&s.theme, width = min(440, s.ctx.width - 60), gap = 18)
		panel.id = clay.ID("reward-panel")
		panel.layout.padding = clay.PaddingAll(28)
		panel.layout.childAlignment.x = .Center
		panel.backgroundColor = ui.ui_clay_color({48, 45, 42, 255})
		panel.cornerRadius = {}
		panel.border = {color = ui.ui_clay_color(GOLD), width = {left = 2, right = 2, top = 2, bottom = 5}}
		if clay.UI()(panel) {
			ui.ui_label_ex(&s.ctx, &s.theme, "A MOMENT OF VICTORY", GOLD, 16)
			ui.ui_image(&s.ctx, foster.SubtextureMake(&s.icons, {96, 0, 96, 96}, {0, 0, 96, 96}), 96, 96)
			ui.ui_heading(&s.ctx, &s.theme, "获得新的力量")
			ui.ui_label_ex(&s.ctx, &s.theme, "Ready for the next encounter.", MUTED, 16)
			if ui.ui_button(&s.ctx, &s.theme, "close", "CONTINUE / 继续", {disabled = s.modal_closing}) {
				close_modal(s)
			}
		}
	}
}

// ==============================================================================
// 原创像素图标 —— 刀、玉石、门；无外部图片依赖
// ==============================================================================

make_icons :: proc(device: ^foster.GraphicsDevice) -> foster.Texture {
	image := foster.ImageMake(96, 32)
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
		}
	}
	// 按显示尺寸生成像素块；最终 UI 不再放大低分辨率图标。
	full := foster.ImageMake(288, 96)
	defer foster.ImageDispose(&full)
	for y in 0..<96 {
		for x in 0..<288 {
			full.Pixels[y * 288 + x] = image.Pixels[(y / 3) * 96 + x / 3]
		}
	}
	return foster.TextureFromImage(device, &full, "motion study icons")
}
