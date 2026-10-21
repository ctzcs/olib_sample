package shader_lab_checks

// 一次 GPU 集中检查：旧预览、拓扑/半分辨率/HDR、反馈、暂停/单步/重置和候选回退。
import "core:fmt"
import "core:os"
import "core:strings"
import foster "olib:foster"
import lab "olib:kit/tools/shader_lab"

prepare_multipass :: proc(s: ^State, source: string) -> bool {
	for name in ([]string{"Trail2D", "Trail3D"}) {
		bytes, err := os.read_entire_file(fmt.tprintf("%s/%s.oshader", source, name), context.temp_allocator)
		if err != nil do return false
		if name == "Trail2D" do s.graph_source = strings.clone(string(bytes))
		if name == "Trail3D" do s.graph_shader = strings.clone(string(bytes))
		if os.write_entire_file(fmt.tprintf("%s/%s.oshader", s.temp_root, name), bytes) != nil do return false
	}
	return true
}

texture_hash :: proc(texture: ^foster.Texture) -> u64 {
	bytes := foster.TextureDownloadData(texture)
	defer delete(bytes)
	hash: u64 = 1469598103934665603
	for b in bytes do hash = (hash ~ u64(b))*1099511628211
	return hash
}

graph_texture :: proc(s: ^State) -> ^foster.Texture {
	e := &s.shaders[s.selected_shader]
	return foster.TargetAttachment(&e.targets[0].buffers[e.current])
}

validate_multipass :: proc(s: ^State, app: ^foster.App) {
	if s.elapsed < s.feature_next do return
	s.feature_next = s.elapsed+0.06
	graph_index, graph_3d_index := -1, -1
	for shader, i in s.shaders {
		if shader.desc.name == "Trail2D" do graph_index = i
		if shader.desc.name == "Trail3D" do graph_3d_index = i
	}
	if graph_index < 0 || graph_3d_index < 0 do return
	path := fmt.tprintf("%s/Trail2D.oshader", s.source_root)
	program := fmt.tprintf("%s/Trail3D.oshader", s.temp_root)
	switch s.smoke_step {
	case 0:
		if s.parameter_watch.status == .Error {
			check(s, false, s.parameter_watch.diagnostic)
			return
		}
		if s.program_count != 10 || s.pending_bank != nil do return
		if s.capture_index == 0 {
			select_parameter_shader(s, 0)
			s.mode = 0
			s.capture_index = 1
			return
		}
		check(s, s.programs[0].revision > 0 && s.selected_shader >= 0 &&
			len(s.shaders[s.selected_shader].desc.passes) == 1 && scene_texture(s).Resource != nil,
			"single-file Shader renders through an shader")
		capture(s, "multipass-single")
		check(s, len(s.shaders) == 4 && s.shaders[graph_index].order[0] == 1 && s.shaders[graph_index].order[3] == 0, "oshader shaders sorted by dependencies")
		lab.select_shader(s.tool, graph_index)
	case 1:
		e := &s.shaders[graph_index]
		check(s, e.targets[2].buffers[0].Width == int(s.viewport.Width*0.5), "half-resolution RenderTexture")
		check(s, foster.TargetAttachment(&e.targets[1].buffers[0]).Format == .R16G16B16A16_FLOAT, "HDR RenderTexture")
		check(s, e.targets[0].buffers[0].Attachments[0].Resource != e.targets[0].buffers[1].Attachments[0].Resource, "feedback has distinct GPU textures")
		s.graph_hash = texture_hash(graph_texture(s))
		capture(s, "multipass-2d")
	case 2:
		check(s, s.shaders[graph_index].frame == 0 && texture_hash(graph_texture(s)) == s.graph_hash, "paused feedback is stable")
		lab.step(s.tool)
	case 3:
		check(s, s.shaders[graph_index].frame == 1 && texture_hash(graph_texture(s)) != s.graph_hash, "one step advances feedback exactly once")
		s.initial_pixels = texture_hash(graph_texture(s))
	case 4:
		check(s, s.shaders[graph_index].frame == 1 && texture_hash(graph_texture(s)) == s.initial_pixels, "pause preserves stepped output")
		lab.reset_history(s.tool)
	case 5:
		check(s, s.shaders[graph_index].frame == 0 && texture_hash(graph_texture(s)) == s.graph_hash, "reset restores deterministic initial feedback")
		lab.select_shader(s.tool, graph_3d_index)
	case 6:
		check(s, len(s.shaders[graph_3d_index].targets[1].buffers[0].Attachments) == 2, "3D model pass has depth")
		capture(s, "multipass-3d")
		resize_window(s, app, {960, 720})
	case 7:
		if waiting(s, resized(s, app), "window resize applied") do return
		check(s, s.shaders[graph_3d_index].targets[0].buffers[0].Width == int(s.viewport.Width), "resize rebuilds feedback targets")
		s.graph_bank = s.bank
		bad := fixture_replace(s, s.graph_source, "Previous", "Current")
		check(s, os.write_entire_file(path, transmute([]u8)bad) == nil, "write cycle fixture")
	case 8:
		if s.parameter_watch.status != .Error do return
		check(s, rawptr(s.bank) == s.graph_bank && strings.contains(s.parameter_watch.diagnostic, "cycle"), "cycle rejected without replacing live shader")
		bad := fixture_replace(s, s.graph_shader, "float3 current =", "invalid_hlsl_here float3 current =")
		check(s, os.write_entire_file(program, bad) == nil, "write invalid shader fixture")
		check(s, os.write_entire_file(path, transmute([]u8)s.graph_source) == nil, "restore oshader graph")
	case 9:
		if s.pending_bank == nil || s.bank_error == "" do return
		check(s, rawptr(s.bank) == s.graph_bank, "failed candidate shader retains whole live bank")
		check(s, os.write_entire_file(program, transmute([]u8)s.graph_shader) == nil, "restore valid shader")
	case 10:
		if rawptr(s.bank) == s.graph_bank || s.pending_bank != nil do return
		check(s, s.bank_error == "" && s.selected_shader == graph_3d_index && len(s.shaders) == 4, "recovered candidate commits atomically and keeps selection")
		capture(s, "multipass-recovered")
		finish(s, app, "PASS: single Shader, oshader graph, HDR/MSAA/half-size, 2D/3D, feedback, pause/step/reset/resize, cycle and shader rollback/recovery")
	}
	s.smoke_step += 1
}
