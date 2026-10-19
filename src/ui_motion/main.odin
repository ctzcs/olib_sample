package main

import "core:fmt"
import "core:os"

import tween "olib:core/tween"
import foster "olib:foster"
import appkit "olib:kit/app"
import r2d "olib:kit/rendering/2d"
import mat "olib:kit/rendering/material"
import ui "olib:kit/ui"
import clay "olib:thirdparty/clay-odin"

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
	tiles: [3]Motion,
	modal: Motion,
	modal_open, modal_closing: bool,
	attacks, rewards, frame: int,
	shot, scaled, failed: bool,
	dt: f32,
}

// ==============================================================================
// 状态与生命周期
// ==============================================================================

main :: proc() {
	s := new(Demo)
	s.shot = appkit.has_arg(os.args, "shot") || appkit.has_arg(os.args, "smoke")
	s.scaled = appkit.has_arg(os.args, "scaled")
	config := foster.DefaultAppConfig("olib - UI Motion | Click tiles | Tab / Enter | Esc", 1200, 760)
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
	s.theme.corner_radius = 0
	s.theme.padding = 12
	s.theme.body_font_size = 18
	s.theme.heading_font_size = 30
	s.tweens = tween.manager_make()
	for &tile in s.tiles {
		tile.visual = ui.UI_VISUAL_DEFAULT
	}
	s.modal.visual = ui.UI_VISUAL_DEFAULT
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
	if s.modal_closing && !tween.manager_is_handle_valid(s.tweens, s.modal.handle) {
		s.modal_open = false
		s.modal_closing = false
	}
	if foster.KeyboardPressed(&g.Input.State.Keyboard, .Escape) {
		close_modal(s)
	}
	if s.shot && s.frame == 125 {
		foster.SetWindowSize(&g.Window, {960, 800})
	}
}

render :: proc(g: ^foster.App) {
	s := foster.AppGetUserDataAs(g, Demo)
	pixels := foster.SizeInPixels(&g.Window)
	if pixels.X <= 0 || pixels.Y <= 0 do return
	if s.target.Width != pixels.X || s.target.Height != pixels.Y {
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
	ui.ui_set_navigation(&s.ctx, nav)
	if s.shot {
		smoke_input(s)
	}
	ui.ui_set_modal(&s.ctx, s.modal_open ? "reward-modal" : "")
	ui.ui_begin(&s.ctx, s.dt)
	declare_ui(s)
	window := foster.DrawableTargetFromWindow(&g.Window)
	final := foster.DrawableTargetFromTarget(&s.target)
	foster.GraphicsDeviceClear(&g.GraphicsDevice, window, INK)
	foster.GraphicsDeviceClear(&g.GraphicsDevice, final, INK)
	// submit 会清空记录：画到第二个目标时用同一批 UI 操作再记录一次。
	ui.ui_draw(&s.ctx, &s.batch)
	r2d.submit(&s.batch, {target = window})
	ui.ui_render(&s.ctx, &s.batch, &s.ctx.ops)
	r2d.submit(&s.batch, {target = final})
	if s.shot {
		assert(s.ctx.error_count == 0 && !s.ctx.pool_overflow, "UI diagnostics")
		if s.frame == 3 || s.frame == 13 || s.frame == 46 || s.frame == 74 || s.frame == 90 || s.frame == 153 || s.frame == 205 {
			save_frame(s)
		}
		if s.frame == 210 {
			assert(s.attacks == 2 && s.rewards == 1 && !s.modal_open, "interaction and resize")
			fmt.printf("UI MOTION PASS: rebound, jump, modal enter/exit, transformed clicks, rapid hover leave/reset, resize; %dx%d scale=%.2f\n",
				pixels.X, pixels.Y, s.ctx.scale)
			foster.Exit(g)
		}
	}
	s.frame += 1
}

// ==============================================================================
// 自动验收 —— 经 UI 输入入口点击实际显示位置，不直接触发业务动作
// ==============================================================================

smoke_input :: proc(s: ^Demo) {
	id: string
	down := false
	switch s.frame {
	case 8, 9, 10:
		id = "attack"
		down = s.frame < 10
	case 38, 39:
		assert(s.attacks == 1)
		id = "item"
		down = s.frame == 38
	case 70, 71:
		assert(s.rewards == 1)
		id = "open"
		down = s.frame == 70
	case 100, 101:
		assert(s.modal_open)
		id = "close"
		down = s.frame == 100
	case 170:
		ui.ui_set_navigation(&s.ctx, {cancel = true})
	case 174:
		id = "attack"
	case 178:
		id = "open"
	case 205:
		for tile in s.tiles {
			assert(tile.visual == ui.UI_VISUAL_DEFAULT, "rapid hover leave must restore every tile")
		}
	case 145, 146:
		assert(!s.modal_open)
		id = "attack"
		down = s.frame == 145
	}
	ui.ui_set_pointer(&s.ctx, -100, -100, false)
	if id != "" {
		box := clay.GetElementData(clay.ID(id))
		assert(box.found)
		bb := box.boundingBox
		// 点击中心。卡片的中心支点仅受 offset 影响；弹窗关闭时已收稳。
		p := foster.Vec2{bb.x + bb.width * 0.5, bb.y + bb.height * 0.5}
		if id == "attack" do p += s.tiles[0].visual.offset
		if id == "item" do p += s.tiles[1].visual.offset
		if id == "open" do p += s.tiles[2].visual.offset
		p = s.ctx.viewport_origin + p * s.ctx.scale
		ui.ui_set_pointer(&s.ctx, p.x, p.y, down)
	}
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
