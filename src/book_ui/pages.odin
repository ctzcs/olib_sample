package main

// 页面内容与屏幕控制栏。每页是普通的 PAGE_W x PAGE_H 的 kit/ui 布局，
// 这里完全不知道页面最后会贴到 3D 纸上。

// 分区：
//   页面 —— build_page 与六页内容
//   插图 —— illustration_space / draw_sigil / draw_satchel / draw_map
//   屏幕控制栏 —— build_overlay
//   主题 —— paper_theme_make / chrome_theme_make

import "core:fmt"
import ui "olib:kit/ui"
import foster "olib:foster"
import r2d "olib:kit/rendering/2d"
import clay "olib:thirdparty/clay"

PAPER_COLOR :: foster.Color{240, 231, 202, 255}

// ==============================================================================
// 页面
// ==============================================================================

build_page :: proc(world: ^World, app: ^foster.App, index: int) {
	page := &world.pages[index]
	ctx, theme := &page.ctx, &world.paper_theme
	ui.ui_begin(ctx, app.Time.Delta)
	root := ui.ui_column_decl(12)
	root.id = clay.ID("paper")
	root.layout.sizing = {width = clay.SizingFixed(PAGE_W), height = clay.SizingFixed(PAGE_H)}
	root.layout.padding = {left = 30, right = 30, top = 26, bottom = 22}
	if clay.UI()(root) {
		if clay.UI()(ui.ui_row_decl(8)) {
			ui.ui_label_dim(ctx, theme, "THE FIELD GRIMOIRE")
			ui.ui_spacer()
			ui.ui_label_dim(ctx, theme, fmt.tprintf("%02d", index + 1))
		}
		ui.ui_separator(ctx, theme)
		switch index {
		case 0:
			page_arcana(world, ctx, theme)
		case 1:
			page_spells(world, ctx, theme)
		case 2:
			page_provisions(world, ctx, theme)
		case 3:
			page_audio(world, ctx, theme)
		case 4:
			page_journey(world, ctx, theme)
		case 5:
			page_quest(world, ctx, theme)
		}
	}
	ui.ui_draw(ctx, &page.batcher)
	// 插图在控件之后画进预留的布局空白里，位置取自真实布局。
	clay.SetCurrentContext(ctx.clay_context)
	switch index {
	case 0:
		draw_sigil(&page.batcher)
	case 2:
		draw_satchel(&page.batcher)
	case 4:
		draw_map(&page.batcher)
	}
}

page_arcana :: proc(world: ^World, ctx: ^ui.UI_Context, theme: ^ui.UI_Theme) {
	g := &world.grimoire
	ui.ui_label_dim(ctx, theme, "CHAPTER I / ARCANA")
	ui.ui_heading(ctx, theme, "A traveller's notes")
	ui.ui_label(ctx, theme, "A little magic for the long road. Choose a spell on the facing page and try it.")
	illustration_space(130, "sigil")
	ui.ui_label_dim(ctx, theme, "Ink, paper, and a spark of curiosity.")
	ui.ui_separator(ctx, theme)
	label := g.chapter_bookmarked ? "Remove bookmark" : "Bookmark chapter"
	if ui.ui_button_ex(ctx, theme, "bookmark", label, .Primary) {
		g.chapter_bookmarked = !g.chapter_bookmarked
		world.status = g.chapter_bookmarked ? "Chapter I bookmarked." : "Bookmark removed."
	}
	ui.ui_label_dim(ctx, theme, "Click the controls printed on the paper.")
}

SPELL_NAMES :: [3]string{"01  /  Ember lantern", "02  /  Forest ward", "03  /  Tidal step"}
SPELL_DESCRIPTIONS :: [3]string{
	"A warm light that never burns out.",
	"A quiet shield woven from leaves.",
	"Cross a stream with a single step.",
}

page_spells :: proc(world: ^World, ctx: ^ui.UI_Context, theme: ^ui.UI_Theme) {
	g := &world.grimoire
	ui.ui_label_dim(ctx, theme, "SPELL INDEX / THREE ENTRIES")
	ui.ui_heading(ctx, theme, "Prepared spells")
	for name, i in SPELL_NAMES {
		style: ui.UI_Button_Style = g.selected_spell == i ? .Primary : .Normal
		if ui.ui_button_ex(ctx, theme, fmt.tprintf("spell-%d", i), name, style) {
			g.selected_spell = i
			world.status = "Spell selected. Press Cast spell to try it."
		}
	}
	ui.ui_separator(ctx, theme)
	descriptions := SPELL_DESCRIPTIONS
	ui.ui_label(ctx, theme, descriptions[g.selected_spell])
	ui.ui_progress_bar(ctx, theme, f32(g.selected_spell + 1) / 4, 290)
	if ui.ui_button_ex(ctx, theme, "cast", "Cast spell", .Primary) {
		g.casts += 1
		world.status = "A spell was cast from the page."
	}
	ui.ui_label_dim(ctx, theme, fmt.tprintf("Spells cast: %d", g.casts))
}

page_provisions :: proc(world: ^World, ctx: ^ui.UI_Context, theme: ^ui.UI_Theme) {
	g := &world.grimoire
	ui.ui_label_dim(ctx, theme, "CHAPTER II / PROVISIONS")
	ui.ui_heading(ctx, theme, "The satchel")
	ui.ui_label(ctx, theme, "Enough supplies for one more expedition. All changes survive a page turn.")
	illustration_space(108, "satchel")
	ui.ui_separator(ctx, theme)
	ui.ui_label(ctx, theme, fmt.tprintf("Healing draughts: %d / 5", 5 - g.potions))
	if ui.ui_button_ex(ctx, theme, "potion", "Drink a draught", .Primary, {disabled = g.potions >= 5}) {
		g.potions += 1
		world.status = "One healing draught used."
	}
	ui.ui_label_dim(ctx, theme, "A real button, drawn into the page texture.")
}

page_audio :: proc(world: ^World, ctx: ^ui.UI_Context, theme: ^ui.UI_Theme) {
	g := &world.grimoire
	ui.ui_label_dim(ctx, theme, "CAMP / AUDIO")
	ui.ui_heading(ctx, theme, "Quiet moments")
	ui.ui_label(ctx, theme, "Page controls use the same UI widgets as the rest of the game.")
	ui.ui_separator(ctx, theme)
	if clay.UI()(ui.ui_row_decl(16)) {
		ui.ui_label(ctx, theme, "Camp music")
		ui.ui_spacer()
		ui.ui_toggle(ctx, theme, "music", &g.music)
	}
	ui.ui_label(ctx, theme, fmt.tprintf("Volume  /  %d%%", int(g.volume * 100)))
	ui.ui_slider(ctx, theme, "volume", &g.volume, width = 290)
	ui.ui_label_dim(ctx, theme, "Drag the thumb directly on the tilted page.")
	ui.ui_separator(ctx, theme)
	if ui.ui_button(ctx, theme, "reset-audio", "Reset audio") {
		g.music = true
		g.volume = 0.65
		world.status = "Audio settings restored."
	}
	ui.ui_label_dim(ctx, theme, g.music ? "Camp music is enabled." : "Camp music is muted.")
}

page_journey :: proc(world: ^World, ctx: ^ui.UI_Context, theme: ^ui.UI_Theme) {
	g := &world.grimoire
	ui.ui_label_dim(ctx, theme, "CHAPTER III / THE JOURNEY")
	ui.ui_heading(ctx, theme, "A map of the wild")
	ui.ui_label(ctx, theme, "Follow the river north. There is an old observatory beyond the pines.")
	illustration_space(160, "map")
	ui.ui_separator(ctx, theme)
	label := g.route_marked ? "Remove map marker" : "Mark this route"
	if ui.ui_button_ex(ctx, theme, "bookmark-map", label, .Primary) {
		g.route_marked = !g.route_marked
		world.status = g.route_marked ? "The northern route is marked." : "Route marker removed."
	}
}

page_quest :: proc(world: ^World, ctx: ^ui.UI_Context, theme: ^ui.UI_Theme) {
	g := &world.grimoire
	ui.ui_label_dim(ctx, theme, "QUEST LOG / THE OBSERVATORY")
	ui.ui_heading(ctx, theme, "Among the stars")
	ui.ui_label(ctx, theme, "Find the keeper's missing lens and bring the night sky back into focus.")
	ui.ui_separator(ctx, theme)
	ui.ui_label(ctx, theme, "Destination: northern observatory")
	ui.ui_label(ctx, theme, "Reward: a new constellation")
	label := g.quest_accepted ? "Quest accepted" : "Accept the quest"
	if ui.ui_button_ex(ctx, theme, "quest", label, .Primary, {disabled = g.quest_accepted}) {
		g.quest_accepted = true
		world.status = "Quest accepted: Among the stars."
	}
	ui.ui_progress_bar(ctx, theme, g.quest_accepted ? 0.25 : 0, 290)
	hint := g.quest_accepted ? "Step 1 / Reach the observatory" : "Your next adventure waits here."
	ui.ui_label_dim(ctx, theme, hint)
	ui.ui_separator(ctx, theme)
	ui.ui_label_dim(ctx, theme, "Use Previous to return to your notes.")
}

// ==============================================================================
// 插图
// ==============================================================================

// 空的布局块，之后把插图画进它的边界。
illustration_space :: proc(height: f32, id: string) {
	decl := ui.ui_column_decl(0)
	decl.id = clay.ID(id)
	decl.layout.sizing.height = clay.SizingFixed(height)
	if clay.UI()(decl) {}
}

draw_sigil :: proc(batch: ^r2d.Render2D) {
	box := clay.GetElementData(clay.ID("sigil")).boundingBox
	p := foster.Vec2{box.x + box.width * 0.5, box.y + box.height * 0.5}
	ink := foster.Color{88, 121, 95, 255}
	r2d.circle_line(batch, p, 54, 1.5, 48, ink)
	r2d.circle_line(batch, p, 45, 1, 48, {165, 151, 105, 255})
	top, right := p + foster.Vec2{0, -38}, p + foster.Vec2{22, 0}
	bottom, left := p + foster.Vec2{0, 38}, p + foster.Vec2{-22, 0}
	r2d.quad(batch, top, right, bottom, left, ink)
	r2d.circle(batch, p, 11, 24, PAPER_COLOR)
	r2d.circle(batch, p, 5, 16, {179, 135, 68, 255})
}

draw_satchel :: proc(batch: ^r2d.Render2D) {
	box := clay.GetElementData(clay.ID("satchel")).boundingBox
	x, y := box.x + box.width * 0.5 - 34, box.y + 18
	r2d.rect(batch, {x, y, 68, 70}, {133, 113, 78, 255})
	r2d.rect(batch, {x - 5, y, 78, 26}, {102, 94, 68, 255})
	r2d.rect(batch, {x + 27, y + 13, 14, 30}, {189, 159, 93, 255})
	r2d.circle_line(batch, {x + 34, y - 1}, 17, 4, 24, {102, 94, 68, 255})
}

draw_map :: proc(batch: ^r2d.Render2D) {
	box := clay.GetElementData(clay.ID("map")).boundingBox
	ink := foster.Color{92, 127, 107, 255}
	water := foster.Color{102, 149, 160, 255}
	brass := foster.Color{160, 110, 65, 255}
	// 松树
	for i in 0..<7 {
		x, y := box.x + 25 + f32(i) * 38, box.y + 25 + f32(i % 3) * 30
		r2d.triangle(batch, {x, y}, {x - 11, y + 22}, {x + 11, y + 22}, ink)
	}
	// 河流：上下交替的折线
	for i in 0..<5 {
		x := box.x + 75 + f32(i) * 32
		y0 := box.y + 100 - f32(i % 2) * 14
		y1 := box.y + 100 - f32((i + 1) % 2) * 14
		r2d.line(batch, {x, y0}, {x + 32, y1}, 3, water)
	}
	// 天文台
	r2d.circle_line(batch, {box.x + 242, box.y + 37}, 12, 2, 24, brass)
	r2d.line(batch, {box.x + 242, box.y + 18}, {box.x + 242, box.y + 56}, 1, brass)
}

// ==============================================================================
// 屏幕控制栏
// ==============================================================================

// 平铺在书上方的屏幕空间控件。
build_overlay :: proc(world: ^World, app: ^foster.App, w, h: f32) {
	ctx, theme := &world.overlay, &world.chrome_theme
	ui.ui_set_viewport(ctx, {0, 0, w, h})
	ui.ui_set_pointer(ctx, world.pointer.x, world.pointer.y, world.pointer_down)
	ui.ui_begin(ctx, app.Time.Delta)
	root := ui.ui_column_decl(8)
	root.layout.padding = {left = 36, right = 36, top = 24, bottom = 24}
	root.layout.sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})}
	turning := world.turn.direction != 0
	spread := world.spread
	if clay.UI()(root) {
		ui.ui_label_ex(ctx, theme, "THE FIELD GRIMOIRE", {229, 220, 190, 255}, 28)
		ui.ui_label_dim(
			ctx,
			theme,
			"A living book / Click the paper / Left & Right: turn / Space: pause / Tab & Enter: page controls",
		)
		ui.ui_label_dim(
			ctx,
			theme,
			"Right drag: rotate / Shift + right drag: roll / Middle drag: move / Wheel: depth / R: reset view",
		)
		// Fill the middle with a non-interactive layout spacer.
		spacer := clay.ElementDeclaration{
			layout = {sizing = {width = clay.SizingFixed(1), height = clay.SizingGrow({})}},
		}
		if clay.UI()(spacer) {}
		ui.ui_label_ex(ctx, theme, world.status, {190, 203, 193, 255}, 15)
		if clay.UI()(ui.ui_row_decl(14)) {
			at_first, at_last := spread == 0, spread == SPREAD_COUNT - 1
			if ui.ui_button(ctx, theme, "previous", "< Previous", {disabled = at_first || turning}) {
				begin_turn(world, -1)
			}
			first, second := left_page(spread) + 1, right_page(spread) + 1
			ui.ui_label(ctx, theme, fmt.tprintf("%02d - %02d / %02d", first, second, PAGE_COUNT))
			if ui.ui_button_ex(ctx, theme, "next", "Next >", .Primary, {disabled = at_last || turning}) {
				begin_turn(world, 1)
			}
			ui.ui_spacer()
			if ui.ui_button(ctx, theme, "reset-view", "Reset view") {
				reset_pose(world)
			}
			if ui.ui_button(ctx, theme, "pause", world.turn.paused ? "Resume" : "Pause") {
				world.turn.paused = !world.turn.paused
			}
			ui.ui_label_dim(ctx, theme, "Turn duration")
			ui.ui_slider(ctx, theme, "duration", &world.turn.seconds, 0.5, 2, width = 130)
		}
		hint := "3D perspective + depth / mouse ray mapped to Clay UI"
		if turning {
			hint = "Turning leaf / page input locked until landing"
		}
		ui.ui_label_dim(ctx, theme, hint)
	}
	ui.ui_draw(ctx, &world.overlay_batch)
}

// ==============================================================================
// 主题
// ==============================================================================

// 纸面主题：米黄纸、墨绿强调色。
paper_theme_make :: proc() -> ui.UI_Theme {
	t := ui.UI_THEME_DARK
	t.panel = {226, 216, 186, 255}
	t.panel_border = {180, 165, 127, 255}
	t.text = {48, 55, 46, 255}
	t.text_dim = {116, 115, 93, 255}
	t.button = {213, 204, 174, 255}
	t.button_hover = {196, 191, 157, 255}
	t.button_press = {184, 181, 149, 255}
	t.primary = {47, 103, 88, 255}
	t.primary_hover = {57, 122, 102, 255}
	t.primary_press = {39, 85, 74, 255}
	t.accent = t.primary
	t.text_on_accent = {245, 239, 214, 255}
	t.body_font_size = 16
	t.heading_font_size = 30
	t.small_font_size = 12
	t.padding = 10
	t.corner_radius = 3
	return t
}

// 屏幕控制栏主题：深色底，强调色与纸面一致。
chrome_theme_make :: proc() -> ui.UI_Theme {
	t := ui.UI_THEME_DARK
	t.primary = {47, 103, 88, 255}
	t.primary_hover = {57, 122, 102, 255}
	t.accent = {119, 193, 162, 255}
	return t
}
