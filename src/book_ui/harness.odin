package main

// 自动化检查用的命令行模式。正常运行只用到 font / scaled / back / rotated / underside。
//   shot ：渲染几帧，把截图 PNG 存到工作目录后退出（截图回归）
//   test ：启动时做几何检查，之后按帧号执行一段点击与翻页脚本；有失败则退出码为 1

// 分区：
//   类型 —— Options / Harness
//   启动与帧尾 —— parse_options / apply_start_pose / harness_startup / harness_end_frame
//   截图 —— shot_file_name / save_capture
//   断言 —— expect / check_diagnostics
//   几何检查 —— test_geometry
//   帧脚本 —— test_step / test_click / test_pointer / test_verify

import "core:fmt"
import "core:math"
import "core:os"
import kit_app "olib:kit/app"

import foster "olib:foster"
import ui "olib:kit/ui"
import kw "olib:kit/world"
import clay "olib:thirdparty/clay-odin"

// ==============================================================================
// 类型
// ==============================================================================

Options :: struct {
	font_path: string, // font <path.ttf>
	shot:      bool,
	test:      bool,
	turn:      bool, // shot：把一张纸定格在翻页途中
	late:      bool, // shot turn：定格得更晚，露出纸的背面
	back:      bool, // 从第二个跨页开始（shot turn：改为往回翻）
	scaled:    bool, // 更大的窗口
	rotated:   bool, // 初始姿态先旋转、平移过
	underside: bool, // 初始就翻过来，露出封底
}

Harness :: struct {
	frame:           int,
	test_failures:   int,
	capture:         foster.Target, // shot：最终画面的离屏副本
	capture_pending: bool,          // shot：副本已画好，下一帧读回
}

// ==============================================================================
// 启动与帧尾
// ==============================================================================

parse_options :: proc(opts: ^Options) {
	for arg, i in os.args {
		if arg == "font" && i + 1 < len(os.args) {
			opts.font_path = os.args[i + 1]
		}
	}
	opts.shot = kit_app.has_arg(os.args, "shot")
	opts.test = kit_app.has_arg(os.args, "test")
	opts.turn = kit_app.has_arg(os.args, "turn")
	opts.late = kit_app.has_arg(os.args, "late")
	opts.back = kit_app.has_arg(os.args, "back")
	opts.scaled = kit_app.has_arg(os.args, "scaled")
	opts.rotated = kit_app.has_arg(os.args, "rotated")
	opts.underside = kit_app.has_arg(os.args, "underside")
}

apply_start_pose :: proc(world: ^World) {
	if world.opts.rotated {
		rotate_book(&world.pose, {45, -18}, false)
		rotate_book(&world.pose, {-24, 0}, true)
		world.pose.position = {65, -25, 100}
	}
	if world.opts.underside {
		world.pose.rotation = quat_axis({0, 1, 0}, PI)
	}
}

harness_startup :: proc(world: ^World, app: ^foster.App) {
	opts := world.opts
	if opts.shot {
		size := foster.DrawableTargetFromWindow(&app.Window)
		foster.TargetInit(
			&world.harness.capture,
			&app.GraphicsDevice,
			size.WidthInPixels,
			size.HeightInPixels,
			"book screenshot",
		)
	}
	if opts.test {
		test_geometry(world)
	}
	if opts.shot && opts.turn {
		begin_turn(world, opts.back ? -1 : 1)
		world.turn.progress = opts.late ? 0.72 : 0.38
		world.turn.paused = true
	}
}

harness_shutdown :: proc(world: ^World) {
	if world.opts.shot {
		foster.TargetDispose(&world.harness.capture)
	}
}

harness_end_frame :: proc(world: ^World, app: ^foster.App) {
	h := &world.harness
	if world.opts.test {
		test_verify(world, app)
	}
	h.frame += 1
	if !world.opts.shot do return
	// Frame 12: draw the finished frame again into `capture`. Next frame the GPU
	// work has been submitted, so read it back, save it and exit.
	if h.capture_pending {
		save_capture(world)
		check_diagnostics(world)
		foster.Exit(app)
	} else if h.frame >= 12 {
		offscreen := foster.DrawableTargetFromTarget(&h.capture)
		foster.GraphicsDeviceClear(&app.GraphicsDevice, offscreen, BACKGROUND_COLOR)
		ui.ui_render(&world.overlay, &world.overlay_batch, &world.overlay.ops)
		compose_frame(world, app, offscreen)
		h.capture_pending = true
	}
}

// ==============================================================================
// 截图
// ==============================================================================

shot_file_name :: proc(opts: Options) -> string {
	if opts.underside do return "book_ui_underside.png"
	if opts.rotated do return "book_ui_rotated.png"
	if opts.turn {
		if opts.back do return "book_ui_back.png"
		if opts.late do return "book_ui_turn_late.png"
		return "book_ui_turn.png"
	}
	if opts.scaled do return "book_ui_scaled.png"
	return "book_ui.png"
}

save_capture :: proc(world: ^World) {
	capture := &world.harness.capture
	data := foster.TextureDownloadData(foster.TargetAttachment(capture))
	defer delete(data)
	image := foster.ImageMake(capture.Width, capture.Height)
	defer foster.ImageDispose(&image)
	if len(data) < len(image.Pixels) * 4 {
		fmt.eprintln("Capture readback failed")
		world.harness.test_failures += 1
		return
	}
	for &p, i in image.Pixels {
		p = {data[i * 4], data[i * 4 + 1], data[i * 4 + 2], data[i * 4 + 3]}
	}
	name := shot_file_name(world.opts)
	ok := foster.ImageWritePng(&image, name)
	fmt.println(name, ok)
	if !ok {
		world.harness.test_failures += 1
	}
}

// ==============================================================================
// 断言
// ==============================================================================

expect :: proc(world: ^World, ok: bool, message: string) {
	if !ok {
		fmt.eprintln("FAIL:", message)
		world.harness.test_failures += 1
	}
}

check_diagnostics :: proc(world: ^World) {
	for &page in world.pages {
		expect(world, page.ctx.error_count == 0 && !page.ctx.pool_overflow, "page UI diagnostics are clear")
	}
	overlay := &world.overlay
	expect(world, overlay.error_count == 0 && !overlay.pool_overflow, "overlay UI diagnostics are clear")
}

// ==============================================================================
// 几何检查
// ==============================================================================

test_geometry :: proc(world: ^World) {
	saved_pose, saved_view := world.pose, world.view
	defer {
		world.pose = saved_pose
		world.view = saved_view
	}
	// Test both sides, an in-flight curved sheet, and multiple viewport sizes.
	for size in ([][2]f32{{1180, 860}, {1500, 1050}, {820, 700}}) {
		world.view = book_view(world.pose, size[0], size[1])
		for angle in ([]f32{0, PI, 0.65, 2.4}) {
			curl: f32 = angle == 0 || angle == PI ? 0 : 0.35
			sheet := make_sheet(angle, curl)
			back := angle > PI * 0.5
			for uv in ([]foster.Vec2{{0.14, 0.12}, {0.55, 0.43}, {0.89, 0.86}}) {
				point := sheet_point(world.view, &sheet, uv, back)
				found, hit := pick_sheet(&world.view, &sheet, point, back)
				close := math.abs(found.x - uv.x) < 0.001 && math.abs(found.y - uv.y) < 0.001
				expect(
					world,
					hit && close,
					fmt.tprintf(
						"screen to page UV round trip: angle=%.2f uv=%v got=%v hit=%v",
						angle,
						uv,
						found,
						hit,
					),
				)
			}
			_, hit := pick_sheet(&world.view, &sheet, {-1000, -1000}, back)
			expect(world, !hit, "outside the book is not a page hit")
		}
	}
	// A near-edge-on triangle must fail safely rather than divide by zero.
	edge_on := kw.Ray3D{{0, 0, 1}, {0, 0, -1}}
	_, _, _, hit := ray_triangle(edge_on, {0, 0, 0}, {0, 1, 0}, {0, 2, 0}, {}, {}, {})
	expect(world, !hit, "degenerate triangle rejected")
	// Turn the whole book over: the leather must block all page widgets.
	world.pose.rotation = quat_axis({0, 1, 0}, PI)
	world.view = book_view(world.pose, 1180, 860)
	// 分两行赋值：把两个 Sheet 写进同一条多重赋值，LLVM 代码生成要多花约 8 秒。
	world.left_sheet = make_sheet(PI, 0)
	world.right_sheet = make_sheet(0, 0)
	page, _ := pick_book(world, project(world.view, {180, 0, 0}))
	expect(world, page == -1, "back cover blocks page clicks")
	world.pose = saved_pose
	world.view = book_view(world.pose, 1180, 860)
	// Sweep a complete rotation, recovering UVs on both sides. Angles near
	// edge-on are excluded here; degenerate ray triangles are checked above.
	for step in 0..<36 {
		world.pose = saved_pose
		world.pose.rotation = quat_mul(quat_axis({0, 1, 0}, f32(step) * PI / 18), world.pose.rotation)
		world.view = book_view(world.pose, 1180, 860)
		normal := kw.matrix4_transform_vector(world.view.model, {0, 0, 1})
		to_camera := kw.v3_normalize(world.view.camera.position - world.pose.position)
		facing := kw.v3_dot(normal, to_camera)
		if math.abs(facing) < 0.15 do continue
		back := facing < 0
		uv := foster.Vec2{0.43, 0.58}
		point := sheet_point(world.view, &world.right_sheet, uv, back)
		found, valid := pick_sheet(&world.view, &world.right_sheet, point, back)
		close := math.abs(found.x - uv.x) < 0.001 && math.abs(found.y - uv.y) < 0.001
		expect(world, valid && close, "UV picking through a full 360-degree rotation")
		if back {
			covered, _ := pick_book(world, point)
			expect(world, covered == -1, "rotated back cover prevents click-through")
		}
	}
	world.pose = saved_pose
	world.view = book_view(world.pose, 1180, 860)
	// Pausing a raised leaf must freeze both its shape and current spread.
	initial_spread := world.spread
	world.spread = 0
	begin_turn(world, 1)
	advance_turn(world, world.turn.seconds * 0.3)
	world.turn.paused = true
	frozen := world.turn.progress
	advance_turn(world, 10)
	expect(world, world.turn.progress == frozen && world.spread == 0, "paused turn does not advance")
	world.turn.paused = false
	advance_turn(world, world.turn.seconds)
	expect(world, world.spread == 1 && world.turn.direction == 0, "resumed turn settles exactly once")
	advance_turn(world, 10)
	expect(world, world.spread == 1, "settled turn cannot advance again")
	world.spread = initial_spread
	world.focus_page = right_page(world.spread)
	world.status = INITIAL_STATUS
	fmt.println("Geometry checks completed")
}

// ==============================================================================
// 帧脚本
// ==============================================================================

// 按帧号移动书、发起翻页。
test_step :: proc(world: ^World) {
	frame := world.harness.frame
	if frame == 4 {
		before := world.pose
		rotate_book(&world.pose, {32, -12}, false)
		rotate_book(&world.pose, {-10, 0}, true)
		move_book(&world.pose, {38, -18}, world.view)
		dolly_book(&world.pose, -1)
		changed := world.pose.rotation != before.rotation && world.pose.position != before.position
		expect(world, changed, "rotation, roll, pan and depth change the book pose")
	}
	switch frame {
	case 32:
		begin_turn(world, 1) // Must be ignored during the first turn.
	case 225:
		begin_turn(world, -1) // First spread boundary.
	case 230, 295:
		begin_turn(world, 1)
	case 365:
		begin_turn(world, 1) // Last spread boundary.
	}
}

// 用控件真实的 Clay 边界瞄准它；页面上的控件再经 3D 纸投影到屏幕。
// page_index < 0 表示屏幕控制栏。
test_click :: proc(
	world: ^World,
	ctx: ^ui.UI_Context,
	id: string,
	page_index: int,
	fraction: f32 = 0.5,
) {
	clay.SetCurrentContext(ctx.clay_context)
	data := clay.GetElementData(clay.ID(id))
	expect(world, data.found, fmt.tprintf("widget bounds exist: %s", id))
	if !data.found do return
	box := data.boundingBox
	point := foster.Vec2{box.x + box.width * fraction, box.y + box.height * 0.5}
	if page_index < 0 {
		world.pointer = point
		return
	}
	uv := foster.Vec2{point.x / PAGE_W, point.y / PAGE_H}
	on_left := page_index % 2 == 0
	sheet := on_left ? &world.left_sheet : &world.right_sheet
	world.pointer = sheet_point(world.view, sheet, uv, on_left)
}

// 第 `press` 帧按下、下一帧松开。
test_press :: proc(world: ^World, press: int, ctx: ^ui.UI_Context, id: string, page_index: int) {
	frame := world.harness.frame
	if frame == press || frame == press + 1 {
		test_click(world, ctx, id, page_index)
		world.pointer_down = frame == press
	}
}

// 脚本化点击，按帧号排列。
test_pointer :: proc(world: ^World) {
	pages, overlay := &world.pages, &world.overlay
	world.pointer = {-1000, -1000}
	world.pointer_down = false
	test_press(world, 8, &pages[0].ctx, "bookmark", 0)
	test_press(world, 12, &pages[1].ctx, "spell-2", 1)
	test_press(world, 16, &pages[1].ctx, "cast", 1)
	test_press(world, 24, overlay, "next", -1)
	// Try to cast again through the animated leaf: this must not activate.
	test_press(world, 32, &pages[1].ctx, "cast", 1)
	test_press(world, 94, &pages[3].ctx, "music", 3)
	// 拖动音量滑条：按住三帧后松开。
	frame := world.harness.frame
	if frame >= 100 && frame <= 103 {
		test_click(world, &pages[3].ctx, "volume", 3, 0.82)
		world.pointer_down = frame < 103
	}
	test_press(world, 108, &pages[2].ctx, "potion", 2)
	test_press(world, 120, overlay, "pause", -1)
	test_press(world, 124, overlay, "pause", -1)
	test_press(world, 150, overlay, "previous", -1)
	test_press(world, 225, overlay, "previous", -1)
	test_press(world, 360, &pages[5].ctx, "quest", 5)
	test_press(world, 365, overlay, "next", -1)
}

// 按帧号检查脚本的效果；最后一帧汇报结果并退出。
test_verify :: proc(world: ^World, app: ^foster.App) {
	s := &world.grimoire
	turn, spread := world.turn, world.spread
	settled_on :: proc(turn: Turn, spread, expected: int) -> bool {
		return spread == expected && turn.direction == 0
	}
	switch world.harness.frame {
	case 20:
		expect(world, s.chapter_bookmarked, "left-page bookmark clicked")
		expect(world, s.selected_spell == 2 && s.casts == 1, "right-page spell selection and cast clicked")
	case 40:
		expect(world, s.casts == 1, "animated page blocks underlying input")
	case 85:
		expect(world, settled_on(turn, spread, 1), "forward turn lands on spread 2")
	case 115:
		expect(world, !s.music && s.volume > 0.80, "toggle and slider on tilted right page")
		expect(world, s.potions == 1, "left-page inventory button clicked")
	case 122:
		expect(world, turn.paused, "screen overlay pause button clicked")
	case 126:
		expect(world, !turn.paused, "screen overlay resume button clicked")
	case 215:
		expect(world, settled_on(turn, spread, 0), "backward turn lands on spread 1")
		survived := s.chapter_bookmarked && s.selected_spell == 2 && s.casts == 1
		expect(world, survived, "page state survives round trip")
	case 226:
		expect(world, settled_on(turn, spread, 0), "previous boundary cannot turn")
	case 366:
		expect(world, settled_on(turn, spread, 2), "next boundary cannot turn")
		expect(world, s.quest_accepted, "last-page quest clicked")
		persisted := !s.music && s.volume > 0.80 && s.potions == 1
		expect(world, persisted, "settings and inventory persist after further turns")
		check_diagnostics(world)
		fmt.printf("Book UI smoke test: %d failures\n", world.harness.test_failures)
		foster.Exit(app)
	}
}
