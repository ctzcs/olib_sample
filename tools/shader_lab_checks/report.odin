package shader_lab_checks

// 失败诊断：每次 Update 记录窗口与候选包的状态变化，第一次失败把完整状态写进
// library/tmp/program-lab-<模式>-failure.txt（同模式复用文件名，开始运行时删除旧报告）。
import "core:fmt"
import "core:os"
import "core:strings"

import foster "olib:foster"
import dev "olib:kit/rendering/shader/dev"
import lab "olib:kit/tools/shader_lab"
import imgui "olib:thirdparty/imgui"
import SDL "vendor:sdl3"

@(private="file")
EVENT_LIMIT :: 400

Watched :: struct {
	size, pixels, position: foster.Point2,
	flags: SDL.WindowFlags,
	bank, pending: rawptr,
	watch_status: dev.Status,
	bank_error: string,
}

mode_name :: proc(s: ^State) -> string {
	switch {
	case s.targets: return "targets"
	case s.hierarchy: return "hierarchy"
	case s.multipass: return "multipass"
	case s.features: return "features"
	case s.color_smoke: return "colors"
	case s.smoke: return "smoke"
	}
	return "shot"
}

report_path :: proc(s: ^State) -> string {
	return fmt.tprintf("%s/../../library/tmp/shader-lab-%s-failure.txt", #directory, mode_name(s))
}

log_event :: proc(s: ^State, format: string, args: ..any) {
	if len(s.events) >= EVENT_LIMIT {
		delete(s.events[0])
		ordered_remove(&s.events, 0)
	}
	append(&s.events, fmt.aprintf("%8.3fs update %d render %d step %d/%d/%d  %s", s.elapsed, s.update_count,
		s.render_serial, s.smoke_step, s.capture_index, s.material_step, fmt.tprintf(format, ..args)))
}

// 外部最大化、最小化、失焦或改尺寸会让注入坐标与截图失效；候选包变化说明热重载走到了哪一步。
watch :: proc(s: ^State, app: ^foster.App) {
	w := &s.watched
	flags := SDL.GetWindowFlags(app.Window.Handle) &
		SDL.WindowFlags{.MINIMIZED, .MAXIMIZED, .FULLSCREEN, .HIDDEN, .OCCLUDED, .INPUT_FOCUS, .MOUSE_FOCUS}
	size, pixels, position := foster.Size(&app.Window), foster.SizeInPixels(&app.Window), foster.Position(&app.Window)
	if size != w.size || pixels != w.pixels || position != w.position || flags != w.flags {
		w.size, w.pixels, w.position, w.flags = size, pixels, position, flags
		log_event(s, "window %dx%d (pixels %dx%d) at %d,%d %v", size.X, size.Y, pixels.X, pixels.Y, position.X, position.Y, flags)
	}
	if rawptr(s.bank) != w.bank {
		w.bank = s.bank
		log_event(s, "live bank: %d shaders, %d shaders", s.program_count, len(s.shaders))
	}
	if rawptr(s.pending_bank) != w.pending {
		w.pending = s.pending_bank
		log_event(s, s.pending_bank == nil ? "candidate bank cleared" : "candidate bank created")
	}
	if s.parameter_watch.status != w.watch_status {
		w.watch_status = s.parameter_watch.status
		log_event(s, "declaration watch %v", w.watch_status)
	}
	if s.bank_error != w.bank_error {
		delete(w.bank_error)
		w.bank_error = strings.clone(s.bank_error)
		log_event(s, "bank error %q", first_line(s.bank_error))
	}
}

// 第一次失败写完整快照，之后的失败只追加 FAIL 行。
report_failure :: proc(s: ^State, message: string) {
	first := s.report == ""
	next: string
	if first {
		b := strings.builder_make()
		report_state(&b, s, message)
		next = strings.to_string(b)
	} else {
		next = fmt.aprintf("%sFAIL: %s\n", s.report, message)
		delete(s.report)
	}
	s.report = next
	path := report_path(s)
	_ = os.make_directory_all(fmt.tprintf("%s/../../library/tmp", #directory))
	if os.write_entire_file(path, s.report) == nil && first {
		fmt.eprintln("Shader Lab diagnostics:", path)
	}
}

@(private="file")
report_state :: proc(b: ^strings.Builder, s: ^State, message: string) {
	fmt.sbprintf(b, "Shader Lab %s validation failure\nFAIL: %s\n\n", mode_name(s), message)
	fmt.sbprintf(b, "sources: %s (kept after a failed run)\n", s.temp_root)
	fmt.sbprintf(b, "time: %.3fs, update %d, render %d (validated %d)\n", s.elapsed, s.update_count, s.render_serial, s.validated_serial)
	fmt.sbprintf(b, "step: smoke_step %d, capture_index %d, material_step %d\n", s.smoke_step, s.capture_index, s.material_step)
	if s.wait_reason != "" do fmt.sbprintf(b, "waiting for: %s (since %.3fs)\n", s.wait_reason, s.wait_since)
	fmt.sbprintf(b, "injected input: pending %v, sent at update %d, entered State before render %d, key edge %v %v\n",
		s.input_pending, s.input_update, s.input_applied, s.input_key_edge, s.input_key)
	if s.app != nil {
		mouse := &s.app.Input.State.Mouse
		fmt.sbprintf(b, "input state: mouse %.1f,%.1f left %v, enabled %v\n", mouse.Position.X, mouse.Position.Y,
			foster.MouseDown(mouse, .Left), s.app.Input.Enabled)
	}
	w := s.watched
	fmt.sbprintf(b, "window: %dx%d (pixels %dx%d) at %d,%d %v; requested %dx%d\n", w.size.X, w.size.Y,
		w.pixels.X, w.pixels.Y, w.position.X, w.position.Y, w.flags, s.resize_to.X, s.resize_to.Y)
	io := imgui.GetIO()
	fmt.sbprintf(b, "output %dx%d, preview viewport %v, pointer %v\n", s.final.Width, s.final.Height, s.viewport, s.pointer)
	fmt.sbprintf(b, "imgui: mouse %.1f,%.1f down %v, any item active %v, wants mouse %v, shader menu %v, color picker %v, %d widgets\n",
		io.MousePos.x, io.MousePos.y, io.MouseDown[0], imgui.IsAnyItemActive(), io.WantCaptureMouse,
		s.shader_menu, s.color_picker.open, len(s.widgets))
	fmt.sbprintf(b, "session: workspace %d (empty %v), shader %d, inspect pass %d, preview pass %d, group %d, mode %d, paused %v, clock %.3f, yaw %.3f\n",
		s.workspace, s.workspace_empty, s.selected_shader, s.inspect_pass, s.preview_pass, s.selected, s.mode, s.paused, s.clock, s.yaw)
	report_bank(b, "live bank", s.bank)
	report_bank(b, "candidate bank", s.pending_bank)
	fmt.sbprintf(b, "bank error: %q\n", s.bank_error)
	fmt.sbprintf(b, "declaration watch: %v %q\n", s.parameter_watch.status, s.parameter_watch.diagnostic)
	fmt.sbprintf(b, "\nevents (latest %d):\n", len(s.events))
	for event in s.events do fmt.sbprintf(b, "  %s\n", event)
	fmt.sbprintf(b, "\n")
}

@(private="file")
report_bank :: proc(b: ^strings.Builder, label: string, bank: ^lab.Parameter_Bank) {
	if bank == nil do return
	fmt.sbprintf(b, "%s: %d shaders, %d shaders, fingerprint %x, candidate failed %v\n", label,
		bank.program_count, len(bank.shaders), bank.fingerprint, bank.candidate_failed)
	for p, i in bank.parameters[:bank.program_count] {
		program := &bank.programs[i]
		fmt.sbprintf(b, "  shader %s: %v revision %d used %v", p.name, program.status, program.revision, bank.program_used[i])
		if program.diagnostic != "" do fmt.sbprintf(b, " diagnostic %q", program.diagnostic)
		fmt.sbprintf(b, "\n")
	}
	for &e in bank.shaders {
		fmt.sbprintf(b, "  shader %s: ready %v, frame %d, current %d", e.desc.name, e.ready, e.frame, e.current)
		for &target, i in e.targets {
			buffer := &target.buffers[0]
			fmt.sbprintf(b, "; pass %d %dx%d x%d enabled %v expanded %v", i, buffer.Width, buffer.Height,
				len(buffer.Attachments), e.enabled[i], e.expanded[i])
		}
		fmt.sbprintf(b, "\n")
	}
}

@(private="file")
first_line :: proc(text: string) -> string {
	end := strings.index_byte(text, '\n')
	return end < 0 ? text : text[:end]
}
