package shader_lab_checks

// 只覆盖本次层级、真实 checkbox/folder 交互和显示名热改，不重复完整多 Pass 故障注入。
import "core:fmt"
import "core:os"
import "core:strings"
import foster "olib:foster"
import lab "olib:kit/tools/shader_lab"

validate_hierarchy :: proc(s: ^State, app: ^foster.App) {
	if s.elapsed < s.feature_next do return
	s.feature_next = s.elapsed+0.08
	if s.parameter_watch.status == .Error {
		check(s, false, s.parameter_watch.diagnostic)
		return
	}
	if s.program_count < 10 || s.pending_bank != nil do return
	graph_index, graph_3d_index := -1, -1
	for shader, i in s.shaders {
		if shader.desc.name == "Trail2D" do graph_index = i
		if shader.desc.name == "Trail3D" do graph_3d_index = i
	}
	e := &s.shaders[graph_index]
	p := &s.parameters[lab.bank_index(s.bank, "Trail2D_blur_x")]
	target := &e.targets[2].buffers[0]
	switch s.smoke_step {
	case 0:
		check(s, s.selected_shader == 0 && s.preview_pass == -1, "start with shader and final output")
		check(s, e.desc.name == "Trail2D" && e.desc.label == "二维拖尾" &&
			p.live.label == "横向模糊", "Pass labels independent of IDs")
		check(s, !s.fonts_dirty && s.missing_glyphs == 0, "Chinese shader and Pass labels are in the ImGui font")
		lab.select_shader(s.tool, graph_index, 2)
	case 1:
		s.graph_hash = texture_hash(foster.TargetAttachment(target))
		capture(s, "hierarchy-2d")
		press_widget(s, app, "group-folder:Trail2D:blur_x", 0.5)
	case 2, 4, 6, 8:
		release_pointer(s, app)
	case 3:
		if s.preview_pass != -1 || s.inspect_pass != 2 || !p.folder_closed {
			fmt.printf("Folder click state: preview=%d inspect=%d closed=%v pointer=%v\n",
				s.preview_pass, s.inspect_pass, p.folder_closed, s.pointer)
		}
		check(s, s.preview_pass == -1 && s.inspect_pass == 2, "editing a Pass preserves final output")
		check(s, p.folder_closed && e.enabled[2] && texture_hash(foster.TargetAttachment(target)) == s.graph_hash,
			"Shader folder collapse only affects UI")
		press_widget(s, app, "pass-enabled:Trail2D:blur_x", 0.5)
	case 5:
		check(s, !e.enabled[2] && texture_hash(foster.TargetAttachment(target)) != s.graph_hash,
			"checkbox disables blur and bypasses current input")
		press_widget(s, app, "pass-enabled:Trail2D:blur_x", 0.5)
	case 7:
		check(s, e.enabled[2] && texture_hash(foster.TargetAttachment(target)) == s.graph_hash,
			"checkbox restores deterministic shader output")
		press_widget(s, app, "pass:blur_x", 0.5)
	case 9:
		check(s, !e.expanded[2] && e.enabled[2], "Pass collapse does not disable rendering")
		lab.set_pass_enabled(s.tool, graph_index, 2, false)
		p.values[2].number[0] = 4.5
		s.graph_bank = s.bank
		renamed := fixture_replace(s, s.graph_source, "二维拖尾", "拖尾二维")
		check(s, os.write_entire_file(fmt.tprintf("%s/Trail2D.oshader", s.source_root), transmute([]u8)renamed) == nil,
			"rename shader label fixture")
	case 10:
		if rawptr(s.bank) == s.graph_bank do return
		if s.selected_shader != graph_index || s.inspect_pass != 2 || e.desc.label != "拖尾二维" ||
			e.enabled[2] || e.expanded[2] || !p.folder_closed || p.values[2].number[0] != 4.5 {
			fmt.printf("Reload state: selected=%d graph=%d pass=%d label=%s enabled=%v expanded=%v folder=%v value=%v\n",
				s.selected_shader, graph_index, s.inspect_pass, e.desc.label, e.enabled[2], e.expanded[2], p.folder_closed, p.values[2].number[0])
		}
		check(s, s.selected_shader == graph_index && s.inspect_pass == 2 && e.desc.label == "拖尾二维" &&
			!e.enabled[2] && !e.expanded[2] && p.folder_closed && p.values[2].number[0] == 4.5,
			"display-name reload preserves stable-ID selection, toggles and values")
		lab.set_pass_enabled(s.tool, graph_index, 1, false)
	case 11:
		bytes := foster.TextureDownloadData(foster.TargetAttachment(&e.targets[1].buffers[0]))
		defer delete(bytes)
		clear := len(bytes) > 0
		for b in bytes do clear = clear && b == 0
		check(s, clear, "disabled source pass clears output rather than leaving stale pixels")
		p.folder_closed = false
		lab.select_shader(s.tool, graph_3d_index, 2)
	case 12:
		capture(s, "hierarchy-3d")
		s.fixed_pass, _ = lab.widget_rect(s.tool, "pass:blur_x")
		press_widget(s, app, "shader-menu", 0.5)
	case 13, 15, 17, 20, 22, 26, 28, 30, 32:
		release_pointer(s, app)
	case 14:
		check(s, s.shader_menu && widget_present(s, "shader:Trail3D") &&
			!widget_present(s, "shader:Trail2D"), "shader menu isolates 3D workspace")
		check(s, len(s.shaders) == 4, "only four explicit shaders are listed for ten compiled Pass programs")
		for shader in s.shaders {
			check(s, shader.desc.name != "TrailBlur" && shader.desc.name != "TrailFeedback",
				"shared Shader resources do not create shaders")
		}
		pass, _ := lab.widget_rect(s.tool, "pass:blur_x")
		check(s, pass == s.fixed_pass, "shader popup does not displace the Pass list")
		press_widget(s, app, "shader:Preview3D", 0.5)
	case 16:
		check(s, s.selected_shader >= 0 && s.shaders[s.selected_shader].desc.name == "Preview3D" &&
			len(s.shaders[s.selected_shader].desc.passes) == 1 && s.inspect_pass == 0 && !s.shader_menu &&
			!widget_present(s, "pass-preview"), "explicit single Pass has no redundant output toggle")
		pixels := foster.TextureDownloadData(scene_texture(s))
		defer delete(pixels)
		varied := false
		for value, i in pixels {
			if i >= 4 && value != pixels[i%4] do varied = true
		}
		check(s, varied, "single Pass shader renders model pixels rather than an empty target")
		capture(s, "unified-shader")
	case 18:
		s.preview_width = s.viewport.Width
		resize_window(s, app, {1696, 1080})
		lab.select_shader(s.tool, graph_3d_index, 2)
		s.paused = false
		s.feature_next = s.elapsed+0.6
	case 19:
		if waiting(s, resized(s, app), "window resize applied") do return
		if waiting(s, s.shaders[s.selected_shader].ready, "Trail3D drawn in the larger preview") do return
		check(s, s.viewport.Width > s.preview_width && s.shaders[graph_3d_index].targets[0].buffers[0].Width == int(s.viewport.Width),
			"larger window grows the preview and its Pass targets")
		capture(s, "workflow-large")
		press_widget(s, app, "pass-preview", 0.5)
	case 21:
		check(s, s.preview_pass == 2, "explicit intermediate preview button")
		press_widget(s, app, "shader-final", 0.5)
	case 23:
		check(s, s.preview_pass == -1 && s.inspect_pass == 2, "return to final keeps inspected parameters")
		resize_window(s, app, {640, 800})
	case 24:
		if waiting(s, resized(s, app), "window resize applied") do return
		if waiting(s, s.shaders[s.selected_shader].ready, "Trail3D drawn in the narrow preview") do return
		check(s, s.viewport.Width < s.preview_width && s.shaders[graph_3d_index].targets[0].buffers[0].Width == int(s.viewport.Width),
			"narrow window shrinks the preview targets with it")
		capture(s, "workflow-narrow")
		resize_window(s, app, {1280, 800})
		lab.select_shader(s.tool, graph_3d_index, 1)
		s.mode = 3
		s.yaw = 1.25
		s.paused = true
	case 25:
		if waiting(s, resized(s, app), "window resize applied") do return
		press_widget(s, app, "workspace:2d", 0.5)
	case 27:
		check(s, s.workspace == 0 && s.selected_shader == graph_index && s.inspect_pass == 2 && s.mode == 0,
			"2D workspace restores its own selected shader and Pass")
		press_widget(s, app, "workspace:3d", 0.5)
	case 29:
		check(s, s.workspace == 1 && s.selected_shader == graph_3d_index && s.inspect_pass == 1 && s.mode == 3 && s.yaw == 1.25,
			"3D workspace restores independent model and camera")
		capture(s, "workspace-stable")
		s.fixed_tabs, _ = lab.widget_rect(s.tool, "inspector-parameters")
		press_widget(s, app, "preview-settings", 0.5)
	case 31:
		tabs, _ := lab.widget_rect(s.tool, "inspector-parameters")
		check(s, s.preview_settings && tabs == s.fixed_tabs, "preview settings replace detail content without moving selectors")
		press_widget(s, app, "inspector-parameters", 0.5)
	case 33:
		check(s, !s.preview_settings, "parameter tab returns from preview settings")
		select_parameter_shader(s, 1)
		s.graph_bank = s.bank
	case 34:
		// 显式单 Pass 扩成两个 Pass，保留 main ID。
		path := fmt.tprintf("%s/Preview3D.oshader", s.source_root)
		bytes, err := os.read_entire_file(path, context.temp_allocator)
		check(s, err == nil, "read single Pass declaration")
		// 去掉文件末尾 Shader 块的右括号，复制 main Pass 后再补回。
		body := strings.trim_right_space(string(bytes))
		check(s, strings.has_suffix(body, "}"), "Shader block closes the file")
		body = strings.trim_suffix(body, "}")
		start := strings.index(body, "    Pass \"main\"")
		check(s, start >= 0, "find main Pass")
		if s.failed do return
		newline := fixture_newline(body)
		second, _ := strings.replace_all(strings.trim_space(body[start:]), "Pass \"main\"", "Pass \"second\"", context.temp_allocator)
		first := fixture_replace(s, body, "Draw Preview_Model", "Draw Preview_Model\n        Output \"base\"")
		expanded := fmt.tprintf("%s%s%s%s}%s", first, newline, second, newline, newline)
		check(s, os.write_entire_file(path, expanded) == nil, "extend explicit shader with another Pass")
	case 35:
		if rawptr(s.bank) == s.graph_bank do return
		chosen := &s.shaders[s.selected_shader]
		check(s, chosen.desc.name == "Preview3D" && len(chosen.desc.passes) == 2 &&
			chosen.desc.passes[s.inspect_pass].id == "main" && s.workspace == 1 &&
			len(s.shaders) == 4 && s.program_count == 11 && lab.parameter_number(s.tool, 1, "hue") == 0.15,
			"single to multi-Pass edit retains shader identity, selection and values")
		check(s, widget_present(s, "pass-preview"), "multiple Passes expose intermediate preview")
		finish(s, app, "PASS: explicit shaders only, Pass programs excluded, single/multi-Pass rendering, workspace restoration, preview sizing and real ImGui input")
	}
	s.smoke_step += 1
}
