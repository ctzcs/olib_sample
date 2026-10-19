package shader_lab_checks

// 示例专用截图/故障注入；游戏编辑器只 import shader_lab，不依赖这个包。
import "core:fmt"

import foster "olib:foster"
import lab "olib:kit/tools/shader_lab"

State :: struct {
	using tool: ^lab.Session,
	features: bool,
	multipass: bool,
	hierarchy: bool,
	targets: bool,
	graph_source, graph_shader: string,
	graph_bank: rawptr,
	graph_hash: u64,
	fixed_pass_y, fixed_tabs_y, saved_scroll_y: f32,
	feature_prepare, feature_draw: int,
	feature_texture: int,
	feature_next: f64,
	shot, smoke, color_smoke, color_test_blur, failed: bool,
	capture_index, smoke_step, validated_serial: int,
	target_release_serial: int,
	parameter_source, binding_source, temp_root: string,
	parameter_revision: u64,
	initial_resources: [2]rawptr,
	initial_pixels, initial_2d_pixels: u64,
	elapsed: f64,
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
	s.elapsed += f64(app.Time.Delta)
	if s.output.Width > 0 do validate_frame(s, app)
	if s.elapsed > 120 {
		s.failed = true
		fmt.eprintln("FAIL: shader lab timed out")
		foster.Exit(app)
	}
}

// 必须在 lab.dispose 前调用，因为测试仍读取工具的临时路径。
dispose :: proc(s: ^State) {
	cleanup_smoke(s)
	delete(s.parameter_source)
	delete(s.graph_source)
	delete(s.binding_source)
	delete(s.graph_shader)
}
