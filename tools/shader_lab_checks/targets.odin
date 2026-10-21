package shader_lab_checks

// 定向检查 Pass 目标生命周期与 Texture Clear，不运行完整故障注入。
import "core:fmt"
import "core:os"
import foster "olib:foster"
import lab "olib:kit/tools/shader_lab"
import clay "olib:thirdparty/clay-odin"

check_selected_targets :: proc(s: ^State, bank: ^lab.Parameter_Bank, selected: int) {
	if bank == nil do return
	for shader, i in bank.shaders {
		for target in shader.targets {
			for buffer, j in target.buffers {
				if i != selected || (j == 1 && !target.history) {
					check(s, len(buffer.Attachments) == 0 && buffer.Width == 0,
						"unselected shader has no RenderTexture, resolve or depth attachments")
				}
			}
		}
	}
}

targets_declarations :: proc(s: ^State, enabled: bool) {
	for name in ([]string{"Preview2D", "Preview3D", "Trail2D", "Trail3D"}) {
		active := fmt.tprintf("%s/%s.oshader", s.source_root, name)
		hidden := fmt.tprintf("%s/%s.disabled", s.source_root, name)
		check(s, os.rename(enabled ? hidden : active, enabled ? active : hidden) == nil, "toggle shader discovery")
	}
	s.graph_bank = s.bank
}

validate_targets :: proc(s: ^State, app: ^foster.App) {
	if s.elapsed < s.feature_next do return
	s.feature_next = s.elapsed+0.1
	check_selected_targets(s, s.bank, s.selected_shader)
	if s.pending_bank != nil do check_selected_targets(s, s.pending_bank, lab.bank_selected_shader(s.tool, s.pending_bank))
	if s.parameter_watch.status == .Error || s.bank_error != "" {
		check(s, false, fmt.tprintf("%s %s", s.parameter_watch.diagnostic, s.bank_error))
		return
	}
	if s.pending_bank != nil || (s.program_count != 10 && s.smoke_step != 7) do return
	switch s.smoke_step {
	case 0:
		check(s, s.selected_shader >= 0 && len(s.shaders[s.selected_shader].targets) == 1 &&
			scene_texture(s).Resource != nil, "single Pass supplies preview target")
		capture(s, "targets-2d")
		select_parameter_shader(s, 1)
	case 1:
		e := &s.shaders[s.selected_shader]
		check(s, len(e.targets[0].buffers[0].Attachments) == 2 && scene_texture(s).SampleCount == .Four,
			"3D Pass owns depth and MSAA")
		capture(s, "targets-3d")
		for shader, i in s.shaders {
			if shader.desc.name == "Trail3D" do lab.select_shader(s.tool, i)
		}
		resize_window(s, app, {960, 720})
	case 2:
		if waiting(s, resized(s, app), "window resize applied") do return
		// 单步要在已就绪的效果上推进，否则那次渲染只会丢弃单步请求。
		if waiting(s, s.shaders[s.selected_shader].ready, "Trail3D drawn at the resized output") do return
		e := &s.shaders[s.selected_shader]
		check(s, len(e.targets) == 4 && e.targets[0].history &&
			e.targets[0].buffers[0].Width == int(s.viewport.Width) &&
			e.targets[2].buffers[0].Width == int(s.viewport.Width*0.5), "resized multipass uses declared target sizes")
		capture(s, "targets-multipass")
		lab.step(s.tool)
	case 3:
		check(s, s.shaders[s.selected_shader].frame == 1, "feedback advances before switching away")
		s.shaders[s.selected_shader].expanded[2] = false
		s.parameters[lab.bank_index(s.bank, "Trail3D_blur_x")].values[2].number[0] = 7
		lab.select_workspace(s.tool, 0)
	case 4:
		check(s, s.selected_shader >= 0 && s.shaders[s.selected_shader].ready, "2D workspace allocates only its selected shader")
		press_widget(s, app, "workspace:3d", 0.5)
	case 5:
		if s.capture_index == 0 {
			release_pointer(s, app)
			s.capture_index = 1
			return // 按钮在消费松开的那次渲染的 panel 中切换，下一轮再读取结果。
		}
		// 切换那次渲染提交 UI 后才释放旧目标，下一次渲染才为 Trail3D 重建目标；等它就绪，不数帧。
		if waiting(s, s.selected_shader >= 0 && s.shaders[s.selected_shader].ready, "switched shader targets recreated") do return
		check(s, s.shaders[s.selected_shader].desc.name == "Trail3D" && s.shaders[s.selected_shader].ready &&
			s.shaders[s.selected_shader].frame == 0 && !s.shaders[s.selected_shader].expanded[2] &&
			s.parameters[lab.bank_index(s.bank, "Trail3D_blur_x")].values[2].number[0] == 7, "switch back recreates history while retaining parameters and folding")
		if s.failed {
			fmt.printf("shader=%s ready=%v frame=%d expanded=%v radius=%v\n",
				s.shaders[s.selected_shader].desc.name, s.shaders[s.selected_shader].ready,
				s.shaders[s.selected_shader].frame, s.shaders[s.selected_shader].expanded[2], s.parameters[lab.bank_index(s.bank, "Trail3D_blur_x")].values[2].number[0])
		}
		s.graph_bank = s.bank
		renamed := fixture_replace(s, s.graph_source, "二维拖尾", "拖尾二维")
		check(s, os.write_entire_file(fmt.tprintf("%s/Trail2D.oshader", s.source_root), renamed) == nil,
			"reload shader declarations with an active selection")
	case 6:
		if rawptr(s.bank) == s.graph_bank do return
		check(s, s.shaders[s.selected_shader].desc.name == "Trail3D" && s.shaders[s.selected_shader].ready,
			"candidate bank commits only the selected shader targets")
		targets_declarations(s, false)
	case 7:
		if rawptr(s.bank) == s.graph_bank do return
		check(s, len(s.shaders) == 0 && s.workspace_empty && s.selected_shader == -1,
			"removing shaders leaves an empty workspace")
		check(s, s.program_count == 0, "removed files release shader resources")
		pixels := foster.TextureDownloadData(foster.TargetAttachment(&s.output))
		defer delete(pixels)
		pixel := (int(s.viewport.Y+s.viewport.Height/2)*s.output.Width+int(s.viewport.X+s.viewport.Width/2))*4
		check(s, pixels[pixel] == 17 && pixels[pixel+1] == 21 && pixels[pixel+2] == 26,
			"empty preview background is drawn into final output")
		capture(s, "targets-empty")
		targets_declarations(s, true)
	case 8:
		if rawptr(s.bank) == s.graph_bank do return
		check(s, len(s.shaders) == 4 && !s.workspace_empty && scene_texture(s).Resource != nil,
			"restoring shaders resumes Pass rendering")
		for program, i in s.programs[:s.program_count] {
			check(s, program.status == (s.bank.program_used[i] ? .Live : .Ready),
				"only selected shader Shaders require GPU pipeline validation")
		}
		select_parameter_shader(s, 0)
		feature_image(s, foster.Red)
		for field, i in s.parameters[0].live.fields {
			if field.kind == .Texture do s.feature_texture = i
		}
		lab.parameter_texture_set(s.tool, 0, s.feature_texture, fmt.tprintf("%s/feature.png", s.temp_root))
	case 9, 12:
		data := clay.GetScrollContainerData(clay.ID(lab.inspector_scroll_id(s.tool)))
		check(s, data.found, "parameter scroll exists for texture controls")
		if data.found do data.scrollPosition.y = -10000
	case 10:
		press_widget(s, app, "texture:Preview2D_main:image", 0.5)
	case 11, 14:
		release_pointer(s, app)
	case 13:
		check(s, s.parameters[0].texture_picker == "image", "texture card opens image actions")
		press_widget(s, app, "texture-default", 0.5)
	case 15:
		check(s, s.parameters[0].values[s.feature_texture].texture == "" && s.parameters[0].textures[0].Resource == nil &&
			len(s.retired_textures) == 0 && s.ctx.error_count == 0, "Clear safely restores checker and releases retired texture after UI submission")
		capture(s, "texture-cleared")
		finish(s, app, "PASS: selected-only targets, switch/recreate, history reset, hot reload, empty workspace and real Texture Clear")
	}
	s.smoke_step += 1
}
