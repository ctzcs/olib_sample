package main

// 野外魔导书：一本 3D 书，每一页都是可交互的 kit/ui 界面。
//
// 原理，每帧一遍（见 render）：
//   1. 每页是普通的 2D UI，画进各自 PAGE_W x PAGE_H 的离屏纹理（pages.odin）。
//   2. 书是 3D 的：实心书壳 + 绕书脊弯折的纸，纸面贴上页面纹理
//      （sheet.odin、renderer3d.odin）。
//   3. 鼠标变成一条射线与纸求交，命中点的 UV 换算回页面像素，交给那一页的 UI
//      当指针，于是印在纸上的控件可以点击（picking.odin）。
// 其余：turning.odin 翻页，pose.odin 书的姿态与相机，harness.odin 是 test / shot
// 两种命令行模式。
//
// 状态：可变状态全部在堆分配的 World 里，经 AppSetUserData 挂到 App 上；回调用
// AppGetUserDataAs 取回后显式传给各个 proc。几何与数学函数是纯函数，不碰 World。

// 分区：
//   类型 —— Page / Grimoire / World
//   入口与生命周期 —— main / world_init / startup / shutdown / update
//   每帧渲染 —— render 及其各步骤

import "core:fmt"
import "core:os"
import ui "olib:kit/ui"
import foster "olib:foster"
import mat "olib:kit/rendering/material"
import r2d "olib:kit/rendering/2d"

// ==============================================================================
// 类型
// ==============================================================================

TITLE :: "olib / The field grimoire"
INITIAL_STATUS :: "Choose a spell, mark a page, or turn the leaf."
BACKGROUND_COLOR :: foster.Color{17, 25, 29, 255}
// 鼠标不在某页上时交给该页的指针位置。
OFF_PAGE :: foster.Vec2{-1000, -1000}

Page :: struct {
	ctx:     ui.UI_Context,
	target:  foster.Target, // 页面纹理
	// Each target needs its own GPU vertex/index buffers. Reusing a batcher
	// would overwrite earlier page draws before the frame is submitted.
	batcher: r2d.Render2D,
}

// 读者通过页面控件改变的内容，翻页后保留。
Grimoire :: struct {
	chapter_bookmarked: bool,
	selected_spell:     int,
	casts:              int,
	potions:            int,
	music:              bool,
	volume:             f32,
	route_marked:       bool,
	quest_accepted:     bool,
}

// 所有权：main 用 new 分配、world_init 填默认值，Run 返回后由 main 释放。
// GPU 资源（pages、renderer、batcher、字体）在 startup 创建、shutdown 释放。
// 不嵌入 foster.App：web 下 Run 会把 App 搬到堆上，嵌入的那份即过期。
World :: struct {
	materials: mat.Material_Library,
	opts:          Options,
	harness:       Harness,

	// ---- 书 ----
	pages:         [PAGE_COUNT]Page,
	grimoire:      Grimoire,
	spread:        int, // 当前摊开的跨页，0..<SPREAD_COUNT
	turn:          Turn,
	left_sheet:    Sheet, // 三张纸每帧重建
	right_sheet:   Sheet,
	turning_sheet: Sheet, // 仅在 turn.direction != 0 时有效
	pose:          Book_Pose,
	view:          Book_View, // 由 pose 派生，pose 或窗口尺寸可能变化后立即重建
	drag:          Book_Drag,
	renderer:      Book_Renderer,

	// ---- 屏幕与输入 ----
	overlay:       ui.UI_Context,
	status:        string, // 控制栏上方的提示语
	paper_theme:   ui.UI_Theme,
	chrome_theme:  ui.UI_Theme,
	font:          foster.MsdfFont,
	font_texture:  foster.Texture,
	scene_batch:   r2d.Render2D,
	overlay_batch: r2d.Render2D,
	pointer:       foster.Vec2, // 可绘制区域像素，控制栏、拾取和拖拽共用
	pointer_down:  bool,
	focus_page:    int, // 接收 Tab / Enter 的页
}

// ==============================================================================
// 入口与生命周期
// ==============================================================================

main :: proc() {
	world := new(World)
	world_init(world)
	config := foster.DefaultAppConfig(TITLE, 1180, 860)
	if world.opts.scaled {
		config = foster.DefaultAppConfig(TITLE, 1500, 1050)
	}
	app: foster.App
	foster.InitApp(&app, config)
	foster.AppSetUserData(&app, world)
	app.StartupProc = startup
	app.UpdateProc = update
	app.RenderProc = render
	app.ShutdownProc = shutdown
	foster.Run(&app)
	// Run 在桌面端执行完 shutdown 才返回；这里还要读测试结果，所以 World 由 main
	// 释放而不是在 shutdown 里。本示例用了 core:os，本来就不支持 web 目标。
	failed := world.harness.test_failures > 0
	foster.Dispose(&app)
	free(world)
	if failed do os.exit(1)
}

// 字段默认值（Odin 结构体没有字段默认值）与命令行参数。
world_init :: proc(world: ^World) {
	parse_options(&world.opts)
	if world.opts.back {
		world.spread = 1
	}
	world.turn.seconds = 0.95
	world.grimoire.music = true
	world.grimoire.volume = 0.65
	world.status = INITIAL_STATUS
	world.focus_page = 1
}

startup :: proc(app: ^foster.App) {
	world := foster.AppGetUserDataAs(app, World)
	reset_pose(world)
	apply_start_pose(world)
	device := &app.GraphicsDevice
	world.materials = {device = device}
	for &page in world.pages {
		if !ui.ui_init(&page.ctx, PAGE_W, PAGE_H) {
			abort_startup(world, app, "Page UI init failed")
			return
		}
		foster.TargetInit(&page.target, device, PAGE_W, PAGE_H, "book page UI")
		assert(r2d.init(&page.batcher, &world.materials) == "")
	}
	if !ui.ui_init(&world.overlay, 1180, 860) || !bake_font(world, app) {
		abort_startup(world, app, "Font unavailable. Pass: font <path-to-ttf>")
		return
	}
	for &page in world.pages {
		ui.ui_register_font(&page.ctx, &world.font, world.font_texture)
	}
	ui.ui_register_font(&world.overlay, &world.font, world.font_texture)
	assert(r2d.init(&world.scene_batch, &world.materials) == "")
	assert(r2d.init(&world.overlay_batch, &world.materials) == "")
	if !renderer_init(&world.renderer, app) {
		abort_startup(world, app, "Book 3D renderer requires a Vulkan or D3D12 graphics device")
		return
	}
	world.paper_theme = paper_theme_make()
	world.chrome_theme = chrome_theme_make()
	harness_startup(world, app)
}

abort_startup :: proc(world: ^World, app: ^foster.App, message: string) {
	fmt.eprintln(message)
	world.harness.test_failures += 1
	foster.Exit(app)
}

bake_font :: proc(world: ^World, app: ^foster.App) -> bool {
	candidates := []string{
		world.opts.font_path,
		"C:/Windows/Fonts/segoeui.ttf",
		"C:/Windows/Fonts/arial.ttf",
		"C:/Windows/Fonts/tahoma.ttf",
	}
	for path in candidates {
		if len(path) == 0 do continue
		source := foster.FontLoadFile(path)
		baked, texture, ok := ui.ui_font_bake(&app.GraphicsDevice, &source, 48, label = "grimoire font")
		foster.FontDispose(&source)
		if ok {
			world.font = baked
			world.font_texture = texture
			return true
		}
	}
	return false
}

shutdown :: proc(app: ^foster.App) {
	world := foster.AppGetUserDataAs(app, World)
	renderer_dispose(&world.renderer)
	for &page in world.pages {
		ui.ui_dispose(&page.ctx)
		foster.TargetDispose(&page.target)
		r2d.dispose(&page.batcher)
	}
	ui.ui_dispose(&world.overlay)
	r2d.dispose(&world.scene_batch)
	r2d.dispose(&world.overlay_batch)
	mat.material_library_dispose(&world.materials)
	foster.TextureDispose(&world.font_texture)
	foster.MsdfFontDispose(&world.font)
	harness_shutdown(world)
}

update :: proc(app: ^foster.App) {
	world := foster.AppGetUserDataAs(app, World)
	key := &app.Input.State.Keyboard
	if foster.KeyboardPressed(key, .Escape) {
		foster.Exit(app)
	}
	if world.opts.test do return // 测试脚本在 render 里按固定步长推进翻页
	if foster.KeyboardPressed(key, .Space) {
		world.turn.paused = !world.turn.paused
	}
	if foster.KeyboardPressed(key, .Right) {
		begin_turn(world, 1)
	}
	if foster.KeyboardPressed(key, .Left) {
		begin_turn(world, -1)
	}
	advance_turn(world, app.Time.Delta)
}

// ==============================================================================
// 每帧渲染
// ==============================================================================

render :: proc(app: ^foster.App) {
	world := foster.AppGetUserDataAs(app, World)
	target := foster.DrawableTargetFromWindow(&app.Window)
	w, h := f32(target.WidthInPixels), f32(target.HeightInPixels)
	world.view = book_view(world.pose, w, h)
	if world.opts.test {
		test_step(world)
		advance_turn(world, 1.0 / 60)
		world.view = book_view(world.pose, w, h) // 脚本可能移动了书
	}
	world.left_sheet = make_sheet(PI, 0)
	world.right_sheet = make_sheet(0, 0)
	read_pointer(world, app, w, h)
	if world.opts.test {
		test_pointer(world)
	}

	// ---- 1. 先建屏幕控制栏，它的按钮优先于书拿到指针 ----
	r2d.reset(&world.overlay_batch)
	build_overlay(world, app, w, h)
	over_overlay := ui.ui_input_capture(&world.overlay).pointer

	// ---- 2. 书的姿态与空中的纸；Previous / Next 可能刚刚发起了翻页 ----
	manipulate_book(world, app, over_overlay)
	world.view = book_view(world.pose, w, h)
	if world.turn.direction != 0 {
		world.turning_sheet = turning_sheet_shape(world.turn)
	}

	// ---- 3. 页面 UI，指针经 3D 书转交 ----
	route_pointer_to_pages(world, app, over_overlay)
	for i in 0..<PAGE_COUNT {
		draw_page(world, app, i)
	}

	// ---- 4. 3D 书，再把一切合成到窗口 ----
	render_book3d(world, app, int(w), int(h))
	compose_frame(world, app, target)
	harness_end_frame(world, app)
}

// 鼠标给的是窗口坐标，其余都用可绘制区域像素，开了系统缩放时两者不同。
read_pointer :: proc(world: ^World, app: ^foster.App, w, h: f32) {
	window := foster.Size(&app.Window)
	mouse := app.Input.State.Mouse
	world.pointer = {
		mouse.Position.X * w / f32(max(window.X, 1)),
		mouse.Position.Y * h / f32(max(window.Y, 1)),
	}
	world.pointer_down = foster.MouseDown(&mouse, .Left)
}

// 射线拾取书，把命中点（页面像素）交给那一页的 UI；其余页都拿到 OFF_PAGE，
// 所以同一时刻只有一页会响应。
route_pointer_to_pages :: proc(world: ^World, app: ^foster.App, over_overlay: bool) {
	// 控制栏、翻页、拖书、封底朝向读者时，页面都不接收输入。
	blocked := over_overlay ||
		world.turn.direction != 0 ||
		world.drag.mode != .None ||
		!page_faces_camera(world)
	hit_page := -1
	page_pointer := OFF_PAGE
	if !blocked {
		uv: foster.Vec2
		hit_page, uv = pick_book(world, world.pointer)
		if hit_page >= 0 {
			page_pointer = {uv.x * PAGE_W, uv.y * PAGE_H}
		}
	}
	if hit_page >= 0 && world.pointer_down {
		world.focus_page = hit_page
	}
	for &page, i in world.pages {
		p := i == hit_page ? page_pointer : OFF_PAGE
		ui.ui_set_pointer(&page.ctx, p.x, p.y, world.pointer_down)
		// Keep the physical button edge on hidden pages, preventing held mouse
		// presses from becoming fresh clicks as the pointer crosses the binding.
		if i != hit_page {
			page.ctx.active_id = 0
		}
		if blocked {
			page.ctx.focused_id = 0
		}
		if i == world.focus_page && !blocked {
			ui.ui_set_navigation(&page.ctx, read_navigation(app))
		}
	}
}

read_navigation :: proc(app: ^foster.App) -> ui.UI_Navigation {
	nav: ui.UI_Navigation
	key := &app.Input.State.Keyboard
	if foster.KeyboardPressed(key, .Tab) {
		nav.next = foster.KeyboardDown(key, .LeftShift) ? -1 : 1
	}
	nav.activate = foster.KeyboardPressed(key, .Enter)
	return nav
}

// 布局一页并渲染进它的纹理。
draw_page :: proc(world: ^World, app: ^foster.App, index: int) {
	page := &world.pages[index]
	r2d.reset(&page.batcher)
	build_page(world, app, index)
	offscreen := foster.DrawableTargetFromTarget(&page.target)
	foster.GraphicsDeviceClear(&app.GraphicsDevice, offscreen, PAPER_COLOR)
	r2d.submit(&page.batcher, {target = offscreen})
}

// 背景斜线，再把 3D 结果（在 renderer.target 里，因为要深度缓冲）作为全屏四边形
// 画上去，最上面是控制栏。
compose_frame :: proc(world: ^World, app: ^foster.App, target: foster.DrawableTarget) {
	w, h := f32(target.WidthInPixels), f32(target.HeightInPixels)
	batch := &world.scene_batch
	r2d.reset(batch)
	for i in 0..<20 {
		y := f32(i) * h / 20
		r2d.line(batch, {0, y}, {w, y + 45}, 1, {27, 35, 38, 255})
	}
	r2d.push_sampler(batch, foster.TextureSamplerMake(.Linear, .Clamp))
	r2d.quad_texture(
		batch,
		foster.TargetAttachment(&world.renderer.target),
		{0, 0}, {w, 0}, {w, h}, {0, h},
		{0, 0}, {1, 0}, {1, 1}, {0, 1},
		foster.White,
	)
	r2d.pop_sampler(batch)
	foster.GraphicsDeviceClear(&app.GraphicsDevice, target, BACKGROUND_COLOR)
	r2d.submit(batch, {target = target})
	r2d.submit(&world.overlay_batch, {target = target})
}
