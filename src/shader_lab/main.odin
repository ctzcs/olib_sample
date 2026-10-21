package main

// 独立启动接线：窗口、输入、项目路径和 MSDF 资产；工具位于 olib:kit/tools/shader_lab。
import "core:fmt"
import "core:os"

import foster "olib:foster"
import appkit "olib:kit/app"
import lab "olib:kit/tools/shader_lab"
import files "../../shared/shader_lab_files"
import fonts "../../shared/msdf_font"
import checks "../../tools/shader_lab_checks"

Host :: struct {
	tool: lab.Session,
	files: files.Bridge,
	validation: checks.State,
	font: foster.MsdfFont,
	font_texture: foster.Texture,
	failed, embedded: bool,
}

main :: proc() {
	host := new(Host)
	defer free(host)
	source := #directory + "/shaders"
	for arg, i in os.args {
		if arg == "source" && i+1 < len(os.args) do source = os.args[i+1]
	}
	// prepare 按 features 决定隔离源码里带哪些 Shader，须先设置。
	host.validation.features = appkit.has_arg(os.args, "features")
	if !checks.prepare(&host.validation, &host.tool, source,
		appkit.has_arg(os.args, "shot"), appkit.has_arg(os.args, "smoke") || appkit.has_arg(os.args, "features"),
		appkit.has_arg(os.args, "colors"), appkit.has_arg(os.args, "multipass") || appkit.has_arg(os.args, "hierarchy") || appkit.has_arg(os.args, "targets")) {
		os.exit(1)
	}
	host.validation.hierarchy = appkit.has_arg(os.args, "hierarchy")
	host.validation.targets = appkit.has_arg(os.args, "targets")
	host.embedded = appkit.has_arg(os.args, "embedded")
	config := foster.DefaultAppConfig("olib / Shader Lab / 2D + 3D", 1280, 800)
	if appkit.has_arg(os.args, "scaled") {
		config.Width = 1600
		config.Height = 1000
	}
	if appkit.has_arg(os.args, "narrow") {
		config.Width = 960
		config.Height = 720
	}
	if appkit.has_arg(os.args, "vulkan") do config.PreferredGraphicsDriver = .Vulkan
	if appkit.has_arg(os.args, "d3d12") do config.PreferredGraphicsDriver = .D3D12
	app: foster.App
	foster.InitApp(&app, config)
	foster.AppSetUserData(&app, host)
	app.StartupProc = startup
	app.UpdateProc = update
	app.RenderProc = render
	app.ShutdownProc = shutdown
	foster.Run(&app)
	foster.Dispose(&app)
	delete(app.GraphicsDevice.WindowRenderTarget.Attachments)
	if host.failed || host.validation.failed {
		fmt.eprintln("Shader Lab startup or validation failed")
		os.exit(1)
	}
}

startup :: proc(app: ^foster.App) {
	host := foster.AppGetUserDataAs(app, Host)
	ok: bool
	host.font, host.font_texture, ok = fonts.load(&app.GraphicsDevice)
	if ok {
		ok = lab.init(&host.tool, &app.GraphicsDevice, {
			source_root = host.tool.source_root,
			font = &host.font, font_texture = host.font_texture,
			paused = host.validation.shot || host.validation.smoke,
			file_dialogs = true,
		})
	}
	if ok do files.init(&host.files, app.Window.Handle)
	if !ok {
		host.failed = true
		foster.Exit(app)
	}
}

update :: proc(app: ^foster.App) {
	host := foster.AppGetUserDataAs(app, Host)
	files.update(&host.files, &host.tool)
	checks.update(&host.validation, app)
	lab.update(&host.tool, app.Time.Delta)
}

render :: proc(app: ^foster.App) {
	host := foster.AppGetUserDataAs(app, Host)
	target := foster.DrawableTargetFromWindow(&app.Window)
	w := f32(target.WidthInPixels)
	h := f32(target.HeightInPixels)
	region := foster.Rect{0, 0, w, h}
	if host.embedded do region = {48, 40, w-96, h-80}
	foster.GraphicsDeviceClear(&app.GraphicsDevice, target, foster.Color{35, 40, 47, 255})
	input := host_input(app, &host.validation)
	logical := foster.Size(&app.Window)
	files.input(&host.files, &input, w/f32(max(1, logical.X)), h/f32(max(1, logical.Y)))
	if input.escape && !host.tool.color_picker.open && !host.tool.splitting do foster.Exit(app)
	_ = lab.render(&host.tool, target, region, input)
}

// 宿主将窗口逻辑坐标转换成最终目标像素，并决定工具能消费哪些输入。
host_input :: proc(app: ^foster.App, validation: ^checks.State) -> lab.Input {
	logical := foster.Size(&app.Window)
	pixels := foster.SizeInPixels(&app.Window)
	scale := foster.Vec2{f32(pixels.X)/f32(max(1, logical.X)), f32(pixels.Y)/f32(max(1, logical.Y))}
	mouse := &app.Input.State.Mouse
	keys := &app.Input.State.Keyboard
	input := lab.Input{
		pointer = {mouse.Position.X*scale.x, mouse.Position.Y*scale.y},
		delta = {mouse.Delta.X*scale.x, mouse.Delta.Y*scale.y},
		scroll = {mouse.Wheel.X, mouse.Wheel.Y},
		left_down = foster.MouseDown(mouse, .Left),
		right_down = foster.MouseDown(mouse, .Right),
		right_pressed = foster.MousePressed(mouse, .Right),
		focused = foster.Focused(&app.Window),
		escape = foster.KeyboardPressed(keys, .Escape),
		vertical_adjust = f32(int(foster.PressedOrRepeated(keys, .Down))-int(foster.PressedOrRepeated(keys, .Up))),
	}
	if validation.smoke do input.focused = !validation.color_test_blur
	if foster.KeyboardPressed(keys, .Tab) {
		input.navigation.next = foster.KeyboardDown(keys, .LeftShift) ? -1 : 1
	}
	input.navigation.activate = foster.KeyboardPressed(keys, .Enter)
	input.navigation.adjust = f32(int(foster.PressedOrRepeated(keys, .Right))-int(foster.PressedOrRepeated(keys, .Left)))
	return input
}

shutdown :: proc(app: ^foster.App) {
	host := foster.AppGetUserDataAs(app, Host)
	files.dispose(&host.files)
	checks.dispose(&host.validation)
	lab.dispose(&host.tool)
	foster.MsdfFontDispose(&host.font)
	foster.TextureDispose(&host.font_texture)
}
