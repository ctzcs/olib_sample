package main

// 独立启动接线：窗口、ImGui 与 Dock 布局、文件对话框与拖放；工具位于 olib:kit/tools/shader_lab。
// 整帧（背景 + ImGui）先画进离屏目标再贴到窗口，验证截图读取同一目标。
import "core:fmt"
import "core:os"

import foster "olib:foster"
import appkit "olib:kit/app"
import r2d "olib:kit/rendering/2d"
import mat "olib:kit/rendering/material"
import lab "olib:kit/tools/shader_lab"
import imgui "olib:thirdparty/imgui"
import imgui_foster "olib:thirdparty/imgui/imgui_impl_ofoster"
import files "../../shared/shader_lab_files"
import checks "../../tools/shader_lab_checks"

Host :: struct {
	tool: lab.Session,
	files: files.Bridge,
	validation: checks.State,
	frame: foster.Target, // 最终输出：背景 + ImGui，渲染完贴到窗口
	materials: mat.Material_Library,
	blit: r2d.Render2D, // 借用 materials；Host 初始化后不得搬动
	failed, gui: bool,
}

// ImGui 首次布局：控制窗口停靠左侧，预览占其余区域。
PANEL_RATIO :: f32(0.3)
// ImGuiDockNodeFlags_DockSpace 是 imgui_internal.h 的私有位，绑定里没有生成。
DOCK_NODE_DOCKSPACE :: transmute(imgui.DockNodeFlags)i32(1 << 10)

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
	host.materials = {device = &app.GraphicsDevice}
	ok := r2d.init(&host.blit, &host.materials) == ""
	// 离屏最终输出是 foster 的 RGBA8 目标；不开键盘导航，方向键和空格不被面板误用。
	if ok do ok = imgui_foster.Init(app, {.DockingEnable}, .Olib, .R8G8B8A8_UNORM)
	host.gui = ok
	if ok {
		imgui.GetIO().IniFilename = nil // 布局不写进工作目录；每次启动用默认停靠
		ok = lab.init(&host.tool, &app.GraphicsDevice, {
			source_root = host.tool.source_root,
			paused = host.validation.shot || host.validation.smoke,
			file_dialogs = true,
			open_file = files.open_file,
		})
	}
	if ok do files.init(&host.files, app.Window.Handle)
	host.validation.final = &host.frame
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
	// 离焦时取消调色板与轨道旋转。验证只认注入的输入：真实焦点不参与，color_test_blur 模拟离焦。
	checking := host.validation.smoke || host.validation.shot
	focused := checking ? !host.validation.color_test_blur : foster.Focused(&app.Window)
	if !focused do lab.cancel(&host.tool)
	escape := foster.KeyboardPressed(&app.Input.State.Keyboard, .Escape)
	if escape && !host.tool.color_picker.open && !host.tool.shader_menu && !imgui.GetIO().WantTextInput {
		foster.Exit(app)
	}
	imgui_foster.NewFrame(app, app.Time.Delta, force_focus = checking)
}

render :: proc(app: ^foster.App) {
	host := foster.AppGetUserDataAs(app, Host)
	device := &app.GraphicsDevice
	window := foster.DrawableTargetFromWindow(&app.Window)
	w, h := window.WidthInPixels, window.HeightInPixels
	if w <= 0 || h <= 0 do return
	if host.frame.Width != w || host.frame.Height != h {
		foster.TargetDispose(&host.frame)
		foster.TargetInit(&host.frame, device, w, h, "shader lab frame")
	}
	foster.GraphicsDeviceClear(device, foster.DrawableTargetFromTarget(&host.frame), foster.Color{35, 40, 47, 255})
	if imgui_foster.BeginRender(app) {
		dock := imgui.GetID("shader-lab-dock")
		if imgui.DockBuilderGetNode(dock) == nil do default_layout(dock, imgui.GetMainViewport().WorkSize)
		imgui.DockSpaceOverViewport(dock, nil, {})
		dropped, position := files.drops(&host.files)
		lab.draw(&host.tool, dropped, position)
		imgui_foster.EndRender(app, &host.frame)
	}
	r2d.quad_texture(&host.blit, foster.TargetAttachment(&host.frame), {0, 0}, {f32(w), 0}, {f32(w), f32(h)}, {0, f32(h)},
		{0, 0}, {1, 0}, {1, 1}, {0, 1}, foster.White)
	r2d.submit(&host.blit, {target = window})
}

default_layout :: proc(dock: imgui.ID, size: imgui.Vec2) {
	imgui.DockBuilderAddNode(dock, DOCK_NODE_DOCKSPACE)
	imgui.DockBuilderSetNodeSize(dock, size)
	panel, preview: imgui.ID
	imgui.DockBuilderSplitNode(dock, .Left, PANEL_RATIO, &panel, &preview)
	imgui.DockBuilderDockWindow(lab.CONTROL_WINDOW, panel)
	imgui.DockBuilderDockWindow(lab.PREVIEW_WINDOW, preview)
	imgui.DockBuilderFinish(dock)
}

shutdown :: proc(app: ^foster.App) {
	host := foster.AppGetUserDataAs(app, Host)
	files.dispose(&host.files)
	checks.dispose(&host.validation)
	lab.dispose(&host.tool)
	if host.gui do imgui_foster.Shutdown()
	r2d.dispose(&host.blit)
	mat.material_library_dispose(&host.materials)
	foster.TargetDispose(&host.frame)
}
