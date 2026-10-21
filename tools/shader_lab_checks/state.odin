package shader_lab_checks

// 示例专用截图/故障注入；游戏编辑器只 import shader_lab，不依赖这个包。
import "core:fmt"
import "core:os"

import foster "olib:foster"
import lab "olib:kit/tools/shader_lab"

State :: struct {
	using tool: ^lab.Session,
	app: ^foster.App, // 第一次 update 时记录，输入注入与失败诊断使用
	final: ^foster.Target, // 宿主的最终输出（背景 + ImGui），截图和像素检查读取它
	features: bool,
	multipass: bool,
	hierarchy: bool,
	targets: bool,
	graph_source, graph_shader: string,
	graph_bank: rawptr,
	graph_hash: u64,
	fixed_pass, fixed_tabs: lab.Widget_Rect, // 浮层 / 页签切换前记下的控件位置
	preview_width: f32,
	feature_record: int,
	feature_template, feature_template_written: int, // 新建着色器步骤：当前模板与已写出的模板（+1）
	feature_builtin: u64,
	feature_texture: int,
	feature_next: f64,
	shot, smoke, color_smoke, color_test_blur, failed: bool,
	done: bool, // 走到最后一步（见 finish）
	capture_index, smoke_step, validated_serial: int,
	material_step: int, // shot 最后一步：0 表示还没切到 2D 材质 Shader
	parameter_source, binding_source, temp_root: string,
	parameter_revision: u64,
	initial_resources: [2]rawptr,
	initial_pixels, initial_2d_pixels: u64,
	elapsed: f64,
	// 注入写进 NextState：下一次 Update 的 InputStep 才进入 State，之后的渲染里 UI 才看到（见 input_track）。
	update_count, input_update, input_applied: int,
	input_pending, input_key_edge: bool,
	input_key: foster.Keys,
	resize_to: foster.Point2,
	resize_serial: int,
	wait_reason: string, // 只存字面量
	wait_since: f64,
	watched: Watched,
	events: [dynamic]string,
	report: string,
}

// 在 lab.init 之前调用；隔离测试源码，生成的临时路径在 dispose 时释放。
prepare :: proc(s: ^State, tool: ^lab.Session, source: string,
	shot, smoke, colors: bool, multipass: bool = false) -> bool {
	s.tool = tool
	s.shot = shot
	s.color_smoke = colors
	s.smoke = smoke || colors || multipass
	s.multipass = multipass
	tool.source_root = source
	if s.smoke || s.shot {
		if !prepare_smoke(s) do return false
		if multipass && !prepare_multipass(s, source) do return false
	}
	return true
}

update :: proc(s: ^State, app: ^foster.App) {
	if !s.shot && !s.smoke do return
	s.update_count += 1
	if s.app == nil {
		s.app = app
		// 失败报告只描述最近一次运行；main 设置完模式标志后这里才知道文件名。
		_ = os.remove(report_path(s))
		isolate_input(s, app)
	}
	input_track(s, app)
	watch(s, app)
	s.elapsed += f64(app.Time.Delta)
	if s.final != nil && s.final.Width > 0 do validate_frame(s, app)
	if s.elapsed > 120 {
		if !s.failed {
			pending := s.wait_reason == "" ? "no explicit wait pending" :
				fmt.tprintf("waiting for %s since %.1fs", s.wait_reason, s.wait_since)
			check(s, false, fmt.tprintf("shader lab timed out (%s)", pending))
		}
		foster.Exit(app)
	}
}

// 条件不满足时记下正在等待的明确状态并返回 true；超时诊断据此说明卡在哪里。
waiting :: proc(s: ^State, condition: bool, what: string) -> bool {
	if condition {
		if s.wait_reason == what do s.wait_reason = ""
		return false
	}
	if s.wait_reason != what {
		s.wait_reason = what
		s.wait_since = s.elapsed
		log_event(s, "wait: %s", what)
	}
	return true
}

// 必须在 lab.dispose 前调用，因为测试仍读取工具的临时路径。
dispose :: proc(s: ^State) {
	// 关闭窗口时宿主照常退出、返回 0；验证没走完就算失败，否则会被当成通过。
	if s.app != nil && !s.done && !s.failed do check(s, false, "validation exited before its last step (window closed?)")
	cleanup_smoke(s)
	delete(s.parameter_source)
	delete(s.graph_source)
	delete(s.binding_source)
	delete(s.graph_shader)
	for event in s.events do delete(event)
	delete(s.events)
	delete(s.report)
	delete(s.watched.bank_error)
}
