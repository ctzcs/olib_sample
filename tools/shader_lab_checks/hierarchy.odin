package shader_lab_checks

// 只覆盖本次层级、真实 checkbox/folder 交互和显示名热改，不重复完整多 Pass 故障注入。
import "core:fmt"
import "core:os"
import "core:strings"
import foster "olib:foster"
import lab "olib:kit/tools/shader_lab"
import clay "olib:thirdparty/clay-odin"

validate_hierarchy :: proc(s: ^State, app: ^foster.App) {
	if s.elapsed < s.feature_next do return
	s.feature_next = s.elapsed+0.08
	if s.parameter_watch.status == .Error {
		check(s, false, s.parameter_watch.diagnostic)
		return
	}
	if s.shader_count < 10 || s.pending_bank != nil do return
	graph_index, graph_3d_index := -1, -1
	for effect, i in s.effects {
		if effect.desc.name == "Trail2D" do graph_index = i
		if effect.desc.name == "Trail3D" do graph_3d_index = i
	}
	e := &s.effects[graph_index]
	p := &s.parameters[lab.bank_index(s.bank, "Trail2D_blur_x")]
	target := &e.targets[2].buffers[0]
	switch s.smoke_step {
	case 0:
		check(s, s.selected_effect == 0 && s.preview_pass == -1, "start with effect and final output")
		check(s, e.desc.name == "Trail2D" && e.desc.label == "二维拖尾" &&
			p.live.label == "横向模糊", "Pass labels independent of IDs")
		for effect in s.effects {
			for pass in effect.desc.passes {
				for cp in pass.label {
					_, found := foster.MsdfFontFindCharacter(s.font, int(cp))
					check(s, found, "Chinese pass glyph in true MSDF atlas")
				}
			}
		}
		lab.select_effect(s.tool, graph_index, 2)
	case 1:
		s.graph_hash = texture_hash(foster.TargetAttachment(target))
		capture(s, "hierarchy-2d")
		press_widget(s, app, "shader-folder:Trail2D:blur_x", 0.5)
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
			"rename effect label fixture")
	case 10:
		if rawptr(s.bank) == s.graph_bank do return
		if s.selected_effect != graph_index || s.inspect_pass != 2 || e.desc.label != "拖尾二维" ||
			e.enabled[2] || e.expanded[2] || !p.folder_closed || p.values[2].number[0] != 4.5 {
			fmt.printf("Reload state: selected=%d graph=%d pass=%d label=%s enabled=%v expanded=%v folder=%v value=%v\n",
				s.selected_effect, graph_index, s.inspect_pass, e.desc.label, e.enabled[2], e.expanded[2], p.folder_closed, p.values[2].number[0])
		}
		check(s, s.selected_effect == graph_index && s.inspect_pass == 2 && e.desc.label == "拖尾二维" &&
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
		lab.select_effect(s.tool, graph_3d_index, 2)
	case 12:
		check(s, s.ctx.error_count == 0 && !s.ctx.pool_overflow, "hierarchy layout has no Clay errors")
		capture(s, "hierarchy-3d")
		press_widget(s, app, "effect-menu", 0.5)
	case 13, 15, 17, 20, 22, 26:
		release_pointer(s, app)
	case 14:
		check(s, widget_present(s, "effect:Trail3D") &&
			!widget_present(s, "effect:Trail2D"), "effect menu isolates 3D workspace")
		check(s, !widget_present(s, "single-shaders") && len(s.effects) == 4,
			"only four explicit effects are listed for ten compiled Pass programs")
		for effect in s.effects {
			check(s, effect.desc.name != "TrailBlur" && effect.desc.name != "TrailFeedback",
				"shared Shader resources do not create effects")
		}
		press_widget(s, app, "effect:Preview3D", 0.5)
	case 16:
		check(s, s.selected_effect >= 0 && s.effects[s.selected_effect].desc.name == "Preview3D" &&
			len(s.effects[s.selected_effect].desc.passes) == 1 && s.inspect_pass == 0 &&
			!widget_present(s, "pass-preview"), "explicit single Pass has no redundant output toggle")
		pixels := foster.TextureDownloadData(scene_texture(s))
		defer delete(pixels)
		varied := false
		for value, i in pixels {
			if i >= 4 && value != pixels[i%4] do varied = true
		}
		check(s, varied, "single Pass effect renders model pixels rather than an empty target")
		capture(s, "unified-effect")
	case 18:
		check(s, s.ctx.error_count == 0 && !s.ctx.pool_overflow, "unified effect layout has no errors")
		resize_window(s, app, {1696, 1080})
		lab.select_effect(s.tool, graph_3d_index, 2)
		s.paused = false
		s.feature_next = s.elapsed+0.6
	case 19:
		if waiting(s, resized(s, app), "window resize applied") do return
		check(s, s.ui_scale > 1.2 && s.ctx.scale == s.ui_scale, "large window scales MSDF and all UI geometry together")
		capture(s, "workflow-large")
		press_widget(s, app, "pass-preview", 0.5)
	case 21:
		check(s, s.preview_pass == 2, "explicit intermediate preview button at fractional UI scale")
		press_widget(s, app, "effect-final", 0.5)
	case 23:
		check(s, s.preview_pass == -1 && s.inspect_pass == 2, "return to final keeps inspected parameters")
		resize_window(s, app, {640, 800})
	case 24:
		if waiting(s, resized(s, app), "window resize applied") do return
		check(s, s.compact && s.ui_scale == 1, "narrow window keeps readable font size")
		capture(s, "workflow-narrow")
	case 25:
		press_widget(s, app, "toggle-sidebar", 0.5)
	case 27:
		if !s.sidebar_collapsed || s.ctx.error_count != 0 || s.ctx.pool_overflow {
			fmt.printf("Sidebar state: collapsed=%v errors=%d overflow=%v pointer=%v\n",
				s.sidebar_collapsed, s.ctx.error_count, s.ctx.pool_overflow, s.pointer)
		}
		check(s, s.sidebar_collapsed && s.ctx.error_count == 0 && !s.ctx.pool_overflow,
			"narrow panel can yield full preview without layout errors")
		resize_window(s, app, {1280, 800})
		s.sidebar_collapsed = false
		lab.select_effect(s.tool, graph_3d_index, 1)
		s.mode = 3
		s.yaw = 1.25
		s.paused = true
		s.feature_next = s.elapsed+0.3
	case 28:
		// 侧栏锚点要在恢复尺寸后的布局上测量，之后的检查才和它比较。
		if waiting(s, resized(s, app), "window resize applied") do return
		s.fixed_pass_y = clay.GetElementData(clay.ID("pass:blur_x")).boundingBox.y
		s.fixed_tabs_y = clay.GetElementData(clay.ID("inspector-parameters")).boundingBox.y
		data := clay.GetScrollContainerData(clay.ID(lab.inspector_scroll_id(s.tool)))
		check(s, data.found && data.contentDimensions.height > data.scrollContainerDimensions.height+40,
			"scene parameters overflow their own scroll region")
		data.scrollPosition.y = -40
	case 29:
		s.saved_scroll_y = clay.GetScrollContainerData(clay.ID(lab.inspector_scroll_id(s.tool))).scrollPosition.y
		check(s, s.saved_scroll_y < -30, "parameter scroll is applied")
		press_widget(s, app, "workspace:2d", 0.5)
	case 30, 35, 38, 41:
		release_pointer(s, app)
	case 31:
		check(s, s.workspace == 0 && s.selected_effect == graph_index && s.inspect_pass == 2 && s.mode == 0,
			"2D workspace restores its own selected effect and Pass")
		check(s, clay.GetElementData(clay.ID("pass:blur_x")).boundingBox.y == s.fixed_pass_y &&
			clay.GetElementData(clay.ID("inspector-parameters")).boundingBox.y == s.fixed_tabs_y,
			"workspace and parameter length changes leave sidebar anchors fixed")
		press_widget(s, app, "effect-menu", 0.5)
	case 32:
		release_pointer(s, app)
	case 33:
		check(s, clay.GetElementData(clay.ID("pass:blur_x")).boundingBox.y == s.fixed_pass_y,
			"effect popup does not displace the Pass list")
		s.effect_menu = false
	case 34:
		press_widget(s, app, "workspace:3d", 0.5)
	case 36:
		check(s, s.workspace == 1 && s.selected_effect == graph_3d_index && s.inspect_pass == 1 && s.mode == 3 && s.yaw == 1.25,
			"3D workspace restores independent model and camera")
		data := clay.GetScrollContainerData(clay.ID(lab.inspector_scroll_id(s.tool)))
		check(s, data.found && data.scrollPosition.y == s.saved_scroll_y,
			"returning to a workspace restores parameter scroll")
		capture(s, "workspace-stable")
	case 37:
		press_widget(s, app, "preview-settings", 0.5)
	case 39:
		check(s, s.preview_settings && clay.GetElementData(clay.ID("inspector-parameters")).boundingBox.y == s.fixed_tabs_y,
			"preview settings replace detail content without moving selectors")
	case 40:
		press_widget(s, app, "inspector-parameters", 0.5)
	case 42:
		data := clay.GetScrollContainerData(clay.ID(lab.inspector_scroll_id(s.tool)))
		check(s, !s.preview_settings && data.found && data.scrollPosition.y == s.saved_scroll_y,
			"parameter tab restores scroll independently of preview settings")
		select_parameter_effect(s, 1)
		s.graph_bank = s.bank
	case 43:
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
		check(s, os.write_entire_file(path, expanded) == nil, "extend explicit effect with another Pass")
	case 44:
		if rawptr(s.bank) == s.graph_bank do return
		chosen := &s.effects[s.selected_effect]
		check(s, chosen.desc.name == "Preview3D" && len(chosen.desc.passes) == 2 &&
			chosen.desc.passes[s.inspect_pass].id == "main" && s.workspace == 1 &&
			len(s.effects) == 4 && s.shader_count == 11 && lab.parameter_number(s.tool, 1, "hue") == 0.15,
			"single to multi-Pass edit retains effect identity, selection and values")
		check(s, widget_present(s, "pass-preview"), "multiple Passes expose intermediate preview")
		finish(s, app, "PASS: explicit effects only, Pass programs excluded, single/multi-Pass rendering, workspace/scroll restoration and scaled MSDF input")
	}
	s.smoke_step += 1
}
