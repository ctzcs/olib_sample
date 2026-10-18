// 常驻开发宿主：App/设备/字体/监听器保持不变，游戏与 UI 在 DLL 中。
package main

import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"

import reload "olib:core/hotreload"
import foster "olib:foster"
import appkit "olib:kit/app"
import ui "olib:kit/ui"
import clay "olib:thirdparty/clay-odin"

import SDL "vendor:sdl3"

import msdf "../../shared/msdf_font"
import "contract"

// 分区：宿主所有权 / App 生命周期 / 热替换与输入 / 状态绘制。
Host :: struct {
	services: contract.Services,
	session: reload.Session,
	watch: reload.Watch,
	font: foster.MsdfFont,
	font_texture: foster.Texture,
	ctx: ui.UI_Context,
	batcher: foster.Batcher,
	theme: ui.UI_Theme,
	sample_root, source_root, library_root: string,
	failed: bool,
	last_status: reload.Build_Status,
}

main :: proc() {
	if !run() do os.exit(1)
}

run :: proc() -> bool {
	s := new(Host)
	defer free(s)
	s.services.scale = appkit.has_arg(os.args, "scaled") ? 1.25 : 1
	s.sample_root, _ = filepath.abs(#directory + "/../..")
	s.library_root, _ = filepath.abs(#directory + "/../../../olib")
	s.source_root = strings.clone(#directory)
	defer delete(s.sample_root)
	defer delete(s.library_root)
	defer delete(s.source_root)
	config := foster.DefaultAppConfig("olib / Collector - Hot Reload", 1280, 800)
	config.WindowTitle = "Collector | WASD / arrows: move | Space: pause | F5: retry | Esc: exit"
	if appkit.has_arg(os.args, "narrow") {
		config.Width = 960
		config.Height = 720
	}
	if appkit.has_arg(os.args, "vulkan") do config.PreferredGraphicsDriver = .Vulkan
	if appkit.has_arg(os.args, "d3d12") do config.PreferredGraphicsDriver = .D3D12
	app: foster.App
	foster.InitApp(&app, config)
	foster.AppSetUserData(&app, s)
	defer {
		foster.Dispose(&app)
		delete(app.GraphicsDevice.WindowRenderTarget.Attachments)
	}
	app.StartupProc = startup
	app.UpdateProc = update
	app.RenderProc = render
	app.ShutdownProc = shutdown
	foster.Run(&app)
	return !s.failed
}

startup :: proc(app: ^foster.App) {
	s := foster.AppGetUserDataAs(app, Host)
	s.services.app = app
	font, texture, font_ok := msdf.load(&app.GraphicsDevice)
	s.font = font
	s.font_texture = texture
	if !check(s, font_ok, "load shared offline MSDF font") do return
	s.services.font = &s.font
	s.services.font_texture = s.font_texture
	if !check(s, ui.ui_init(&s.ctx, 1280, 800), "initialize host status UI") do return
	s.theme = ui.UI_THEME_DARK
	s.theme.body_font_id = u16(ui.ui_register_font(&s.ctx, &s.font, s.font_texture, .MSDF))
	s.theme.body_font_size = 15
	s.theme.small_font_size = 12
	foster.BatcherInit(&s.batcher, &app.GraphicsDevice, "hotreload host status")
	if !check(s, reload.init(&s.session, contract.HOST_VERSION, &s.services), "initialize module session") {
		return
	}
	if !check(s, reload.watch_init(&s.watch, {
		working_directory = s.sample_root,
		command = {"odin", "build", fmt.tprintf("%s/game", s.source_root), "-build-mode:dll",
			fmt.tprintf("-collection:olib=%s", s.library_root), "-out:{output}",
			"-vet", "-vet-packages:game,view,logic,data,def,contract"},
		roots = {fmt.tprintf("%s/game", s.source_root), fmt.tprintf("%s/view", s.source_root),
			fmt.tprintf("%s/logic", s.source_root), fmt.tprintf("%s/data", s.source_root),
			fmt.tprintf("%s/def", s.source_root)},
	}), "start source watcher") {
		return
	}
	fmt.println("Hotreload source:", s.source_root)
	fmt.println("Save view/ui.odin or logic/rules.odin. F5 retries; Space pauses; Escape exits.")
}

shutdown :: proc(app: ^foster.App) {
	s := foster.AppGetUserDataAs(app, Host)
	_ = SDL.WaitForGPUIdle(app.GraphicsDevice.Device)
	check(s, reload.dispose(&s.session), "dispose game module")
	reload.watch_dispose(&s.watch)
	ui.ui_dispose(&s.ctx)
	foster.BatcherDispose(&s.batcher)
	foster.MsdfFontDispose(&s.font)
	foster.TextureDispose(&s.font_texture)
}

// ==============================================================================
// 热替换与输入：提交发生在帧开始，上一帧 GPU 工作已经完成
// ==============================================================================

update :: proc(app: ^foster.App) {
	s := foster.AppGetUserDataAs(app, Host)
	if s.failed do return
	keys := &app.Input.State.Keyboard
	if foster.KeyboardPressed(keys, .Escape) {
		foster.Exit(app)
		return
	}
	if foster.KeyboardPressed(keys, .F5) do reload.watch_retry(&s.watch)
	reload.watch_update(&s.watch, f64(app.Time.Delta))
	if s.watch.status == .Ready {
		_ = SDL.WaitForGPUIdle(app.GraphicsDevice.Device)
		result := reload.watch_apply(&s.watch, &s.session)
		if result == .Success {
			fmt.printfln("LIVE generation=%d", s.session.revision)
		}
	}
	if s.watch.status == .Error && s.last_status != .Error {
		fmt.eprintln(s.watch.diagnostic)
	}
	s.last_status = s.watch.status
	input := contract.Input{}
	input.move = {
		f32(int(foster.KeyboardDown(keys, .D) || foster.KeyboardDown(keys, .Right)) -
			int(foster.KeyboardDown(keys, .A) || foster.KeyboardDown(keys, .Left))),
		f32(int(foster.KeyboardDown(keys, .S) || foster.KeyboardDown(keys, .Down)) -
			int(foster.KeyboardDown(keys, .W) || foster.KeyboardDown(keys, .Up))),
	}
	input.toggle_pause = foster.KeyboardPressed(keys, .Space)
	mouse := app.Input.State.Mouse
	pixels := foster.SizeInPixels(&app.Window)
	logical := foster.Size(&app.Window)
	input.mouse = {mouse.Position.X*f32(pixels.X)/f32(max(logical.X, 1)),
		mouse.Position.Y*f32(pixels.Y)/f32(max(logical.Y, 1))}
	input.mouse_down = foster.MouseDown(&mouse, .Left)
	input.wheel = {mouse.Wheel.X, mouse.Wheel.Y}
	if foster.KeyboardPressed(keys, .Tab) {
		input.navigation.next = foster.KeyboardDown(keys, .LeftShift) ? -1 : 1
	}
	input.navigation.activate = foster.KeyboardPressed(keys, .Enter)
	s.services.input = input
	dt := f64(min(app.Time.Delta, 0.05))
	reload.update(&s.session, dt)
}

// ==============================================================================
// 最终像素绘制：游戏与宿主状态直接绘制到窗口
// ==============================================================================

render :: proc(app: ^foster.App) {
	s := foster.AppGetUserDataAs(app, Host)
	if s.failed || s.ctx.clay_context == nil || !app.GraphicsDevice.InFrame do return
	target := foster.DrawableTargetFromWindow(&app.Window)
	w := target.WidthInPixels
	h := target.HeightInPixels
	if w <= 0 || h <= 0 do return
	foster.GraphicsDeviceClear(&app.GraphicsDevice, target, {12, 18, 26, 255})
	reload.render(&s.session, f64(app.Time.Delta))
	draw_status(s, f32(w), f32(h))
	foster.BatcherRender(&s.batcher, target)
	check(s, s.ctx.error_count == 0, "host status UI layout must be valid")
}

draw_status :: proc(s: ^Host, width, height: f32) {
	ctx := &s.ctx
	t := &s.theme
	ui.ui_set_viewport(ctx, {0, 0, width, height}, s.services.scale)
	ui.ui_begin(ctx, 1.0/60)
	label := "WAITING FOR FIRST BUILD"
	if reload.is_live(&s.session) do label = "SOURCE CHANGED - WAITING TO BUILD"
	color := foster.Color{247, 197, 109, 255}
	#partial switch s.watch.status {
	case .Compiling:
		label = "BUILDING - GAME STILL RUNNING"
	case .Live:
		label = "LIVE - SAVE TO RELOAD"
		color = {100, 229, 185, 255}
	case .Error:
		label = "BUILD FAILED - PREVIOUS GAME KEPT"
		color = {255, 147, 135, 255}
	}
	column := ui.ui_column_decl(0)
	if clay.UI()(column) {
		bar := ui.ui_row_decl(16)
		bar.layout.padding = {left = 24, right = 24}
		bar.layout.sizing.height = clay.SizingFixed(64)
		bar.backgroundColor = ui.ui_clay_color({20, 29, 40, 255})
		if clay.UI()(bar) {
			ui.ui_label_ex(ctx, t, "OLIB / HOT RELOAD", t.text, 16)
			ui.ui_spacer()
			ui.ui_label_ex(ctx, t, label, color, ctx.width < 1000 ? 11 : 13)
			ui.ui_label_dim(ctx, t, fmt.tprintf("v%02d", s.session.revision))
		}
		if s.watch.status == .Error {
			panel := ui.ui_panel_decl(t, 4)
			panel.backgroundColor = ui.ui_clay_color({67, 34, 39, 255})
			if clay.UI()(panel) {
				ui.ui_label_ex(ctx, t, "Fix the source and save. F5 retries the current source.", color, 15)
				ui.ui_label_dim(ctx, t, diagnostic_preview(s.watch.diagnostic, ctx.width))
			}
		} else if !reload.is_live(&s.session) {
			if clay.UI()(ui.ui_panel_decl(t, 10)) {
				ui.ui_heading(ctx, t, "Starting your first run...")
				ui.ui_label(ctx, t, "Compiling game logic and UI. This window stays open for every reload.")
			}
		}
	}
	foster.BatcherClear(&s.batcher)
	ui.ui_draw(ctx, &s.batcher)
}

diagnostic_preview :: proc(value: string, width: f32) -> string {
	// 编译器完整日志在终端；界面仅给前四行，避免覆盖整场游戏。
	lines := strings.split_lines(value, context.temp_allocator)
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	limit := int(math.clamp(width/8-8, 30, 150))
	for line, i in lines {
		if i == 4 do break
		trimmed := strings.trim_space(line)
		strings.write_string(&b, trimmed[:min(len(trimmed), limit)])
		strings.write_string(&b, "\n")
	}
	return strings.to_string(b)
}

check :: proc(s: ^Host, ok: bool, message: string) -> bool {
	if ok do return true
	s.failed = true
	fmt.eprintln("HOTRELOAD FAIL:", message)
	foster.Exit(s.services.app)
	return false
}
