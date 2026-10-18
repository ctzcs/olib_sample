package main

import "core:fmt"
import "core:math"
import "core:os"

import "editor"

import debug "olib:core/debug"
import foster "olib:foster"
import appkit "olib:kit/app"
import gizmo "olib:kit/gizmo"
import world "olib:kit/world"

// 分区：资源与生命周期 / 输入与自动验收 / 原生像素绘制
Demo :: struct {
	batch: foster.Batcher,
	font_source: foster.Font,
	font: foster.SpriteFont,
	target: foster.Target,
	editor: editor.Session,
	viewports: [3]foster.Rect,
	frame: int,
	shot, failed: bool,
	pointer, scripted_end: foster.Vec2,
	ui_scale: f32,
}

// ==============================================================================
// 资源与生命周期
// ==============================================================================

main :: proc() {
	if !run_app() do os.exit(1)
}

run_app :: proc() -> bool {
	tracking := debug.track_create()
	defer debug.track_destroy(tracking)
	context.allocator = tracking
	s: Demo
	s.shot = appkit.has_arg(os.args, "shot")
	config := foster.DefaultAppConfig("Gizmo2D", 1280, 720)
	config.WindowTitle = "olib - 2D Gizmos | Drag handles | Arrows pan | Q/E rotate camera | R reset"
	if appkit.has_arg(os.args, "scaled") {
		config.Width = 1600
		config.Height = 900
	}
	if appkit.has_arg(os.args, "narrow") {
		config.Width = 960
		config.Height = 600
	}
	if appkit.has_arg(os.args, "vulkan") do config.PreferredGraphicsDriver = .Vulkan
	app: foster.App
	foster.InitApp(&app, config)
	foster.AppSetUserData(&app, &s)
	defer {
		foster.Dispose(&app)
		// 交换链 CPU 包装数组由宿主释放，不拥有 SDL 交换链纹理。
		delete(app.GraphicsDevice.WindowRenderTarget.Attachments)
		app.GraphicsDevice.WindowRenderTarget.Attachments = nil
	}
	app.StartupProc = startup
	app.ShutdownProc = shutdown
	app.UpdateProc = update
	app.RenderProc = render
	foster.Run(&app)
	return !s.failed
}

startup :: proc(app: ^foster.App) {
	s := foster.AppGetUserDataAs(app, Demo)
	foster.BatcherInit(&s.batch, &app.GraphicsDevice)
	for path in ([]string{"C:/Windows/Fonts/segoeui.ttf", "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
		"/System/Library/Fonts/Supplemental/Arial.ttf"}) {
		if !os.exists(path) do continue
		s.font_source = foster.FontLoadFile(path)
		s.font = foster.SpriteFontMakeGPU(&app.GraphicsDevice, &s.font_source, 16)
		break
	}
	if s.font_source.Disposed || len(s.font.Characters) == 0 {
		fmt.eprintln("Gizmo2D: no usable demo font")
		s.failed = true
		foster.Exit(app)
	}
	editor.init(&s.editor)
}

shutdown :: proc(app: ^foster.App) {
	s := foster.AppGetUserDataAs(app, Demo)
	editor.destroy(&s.editor)
	foster.TargetDispose(&s.target)
	foster.SpriteFontDispose(&s.font)
	foster.FontDispose(&s.font_source)
	foster.BatcherDispose(&s.batch)
}

// ==============================================================================
// 输入与自动验收
// ==============================================================================

update :: proc(app: ^foster.App) {
	s := foster.AppGetUserDataAs(app, Demo)
	s.frame += 1
	keys := &app.Input.State.Keyboard
	if foster.KeyboardPressed(keys, .Escape) {
		if s.editor.active {
			editor.cancel(&s.editor)
		} else {
			foster.Exit(app)
		}
	}
	if foster.KeyboardCtrl(keys) {
		if foster.KeyboardPressed(keys, .Z) do editor.undo(&s.editor)
		if foster.KeyboardPressed(keys, .Y) do editor.redo(&s.editor)
	}
	if foster.KeyboardPressed(keys, .R) do editor.reset(&s.editor)
	for &c in s.editor.cameras {
		dt := app.Time.Delta
		p := c.position
		if foster.KeyboardDown(keys, .Left) do p.x -= dt*2
		if foster.KeyboardDown(keys, .Right) do p.x += dt*2
		if foster.KeyboardDown(keys, .Up) do p.y -= dt*2
		if foster.KeyboardDown(keys, .Down) do p.y += dt*2
		world.camera2d_set_position(&c, p)
		if foster.KeyboardDown(keys, .Q) do world.camera2d_set_rotation(&c, c.rotation-dt)
		if foster.KeyboardDown(keys, .E) do world.camera2d_set_rotation(&c, c.rotation+dt)
		if !foster.KeyboardCtrl(keys) && foster.KeyboardDown(keys, .Z) do world.camera2d_set_zoom(&c, max(0.1, c.zoom-dt))
		if foster.KeyboardDown(keys, .X) do world.camera2d_set_zoom(&c, min(5, c.zoom+dt))
	}
	if s.shot do smoke(app)
}

// 冒烟走真实 Foster 鼠标输入，使用带偏移、旋转相机的三个独立视口。
smoke :: proc(app: ^foster.App) {
	s := foster.AppGetUserDataAs(app, Demo)
	switch s.frame {
	case 10, 40, 70, 100:
		i := s.frame == 10 ? 0 : s.frame == 40 ? 1 : 2
		g := gizmo.transform2d_geometry(&s.editor.cameras[i], s.editor.values[i], s.viewports[i], gizmo.Mode(i), s.ui_scale)
		start := g.axes.origin
		if i == 0 {
			s.scripted_end, _ = gizmo.project2d(&s.editor.cameras[i], {0.75, -0.5}, s.viewports[i])
		} else if i == 1 {
			start.x += g.radius
			s.scripted_end = g.axes.origin+foster.Vec2{math.cos(f32(0.5)), math.sin(f32(0.5))}*g.radius
		} else if s.frame == 70 {
			start = g.axes.ends[0]
			s.scripted_end = start+(start-g.axes.origin)*0.5
		} else {
			s.scripted_end = start+foster.Vec2{0.70710678, -0.70710678}*25*s.ui_scale
		}
		pointer(app, start, true)
	case 20, 50, 80, 105:
		pointer(app, s.scripted_end, true)
	case 30, 60, 90, 110:
		foster.InputMouseButton(&app.Input, .Left, false, app.Time.Elapsed)
	case 114:
		d := s.editor.values[0].position-foster.Vec2{0.75, -0.5}
		check(s, d.x*d.x+d.y*d.y < 0.00001, "free movement")
		check(s, abs(s.editor.values[1].rotation-0.75) < 0.001, "rotation")
		check(s, abs(s.editor.values[2].scale.x-2.25) < 0.001 && abs(s.editor.values[2].scale.y-1) < 0.001,
			"axis and uniform scaling")
	case 117:
		check(s, len(s.editor.history) == 4 && !s.editor.active, "one record per gesture")
		editor.undo(&s.editor)
		check(s, abs(s.editor.values[2].scale.x-1.8) < 0.001, "undo uniform scaling")
		editor.redo(&s.editor)
		check(s, abs(s.editor.values[2].scale.x-2.25) < 0.001, "redo uniform scaling")
	case 120:
		foster.SetWindowSize(&app.Window, {1100, 650})
	case 142:
		check(s, abs(s.editor.values[1].rotation-0.75) < 0.001 && s.editor.cursor == 4,
			"history and rotation survive undo/redo and resize")
		fmt.println(s.failed ? "GIZMO2D SMOKE FAIL" : "GIZMO2D SMOKE PASS: move, rotate, scale, offset viewports and resize")
		foster.Exit(app)
	}
}

check :: proc(s: ^Demo, condition: bool, reason: string) {
	if condition do return
	s.failed = true
	fmt.eprintln("Gizmo2D:", reason)
}

pointer :: proc(app: ^foster.App, pixel: foster.Vec2, down: bool) {
	size := foster.Size(&app.Window)
	pixels := foster.SizeInPixels(&app.Window)
	foster.InputMouseMove(&app.Input, {pixel.x*f32(size.X)/f32(pixels.X),
		pixel.y*f32(size.Y)/f32(pixels.Y)}, {}, app.Time.Elapsed)
	foster.InputMouseButton(&app.Input, .Left, down, app.Time.Elapsed)
}

// ==============================================================================
// 原生像素绘制
// ==============================================================================

render :: proc(app: ^foster.App) {
	s := foster.AppGetUserDataAs(app, Demo)
	pixels := foster.SizeInPixels(&app.Window)
	if pixels.X <= 0 || pixels.Y <= 0 do return
	if s.target.Width != pixels.X || s.target.Height != pixels.Y {
		foster.TargetDispose(&s.target)
		foster.TargetInit(&s.target, &app.GraphicsDevice, pixels.X, pixels.Y)
	}
	w, h := f32(pixels.X), f32(pixels.Y)
	s.ui_scale = min(w/1280, h/720)
	size := foster.Size(&app.Window)
	mouse := &app.Input.State.Mouse
	s.pointer = {mouse.Position.X*w/f32(max(1, size.X)), mouse.Position.Y*h/f32(max(1, size.Y))}
	// 先同步全部视口，再分配一次输入；场景和手柄随后读取已接受的文档。
	for i in 0..<3 {
		width := f32(int((w-64)/3))
		s.viewports[i] = {16+f32(i)*(width+16), 104, width, f32(int(h-184))}
		world.camera2d_set_viewport(&s.editor.cameras[i], int(width), int(h-184))
	}
	editor.input(&s.editor, s.viewports,
		{pointer = s.pointer, pressed = foster.MouseLeftPressed(mouse), down = foster.MouseLeftDown(mouse),
			enabled = foster.Focused(&app.Window) || s.shot, allow_start = true}, s.ui_scale)
	foster.BatcherClear(&s.batch)
	foster.BatcherRect(&s.batch, {0, 0, w, h}, {18, 26, 36, 255})
	text(s, "2D GIZMOS / Camera2D", {24, 22})
	text(s, "Drag handles | Arrows: pan | Q/E: camera rotation | Z/X: zoom | R: reset | Ctrl Z/Y: undo/redo | Esc: cancel", {24, 48})
	names := [3]string{"MOVE / WORLD X,Y", "ROTATE / Z", "SCALE / LOCAL X,Y"}
	for i in 0..<3 {
		width := f32(int((w-64)/3))
		rect := foster.Rect{16+f32(i)*(width+16), 104, width, f32(int(h-184))}
		s.viewports[i] = rect
		world.camera2d_set_viewport(&s.editor.cameras[i], int(rect.Width), int(rect.Height))
		text(s, names[i], {rect.X+8, 80})
		foster.BatcherPushScissor(&s.batch, {int(rect.X), int(rect.Y), int(rect.Width), int(rect.Height)})
		foster.BatcherRect(&s.batch, rect, {29, 42, 55, 255})
		for line in -12..=12 {
			a, _ := gizmo.project2d(&s.editor.cameras[i], {f32(line), -12}, rect)
			b, _ := gizmo.project2d(&s.editor.cameras[i], {f32(line), 12}, rect)
			foster.BatcherLine(&s.batch, a, b, 1, {48, 63, 77, 255})
			a, _ = gizmo.project2d(&s.editor.cameras[i], {-12, f32(line)}, rect)
			b, _ = gizmo.project2d(&s.editor.cameras[i], {12, f32(line)}, rect)
			foster.BatcherLine(&s.batch, a, b, 1, {48, 63, 77, 255})
		}
		v := s.editor.values[i]
		points: [4]foster.Vec2
		for local, n in ([4]foster.Vec2{{-1, -0.7}, {1, -0.7}, {1, 0.7}, {-1, 0.7}}) {
			p := local*v.scale
			rotated := foster.Vec2{p.x*math.cos(v.rotation)-p.y*math.sin(v.rotation),
				p.x*math.sin(v.rotation)+p.y*math.cos(v.rotation)}
			points[n], _ = gizmo.project2d(&s.editor.cameras[i], v.position+rotated, rect)
		}
		foster.BatcherTriangle(&s.batch, points[0], points[1], points[2], {61, 117, 126, 255})
		foster.BatcherTriangle(&s.batch, points[0], points[2], points[3], {61, 117, 126, 255})
		for point, n in points do foster.BatcherLine(&s.batch, point, points[(n+1)%4], 2, {144, 207, 199, 255})
		geometry := gizmo.transform2d_geometry(&s.editor.cameras[i], v, rect, gizmo.Mode(i), s.ui_scale)
		labels := gizmo.transform2d_draw(&s.batch, &s.editor.handles[i], geometry, s.pointer, s.ui_scale)
		axis_names := [3]string{"X", "Y", "Z"}
		for label, axis in labels {
			if label.visible do text(s, axis_names[axis], label.position)
		}
		foster.BatcherPopScissor(&s.batch)
		text(s, fmt.tprintf("pos %.2f, %.2f | angle %.1f", v.position.x, v.position.y, v.rotation*180/math.PI),
			{rect.X+8, h-64})
		text(s, fmt.tprintf("scale %.2f, %.2f", v.scale.x, v.scale.y), {rect.X+8, h-40})
	}
	foster.BatcherRender(&s.batch, foster.DrawableTargetFromWindow(&app.Window))
	foster.BatcherRender(&s.batch, foster.DrawableTargetFromTarget(&s.target))
	if s.shot && (s.frame == 116 || s.frame == 140) {
		bytes := foster.TextureDownloadData(foster.TargetAttachment(&s.target))
		defer delete(bytes)
		image := foster.ImageMake(pixels.X, pixels.Y)
		defer foster.ImageDispose(&image)
		check(s, len(bytes) == pixels.X*pixels.Y*4, "capture readback")
		if len(bytes) == pixels.X*pixels.Y*4 {
			for &pixel, i in image.Pixels do pixel = {bytes[i*4], bytes[i*4+1], bytes[i*4+2], bytes[i*4+3]}
			name := fmt.tprintf("build/gizmo2d-%dx%d.png", pixels.X, pixels.Y)
			check(s, foster.ImageWritePng(&image, name), "capture write")
			fmt.println(name)
		}
	}
}

text :: proc(s: ^Demo, value: string, position: foster.Vec2) {
	foster.SpriteFontDraw(&s.batch, &s.font, value, position, foster.White)
}
