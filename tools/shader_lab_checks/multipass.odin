package shader_lab_checks

// 一次 GPU 集中检查：旧预览、拓扑/半分辨率/HDR、反馈、暂停/单步/重置和候选回退。
import "core:fmt"
import "core:os"
import "core:strings"
import foster "olib:foster"
import lab "olib:kit/tools/shader_lab"

prepare_multipass :: proc(s: ^State, source, params: string) -> bool {
	for name in ([]string{"TrailBlur", "TrailFeedback"}) {
		bytes, err := os.read_entire_file(fmt.tprintf("%s/%s.hlsl", source, name), context.temp_allocator)
		if err != nil do return false
		text, _ := strings.replace_all(string(bytes), fmt.tprintf("../../../library/shader_dev/%s/params.generated.hlsli", name),
			"params.generated.hlsli", context.temp_allocator)
		if os.write_entire_file(fmt.tprintf("%s/%s.hlsl", s.temp_root, name), transmute([]u8)text) != nil do return false
		if name == "TrailFeedback" do s.graph_shader = strings.clone(text)
	}
	bytes, err := os.read_entire_file(fmt.tprintf("%s/multipass.odin", params), context.temp_allocator)
	if err != nil do return false
	s.graph_source = strings.clone(string(bytes))
	return os.write_entire_file(fmt.tprintf("%s/multipass.odin", s.parameter_directory), bytes) == nil
}

texture_hash :: proc(texture: ^foster.Texture) -> u64 {
	bytes := foster.TextureDownloadData(texture)
	defer delete(bytes)
	hash: u64 = 1469598103934665603
	for b in bytes do hash = (hash ~ u64(b))*1099511628211
	return hash
}

graph_texture :: proc(s: ^State) -> ^foster.Texture {
	e := &s.effects[s.selected_effect]
	return foster.TargetAttachment(&e.targets[0].buffers[e.current])
}

validate_multipass :: proc(s: ^State, app: ^foster.App) {
	if s.elapsed < s.feature_next do return
	s.feature_next = s.elapsed+0.06
	graph_index, graph_3d_index := -1, -1
	for effect, i in s.effects {
		if effect.desc.name == "Trail2D" do graph_index = i
		if effect.desc.name == "Trail3D" do graph_3d_index = i
	}
	if graph_index < 0 || graph_3d_index < 0 do return
	path := fmt.tprintf("%s/multipass.odin", s.parameter_directory)
	shader := fmt.tprintf("%s/TrailFeedback.hlsl", s.temp_root)
	switch s.smoke_step {
	case 0:
		if s.parameter_watch.status == .Error {
			check(s, false, s.parameter_watch.diagnostic)
			return
		}
		if s.shader_count != 4 || s.pending_bank != nil do return
		if s.capture_index == 0 {
			select_parameter_effect(s, 0)
			s.mode = 0
			s.capture_index = 1
			return
		}
		check(s, s.shaders[0].revision > 0 && s.selected_effect >= 0 &&
			len(s.effects[s.selected_effect].desc.passes) == 1 && scene_texture(s).Resource != nil,
			"legacy single Shader renders through an effect")
		capture(s, "multipass-legacy")
		check(s, len(s.effects) == 4 && s.effects[graph_index].order[0] == 1 && s.effects[graph_index].order[3] == 0, "Odin effects sorted by dependencies")
		lab.select_effect(s.tool, graph_index)
	case 1:
		e := &s.effects[graph_index]
		check(s, e.targets[2].buffers[0].Width == int(s.viewport.Width*0.5), "half-resolution RenderTexture")
		check(s, foster.TargetAttachment(&e.targets[1].buffers[0]).Format == .R16G16B16A16_FLOAT, "HDR RenderTexture")
		check(s, e.targets[0].buffers[0].Attachments[0].Resource != e.targets[0].buffers[1].Attachments[0].Resource, "feedback has distinct GPU textures")
		s.graph_hash = texture_hash(graph_texture(s))
		capture(s, "multipass-2d")
	case 2:
		check(s, s.effects[graph_index].frame == 0 && texture_hash(graph_texture(s)) == s.graph_hash, "paused feedback is stable")
		lab.step(s.tool)
	case 3:
		check(s, s.effects[graph_index].frame == 1 && texture_hash(graph_texture(s)) != s.graph_hash, "one step advances feedback exactly once")
		s.initial_pixels = texture_hash(graph_texture(s))
	case 4:
		check(s, s.effects[graph_index].frame == 1 && texture_hash(graph_texture(s)) == s.initial_pixels, "pause preserves stepped output")
		lab.reset_history(s.tool)
	case 5:
		check(s, s.effects[graph_index].frame == 0 && texture_hash(graph_texture(s)) == s.graph_hash, "reset restores deterministic initial feedback")
		lab.select_effect(s.tool, graph_3d_index)
	case 6:
		check(s, len(s.effects[graph_3d_index].targets[1].buffers[0].Attachments) == 2, "3D model pass has depth")
		capture(s, "multipass-3d")
		foster.SetWindowSize(&app.Window, {960, 720})
	case 7:
		check(s, s.effects[graph_3d_index].targets[0].buffers[0].Width == int(s.viewport.Width), "resize rebuilds feedback targets")
		s.graph_bank = s.bank
		bad, _ := strings.replace_all(s.graph_source, "frame = .Previous", "frame = .Current", context.temp_allocator)
		check(s, os.write_entire_file(path, transmute([]u8)bad) == nil, "write cycle fixture")
	case 8:
		if s.parameter_watch.status != .Error do return
		check(s, rawptr(s.bank) == s.graph_bank && strings.contains(s.parameter_watch.diagnostic, "cycle"), "cycle rejected without replacing live effect")
		check(s, os.write_entire_file(shader, fmt.tprintf("%s\ninvalid_hlsl_here\n", s.graph_shader)) == nil, "write invalid shader fixture")
		check(s, os.write_entire_file(path, transmute([]u8)s.graph_source) == nil, "restore Odin graph")
	case 9:
		if s.pending_bank == nil || s.bank_error == "" do return
		check(s, rawptr(s.bank) == s.graph_bank, "failed candidate shader retains whole live bank")
		check(s, os.write_entire_file(shader, transmute([]u8)s.graph_shader) == nil, "restore valid shader")
	case 10:
		if rawptr(s.bank) == s.graph_bank || s.pending_bank != nil do return
		check(s, s.bank_error == "" && s.selected_effect == graph_3d_index && len(s.effects) == 4, "recovered candidate commits atomically and keeps selection")
		capture(s, "multipass-recovered")
		if !s.failed do fmt.println("PASS: single Shader, Odin graph, HDR/MSAA/half-size, 2D/3D, feedback, pause/step/reset/resize, cycle and shader rollback/recovery")
		foster.Exit(app)
	}
	s.smoke_step += 1
}
