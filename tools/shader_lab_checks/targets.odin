package shader_lab_checks

// 定向检查 Pass 目标生命周期与 Texture Clear，不运行完整故障注入。
import "core:fmt"
import "core:os"
import "core:strings"
import foster "olib:foster"
import lab "olib:kit/tools/shader_lab"
import clay "olib:thirdparty/clay-odin"

check_selected_targets :: proc(s: ^State, bank: ^lab.Parameter_Bank, selected: int) {
	if bank == nil do return
	for effect, i in bank.effects {
		for target in effect.targets {
			for buffer, j in target.buffers {
				if i != selected || (j == 1 && !target.history) {
					check(s, len(buffer.Attachments) == 0 && buffer.Width == 0,
						"unselected effect has no RenderTexture, resolve or depth attachments")
				}
			}
		}
	}
}

targets_declarations :: proc(s: ^State, enabled: bool) {
	for name in ([]string{"preview2d.odin", "preview3d.odin", "multipass.odin"}) {
		path := fmt.tprintf("%s/%s", s.parameter_directory, name)
		bytes, err := os.read_entire_file(path, context.temp_allocator)
		check(s, err == nil, "read isolated target fixture")
		text, _ := strings.replace_all(string(bytes), enabled ? "_Stages" : "_Passes",
			enabled ? "_Passes" : "_Stages", context.temp_allocator)
		check(s, os.write_entire_file(path, text) == nil, "toggle explicit effect declarations")
	}
	s.graph_bank = s.bank
}

validate_targets :: proc(s: ^State, app: ^foster.App) {
	if s.elapsed < s.feature_next do return
	s.feature_next = s.elapsed+0.1
	check_selected_targets(s, s.bank, s.selected_effect)
	if s.pending_bank != nil do check_selected_targets(s, s.pending_bank, lab.bank_selected_effect(s.tool, s.pending_bank))
	if s.parameter_watch.status == .Error || s.bank_error != "" {
		check(s, false, fmt.tprintf("%s %s", s.parameter_watch.diagnostic, s.bank_error))
		return
	}
	if s.shader_count != 4 || s.pending_bank != nil do return
	switch s.smoke_step {
	case 0:
		check(s, s.selected_effect >= 0 && len(s.effects[s.selected_effect].targets) == 1 &&
			scene_texture(s).Resource != nil, "single Pass supplies preview target")
		capture(s, "targets-2d")
		select_parameter_effect(s, 1)
	case 1:
		e := &s.effects[s.selected_effect]
		check(s, len(e.targets[0].buffers[0].Attachments) == 2 && scene_texture(s).SampleCount == .Four,
			"3D Pass owns depth and MSAA")
		capture(s, "targets-3d")
		for effect, i in s.effects {
			if effect.desc.name == "Trail3D" do lab.select_effect(s.tool, i)
		}
		foster.SetWindowSize(&app.Window, {960, 720})
	case 2:
		e := &s.effects[s.selected_effect]
		check(s, len(e.targets) == 4 && e.targets[0].history &&
			e.targets[0].buffers[0].Width == int(s.viewport.Width) &&
			e.targets[2].buffers[0].Width == int(s.viewport.Width*0.5), "resized multipass uses declared target sizes")
		capture(s, "targets-multipass")
		lab.step(s.tool)
	case 3:
		check(s, s.effects[s.selected_effect].frame == 1, "feedback advances before switching away")
		s.effects[s.selected_effect].expanded[2] = false
		s.parameters[2].values[2].number[0] = 7
		lab.select_workspace(s.tool, 0)
	case 4:
		check(s, s.selected_effect >= 0 && s.effects[s.selected_effect].ready, "2D workspace allocates only its selected effect")
		press_widget(s, app, "workspace:3d", 0.5)
	case 5:
		if s.capture_index == 0 {
			foster.InputMouseButton(&app.Input, .Left, false, app.Time.Elapsed)
			s.capture_index = 1
			s.target_release_serial = int(s.render_serial)
			return // 按钮在 release 帧的 panel 中切换，下一轮再读取渲染结果。
		}
		// 切换帧提交 UI 后释放旧目标，下一渲染帧才创建新目标；不要以墙钟时间推测帧数。
		if int(s.render_serial) < s.target_release_serial+2 do return
		check(s, s.effects[s.selected_effect].desc.name == "Trail3D" && s.effects[s.selected_effect].ready &&
			s.effects[s.selected_effect].frame == 0 && !s.effects[s.selected_effect].expanded[2] &&
			s.parameters[2].values[2].number[0] == 7, "switch back recreates history while retaining parameters and folding")
		if s.failed {
			fmt.printf("effect=%s ready=%v frame=%d expanded=%v radius=%v\n",
				s.effects[s.selected_effect].desc.name, s.effects[s.selected_effect].ready,
				s.effects[s.selected_effect].frame, s.effects[s.selected_effect].expanded[2], s.parameters[2].values[2].number[0])
		}
		s.graph_bank = s.bank
		renamed, _ := strings.replace_all(s.graph_source, "二维拖尾", "拖尾二维", context.temp_allocator)
		check(s, os.write_entire_file(fmt.tprintf("%s/multipass.odin", s.parameter_directory), renamed) == nil,
			"reload effect declarations with an active selection")
	case 6:
		if rawptr(s.bank) == s.graph_bank do return
		check(s, s.effects[s.selected_effect].desc.name == "Trail3D" && s.effects[s.selected_effect].ready,
			"candidate bank commits only the selected effect targets")
		targets_declarations(s, false)
	case 7:
		if rawptr(s.bank) == s.graph_bank do return
		check(s, len(s.effects) == 0 && s.workspace_empty && s.selected_effect == -1,
			"removing effects leaves an empty workspace")
		for shader, i in s.shaders[:s.shader_count] {
			check(s, !s.bank.shader_used[i] && shader.status == .Ready &&
				shader.vertex.Resource == nil && shader.fragment.Resource == nil,
				"unused Shader remains compiled without GPU pipeline or fallback target")
		}
		pixels := foster.TextureDownloadData(foster.TargetAttachment(&s.output))
		defer delete(pixels)
		pixel := (int(s.viewport.Y+s.viewport.Height/2)*s.output.Width+int(s.viewport.X+s.viewport.Width/2))*4
		check(s, pixels[pixel] == 17 && pixels[pixel+1] == 21 && pixels[pixel+2] == 26,
			"empty preview background is drawn into final output")
		capture(s, "targets-empty")
		targets_declarations(s, true)
	case 8:
		if rawptr(s.bank) == s.graph_bank do return
		check(s, len(s.effects) == 4 && !s.workspace_empty && scene_texture(s).Resource != nil,
			"restoring effects resumes Pass rendering")
		for shader, i in s.shaders[:s.shader_count] {
			check(s, shader.status == (s.bank.shader_used[i] ? .Live : .Ready),
				"only selected effect Shaders require GPU pipeline validation")
		}
		select_parameter_effect(s, 0)
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
		press_widget(s, app, "texture:Preview2D:image", 0.5)
	case 11, 14:
		foster.InputMouseButton(&app.Input, .Left, false, app.Time.Elapsed)
	case 13:
		check(s, s.parameters[0].texture_picker == "image", "texture card opens image actions")
		press_widget(s, app, "texture-default", 0.5)
	case 15:
		check(s, s.parameters[0].values[s.feature_texture].texture == "" && s.parameters[0].textures[0].Resource == nil &&
			len(s.retired_textures) == 0 && s.ctx.error_count == 0, "Clear safely restores checker and releases retired texture after UI submission")
		capture(s, "texture-cleared")
		if !s.failed do fmt.println("PASS: selected-only targets, switch/recreate, history reset, hot reload, empty workspace and real Texture Clear")
		foster.Exit(app)
	}
	s.smoke_step += 1
}
