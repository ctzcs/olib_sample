package view

import "core:fmt"
import "core:math"

import foster "olib:foster"
import ui "olib:kit/ui"
import clay "olib:thirdparty/clay-odin"

import "../data"
import "../def"

// 分区：可热修改的外观 / 私有 UI 生命周期 / 布局与只读表现。
// 演示：改标题、侧栏宽度或颜色后保存，下一版会重建 UI，保留游戏快照。
PANEL_WIDTH :: f32(300)
ACCENT :: foster.Color{100, 229, 185, 255}
TITLE :: "COLLECTOR"

View :: struct {
	ctx: ui.UI_Context,
	batcher: foster.Batcher,
	theme: ui.UI_Theme,
	field: foster.Rect,
	panel_width: f32,
}

init :: proc(v: ^View, device: ^foster.GraphicsDevice, font: ^foster.MsdfFont,
	texture: foster.Texture) -> bool {
	if !ui.ui_init(&v.ctx, 1280, 800) do return false
	foster.BatcherInit(&v.batcher, device, "live collector UI and scene")
	font_id := ui.ui_register_font(&v.ctx, font, texture, .MSDF)
	v.theme = ui.UI_THEME_DARK
	v.theme.body_font_id = u16(font_id)
	v.theme.body_font_size = 16
	v.theme.small_font_size = 13
	v.theme.heading_font_size = 24
	v.theme.panel = {25, 35, 46, 255}
	v.theme.text = {228, 237, 240, 255}
	v.theme.text_dim = {150, 170, 180, 255}
	v.theme.accent = ACCENT
	v.theme.primary = ACCENT
	v.theme.primary_hover = {153, 242, 213, 255}
	v.theme.text_on_accent = {12, 32, 31, 255}
	v.theme.padding = 10
	return true
}

dispose :: proc(v: ^View) {
	ui.ui_dispose(&v.ctx)
	foster.BatcherDispose(&v.batcher)
}

// view 只返回命令，游戏入口交给 logic 执行，不直接修改 World。
layout :: proc(v: ^View, w: ^data.World, tuning: def.Tuning, width, height, scale: f32,
	mouse: foster.Vec2, down: bool, wheel: foster.Vec2, navigation: ui.UI_Navigation,
	dt: f32) -> (commands: def.Commands) {
	ctx := &v.ctx
	ui.ui_set_viewport(ctx, {0, 64*scale, width, max(height-64*scale, 1)}, scale)
	compact := ctx.height < 640
	theme := v.theme
	if compact {
		theme.body_font_size = 14
		theme.small_font_size = 12
		theme.padding = 8
	}
	t := &theme
	ui.ui_set_pointer(ctx, mouse.x, mouse.y, down)
	ui.ui_add_scroll(ctx, wheel.x, wheel.y)
	ui.ui_set_navigation(ctx, navigation)
	ui.ui_begin(ctx, dt)
	root := ui.ui_column_decl(compact ? 12 : 18)
	root.layout.padding = clay.PaddingAll(compact ? 16 : 24)
	root.layout.sizing.height = clay.SizingGrow({})
	if clay.UI()(root) {
		if clay.UI()(ui.ui_column_decl(5)) {
			ui.ui_label_ex(ctx, t, "FIELD 01   /   CODE IS LIVE", ACCENT, 13)
			ui.ui_label_ex(ctx, t, TITLE, t.text, compact ? 28 : 36)
			ui.ui_label(ctx, t, "Change the rules. Keep the run.")
		}
		body := ui.ui_row_decl(20)
		body_height := max(ctx.height-(compact ? 184 : 210), 100)
		body.layout.sizing.height = clay.SizingFixed(body_height)
		body.layout.childAlignment.y = .Top
		if clay.UI()(body) {
			field := ui.ui_column_decl(6)
			field.id = clay.ID("field")
			field.layout.sizing.height = clay.SizingGrow({})
			field.layout.padding = clay.PaddingAll(16)
			if clay.UI()(field) {
				ui.ui_label_ex(ctx, t, "THE COLLECTION FIELD", t.text_dim, 13)
				ui.ui_label_dim(ctx, t, "WASD / arrows to move")
			}
			v.panel_width = min(PANEL_WIDTH, ctx.width < 1000 ? 250 : PANEL_WIDTH)
			panel := ui.ui_scroll_decl(ctx, "inspector", body_height, v.panel_width, compact ? 6 : 12)
			panel.layout.padding = clay.PaddingAll(t.padding*2)
			panel.backgroundColor = ui.ui_clay_color(t.panel)
			panel.cornerRadius = clay.CornerRadiusAll(10)
			if clay.UI()(panel) {
				ui.ui_block_pointer(ctx, "inspector")
				ui.ui_label_ex(ctx, t, "YOUR RUN", t.text_dim, 13)
				ui.ui_label_ex(ctx, t, fmt.tprintf("%03d", w.score), ACCENT, compact ? 32 : 46)
				ui.ui_label(ctx, t, "points collected")
				count := 0
				for i in 0..<8 {
					if w.collected & (u32(1)<<u32(i)) != 0 do count += 1
				}
				ui.ui_progress_bar(ctx, t, f32(count)/8, v.panel_width-40, 5)
				ui.ui_label_dim(ctx, t, fmt.tprintf("%d / 8 energy nodes", count))
				if clay.UI()(ui.ui_row_decl(8)) {
					commands.toggle_pause = ui.ui_button_ex(ctx, t, "pause",
						w.paused ? "Resume" : "Pause", .Primary)
					commands.new_run = ui.ui_button(ctx, t, "restart", "New run")
				}
				ui.ui_label_ex(ctx, t, "LIVE RULES", t.text_dim, 13)
				ui.ui_label(ctx, t, fmt.tprintf("Speed      %.0f units/s", tuning.move_speed))
				ui.ui_label(ctx, t, fmt.tprintf("Reward     +%d / node", tuning.pickup_score))
				ui.ui_label_dim(ctx, t, fmt.tprintf("Position   %.0f, %.0f", w.position[0], w.position[1]))
				if compact {
					ui.ui_label_dim(ctx, t, fmt.tprintf("%.1f s  /  %d trail points", w.elapsed, len(w.trail)))
				} else {
					ui.ui_label_dim(ctx, t, fmt.tprintf("Time       %.1f s", w.elapsed))
					ui.ui_label_dim(ctx, t, fmt.tprintf("Trail      %d points", len(w.trail)))
				}
			}
		}
		ui.ui_label_dim(ctx, t, "Save view/ui.odin or logic/rules.odin. Scroll the panel for details.")
	}
	ui.ui_translate_into(ctx, ui.ui_end(ctx), &ctx.ops)
	box := clay.GetElementData(clay.ID("field")).boundingBox
	v.field = {box.x, box.y+60, box.width, max(box.height-60, 1)}
	return
}

draw :: proc(v: ^View, w: ^data.World, target: foster.DrawableTarget) {
	b := &v.batcher
	foster.BatcherClear(b)
	foster.BatcherPushMatrixTRS(b, v.ctx.viewport_origin, {v.ctx.scale, v.ctx.scale}, 0, false)
	draw_field(v, w)
	foster.BatcherPopMatrix(b)
	ui.ui_render(&v.ctx, b, &v.ctx.ops)
	foster.BatcherRender(b, target)
}

@(private)
draw_field :: proc(v: ^View, w: ^data.World) {
	b := &v.batcher
	r := v.field
	fit := min(r.Width/def.WORLD_SIZE[0], r.Height/def.WORLD_SIZE[1])
	origin := foster.Vec2{r.X+(r.Width-def.WORLD_SIZE[0]*fit)/2,
		r.Y+(r.Height-def.WORLD_SIZE[1]*fit)/2}
	foster.BatcherRect(b, {r.X, r.Y-60, r.Width, r.Height+60}, {17, 26, 36, 255})
	for x in 0..=10 {
		foster.BatcherLine(b, origin+foster.Vec2{f32(x)*100*fit, 0},
			origin+foster.Vec2{f32(x)*100*fit, 640*fit}, 1, {30, 43, 54, 255})
	}
	for y in 0..=6 {
		foster.BatcherLine(b, origin+foster.Vec2{0, f32(y)*100*fit},
			origin+foster.Vec2{1000*fit, f32(y)*100*fit}, 1, {30, 43, 54, 255})
	}
	for p, i in w.trail {
		if i == 0 do continue
		a := w.trail[i-1]
		foster.BatcherLine(b, origin+foster.Vec2{a[0]*fit, a[1]*fit},
			origin+foster.Vec2{p[0]*fit, p[1]*fit}, 2, {48, 102, 94, 255})
	}
	for point, i in def.PICKUPS {
		p := origin + foster.Vec2{point[0]*fit, point[1]*fit}
		if w.collected & (u32(1)<<u32(i)) != 0 {
			foster.BatcherCircleLine(b, p, 7, 1, 20, {48, 72, 77, 255})
			continue
		}
		pulse := f32(math.sin(w.elapsed*2+f64(i)))
		foster.BatcherCircleLine(b, p, 13+pulse, 1, 32, {91, 86, 58, 255})
		foster.BatcherCircle(b, p, 5, 20, {249, 206, 103, 255})
	}
	p := origin + foster.Vec2{w.position[0]*fit, w.position[1]*fit}
	foster.BatcherCircleLine(b, p, 17, 1, 40, ACCENT)
	foster.BatcherCircle(b, p, 10, 32, ACCENT)
	foster.BatcherCircle(b, p+foster.Vec2{3, -3}, 2, 16, {238, 255, 248, 255})
}
