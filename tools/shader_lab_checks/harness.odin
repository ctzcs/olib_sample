package shader_lab_checks

// 自动验收仅修改独立临时源码；不接触用户正在编辑的文件。
import "core:fmt"
import "core:os"
import "core:strings"

import foster "olib:foster"
import lab "olib:kit/tools/shader_lab"
import clay "olib:thirdparty/clay-odin"

prepare_smoke :: proc(s: ^State) -> bool {
	root, err := os.make_directory_temp("", "olib_shader_lab_*", context.allocator)
	if err != nil {
		s.failed = true
		return false
	}
	s.temp_root = root
	for name in ([]string{"Preview2D.oshader", "Preview3D.oshader", "Palette.hlsli"}) {
		bytes, err := os.read_entire_file(fmt.tprintf("%s/%s", s.source_root, name), context.temp_allocator)
		if err != nil || os.write_entire_file(fmt.tprintf("%s/%s", root, name), bytes) != nil do return false
	}
	s.source_root = s.temp_root
	return true
}

cleanup_smoke :: proc(s: ^State) {
	if s.temp_root == "" || s.failed do return
	for name in ([]string{"Preview2D.oshader", "Preview3D.oshader", "Trail2D.oshader", "Trail3D.oshader", "Palette.hlsli", "Extra.oshader", "red.png", "feature-preset.json", "feature-bad.json", "feature.png"}) {
		_ = os.remove(fmt.tprintf("%s/%s", s.temp_root, name))
	}
	_ = os.remove(s.temp_root)
	delete(s.temp_root)
}

check :: proc(s: ^State, condition: bool, message: string) {
	if !condition {
		s.failed = true
		fmt.eprintln("FAIL:", message)
	}
}

scene_hash :: proc(s: ^State) -> u64 {
	texture := scene_texture(s)
	if texture == nil do return 0
	bytes := foster.TextureDownloadData(texture)
	defer delete(bytes)
	hash: u64 = 1469598103934665603
	for b in bytes do hash = (hash ~ u64(b))*1099511628211
	return hash
}

scene_texture :: proc(s: ^State) -> ^foster.Texture {
	if s.selected_effect >= 0 {
		e := &s.effects[s.selected_effect]
		for p, i in e.desc.passes {
			if (s.preview_pass < 0 && p.output == e.desc.output) || s.preview_pass == i {
				target := &e.targets[i]
				return foster.TargetAttachment(&target.buffers[target.history ? e.current : 0])
			}
		}
	}
	return nil
}

select_parameter_effect :: proc(s: ^State, parameter: int) {
	for e, i in s.effects {
		if len(e.desc.passes) != 1 || string(e.desc.passes[0].params) != s.parameters[parameter].name do continue
		lab.select_effect(s.tool, i)
		return
	}
	check(s, false, "parameter has a single-Pass effect")
}

capture :: proc(s: ^State, label: string) {
	bytes := foster.TextureDownloadData(foster.TargetAttachment(&s.output))
	defer delete(bytes)
	check(s, len(bytes) == s.output.Width*s.output.Height*4, "final output readback")
	if len(bytes) != s.output.Width*s.output.Height*4 do return
	image := foster.ImageMake(s.output.Width, s.output.Height)
	defer foster.ImageDispose(&image)
	for &pixel, i in image.Pixels do pixel = {bytes[i*4], bytes[i*4+1], bytes[i*4+2], bytes[i*4+3]}
	_ = os.make_directory_all(#directory + "/../../library/screenshots")
	path := fmt.tprintf("%s/../../library/screenshots/shader-lab-%s-%dx%d.png", #directory, label, image.Width, image.Height)
	check(s, foster.ImageWritePng(&image, path), "PNG write")
	fmt.println(path)
}

validate_frame :: proc(s: ^State, app: ^foster.App) {
	if s.render_serial == s.validated_serial do return
	s.validated_serial = s.render_serial
	if s.failed {
		foster.Exit(app)
		return
	}
	if s.targets {
		validate_targets(s, app)
		return
	}
	if s.hierarchy {
		validate_hierarchy(s, app)
		return
	}
	if s.multipass {
		validate_multipass(s, app)
		return
	}
	if s.features {
		validate_features(s, app)
		return
	}
	if s.color_smoke {
		validate_color_frame(s, app)
		return
	}
	if s.smoke_step == 0 {
		if s.shader_count < 2 || s.pending_bank != nil || s.selected_effect < 0 || !s.effects[s.selected_effect].ready do return
		// 每个模式连续两帧，确保录下的确实是切换后的实际绘制。
		if s.capture_index%2 == 1 {
			names := [4]string{"fullscreen", "sprite", "sphere", "cube"}
			capture(s, names[s.mode])
			if s.mode == 0 do s.initial_2d_pixels = scene_hash(s)
			if s.mode < 3 do s.mode += 1
			select_parameter_effect(s, s.mode < 2 ? 0 : 1)
		}
		s.capture_index += 1
		if s.capture_index < 8 do return
		if !s.smoke {
			foster.Exit(app)
			return
		}
		s.initial_pixels = scene_hash(s)
		for &shader, i in s.shaders[:2] {
			s.initial_resources[i] = rawptr(shader.fragment.Resource)
			old_vertex := shader.vertex.Resource
			old_fragment := shader.fragment.Resource
			invalid_probe := [1]foster.DrawCommand{{}}
			ok, _ := foster.ShaderPairTryReplace(&shader.vertex, &shader.fragment,
				&app.GraphicsDevice, shader.vertex.CreateInfo, shader.fragment.CreateInfo, invalid_probe[:])
			check(s, !ok && shader.vertex.Resource == old_vertex &&
				shader.fragment.Resource == old_fragment, "failed pipeline keeps both stages")
		}
		check(s, os.write_entire_file(fmt.tprintf("%s/Palette.hlsli", s.temp_root),
			string("this is intentionally invalid HLSL;")) == nil, "write bad include")
		s.smoke_step = 1
	} else if s.smoke_step == 1 {
		if s.pending_bank == nil || s.bank_error == "" do return
		for &shader, i in s.shaders[:2] {
			check(s, shader.revision == 1 && rawptr(shader.fragment.Resource) == s.initial_resources[i],
				"compile failure retains previous shader")
		}
		check(s, scene_hash(s) == s.initial_pixels, "compile failure retains identical scene pixels")
		capture(s, "compile-error")
		fixed := "float3 palette(float phase) { return float3(0.1, 0.8, 0.35) + phase * 0.01; }"
		check(s, os.write_entire_file(fmt.tprintf("%s/Palette.hlsli", s.temp_root),
			transmute([]u8)fixed) == nil, "repair shared include")
		s.smoke_step = 2
	} else if s.smoke_step == 2 {
		if s.pending_bank != nil || s.shaders[1].revision < 2 do return
		check(s, scene_hash(s) != s.initial_pixels, "valid include visibly updates scene")
		check(s, s.clock == 1 && s.yaw == 0.4 && lab.parameter_number(s.tool, 0, "hue") == 0.15 && lab.parameter_number(s.tool, 1, "hue") == 0.15,
			"reload preserves time, camera and parameters")
		capture(s, "recovered")
		select_parameter_effect(s, 0)
		s.mode = 0
		s.smoke_step = 20
	} else if s.smoke_step == 20 {
		if s.shaders[0].revision < 2 do return
		check(s, scene_hash(s) != s.initial_2d_pixels, "valid include visibly updates 2D scene")
		capture(s, "recovered-2d")
		path := fmt.tprintf("%s/Preview2D.oshader", s.temp_root)
		bytes, _ := os.read_entire_file(path, context.temp_allocator)
		s.binding_source = strings.clone(string(bytes))
		modified, _ := strings.replace_all(string(bytes), "color *= lerp",
			"color *= Extra; color *= lerp", context.temp_allocator)
		text, _ := strings.replace_all(modified, "HLSLPROGRAM", "HLSLPROGRAM\ncbuffer ExtraBlock : register(b2, space3) { float Extra; };", context.temp_allocator)
		check(s, os.write_entire_file(path, transmute([]u8)text) == nil, "change binding contract")
		s.smoke_step = 3
	} else if s.smoke_step == 3 {
		if s.pending_bank == nil || s.bank_error == "" do return
		check(s, s.shaders[0].revision == 2 && strings.contains(s.bank_error, "bindings changed"),
			"binding changes rejected before GPU replacement")
		check(s, os.write_entire_file(fmt.tprintf("%s/Preview2D.oshader", s.source_root), s.binding_source) == nil, "restore binding contract")
		s.smoke_step = 4
		s.capture_index = 0
		lab.select_workspace(s.tool, 0)
		s.effect_menu = true
	} else if s.smoke_step == 4 {
		if s.pending_bank != nil || s.elapsed < s.feature_next do return
		s.feature_next = s.elapsed+0.06
		switch s.capture_index {
		case 0:
			press_widget(s, app, "effect:Preview2D", 0.5)
		case 2, 6:
			foster.InputMouseButton(&app.Input, .Left, false, app.Time.Elapsed)
		case 4:
			check(s, s.mode == 0, "Shader selection uses real UI input")
			press_widget(s, app, "Preview2D_main:strength", 0.9)
		case 8:
			check(s, lab.parameter_number(s.tool, 0, "strength") > 0.8 && lab.parameter_number(s.tool, 1, "strength") == 0.65 && s.yaw == 0.4,
				"slider changes only active preview and does not orbit camera")
			foster.SetWindowSize(&app.Window, {1100, 825})
		case 12:
			check(s, s.output.Width == 1100 && s.output.Height == 825, "resize uses native output pixels")
			capture(s, "resized")
			select_parameter_effect(s, 1)
			s.mode = 3
			s.smoke_step = 5
			s.capture_index = -1
		}
		s.capture_index += 1
	} else if s.smoke_step == 5 {
		if s.pending_bank != nil do return
		if s.capture_index < 2 {
			s.capture_index += 1
			return
		}
		s.initial_pixels = scene_hash(s)
		s.parameter_revision = s.shaders[1].revision
		path := fmt.tprintf("%s/Preview3D.oshader", s.source_root)
		bytes, _ := os.read_entire_file(path, context.temp_allocator)
		s.parameter_source = strings.clone(string(bytes))
		bad, _ := strings.replace_all(s.parameter_source, "Range(0,5)", "Range(0,invalid)", context.temp_allocator)
		check(s, os.write_entire_file(path, bad) == nil, "write bad property declaration")
		s.smoke_step = 6
	} else if s.smoke_step == 6 {
		if s.parameter_watch.status != .Error do return
		check(s, s.shaders[1].revision == s.parameter_revision && scene_hash(s) == s.initial_pixels,
			"invalid property declaration keeps both schema and GPU pixels")
		capture(s, "parameter-error")
		text, _ := strings.replace_all(s.parameter_source, "Properties\n    {", "Properties\n    {\n        _gain (\"亮度\", Range(0,1)) = 0.5", context.temp_allocator)
		text, _ = strings.replace_all(text, "return float4(color * light", "return float4(color * _gain * light", context.temp_allocator)
		check(s, os.write_entire_file(fmt.tprintf("%s/Preview3D.oshader", s.source_root), text) == nil, "add property and consume it in HLSL atomically")
		s.smoke_step = 7
	} else if s.smoke_step == 7 {
		if s.parameters[1].has_pending || lab.parameter_number(s.tool, 1, "gain") != 0.5 do return
		check(s, s.shaders[1].revision > s.parameter_revision && scene_hash(s) != s.initial_pixels,
			"new generated layout and default visibly update 3D")
		check(s, lab.parameter_number(s.tool, 1, "strength") == 0.65 && lab.parameter_number(s.tool, 1, "hue") == 0.15,
			"field reorder retains values by stable ID")
		capture(s, "parameter-recovered")
		p := &s.parameters[1]
		for f, i in p.live.fields {
			if f.kind != .Texture do continue
			lab.parameter_texture_set(s.tool, 1, i, "missing-image.png")
			check(s, p.values[i].texture == "" && p.textures[0].Resource == nil, "failed texture keeps previous binding")
			img := foster.ImageMake(4, 4)
			for &pixel in img.Pixels do pixel = {255, 0, 0, 255}
			check(s, foster.ImageWritePng(&img, fmt.tprintf("%s/red.png", s.temp_root)), "write test texture")
			foster.ImageDispose(&img)
			lab.parameter_texture_set(s.tool, 1, i, "red.png")
			check(s, p.values[i].texture == "red.png" && p.textures[0].Resource != nil, "texture replacement succeeds")
		}
		s.initial_pixels = scene_hash(s)
		s.parameter_revision = s.shaders[1].revision
		s.smoke_step = 8
	} else if s.smoke_step == 8 {
		check(s, scene_hash(s) != s.initial_pixels && s.shaders[1].revision == s.parameter_revision,
			"texture changes pixels without recompiling")
		text := `Shader "Extra" {
Properties { _amount ("Amount", Range(0,1)) = 0.75 }
Pass "main" {
Draw Preview_Model
HLSLPROGRAM
struct I {float2 p:TEXCOORD0; float2 uv:TEXCOORD1;};
struct O {float4 p:SV_Position;};
O vertex_main(I v) {O o; o.p=float4(v.p,0,1); return o;}
float4 fragment_main(O v):SV_Target0 {return float4(_amount,0.2,0.3,1);}
ENDHLSL
}}
`
		check(s, os.write_entire_file(fmt.tprintf("%s/Extra.oshader", s.source_root), text) == nil, "add third shader")
		s.smoke_step = 9
	} else if s.smoke_step == 9 {
		extra := lab.bank_index(s.bank, "Extra_main")
		if extra < 0 || s.pending_bank != nil do return
		check(s, s.parameters[extra].available, "discovers third shader without restarting")
		select_parameter_effect(s, extra)
		s.mode = 0
		s.smoke_step = 11
	} else if s.smoke_step == 11 {
		if !s.effects[s.selected_effect].ready do return
		texture := scene_texture(s)
		pixels := foster.TextureDownloadData(texture)
		defer delete(pixels)
		pixel := (texture.Height/2*texture.Width+texture.Width/2)*4
		check(s, len(pixels) > pixel+3 && pixels[pixel] >= 189 && pixels[pixel] <= 193,
			"b1 parameter binds correctly even when b0 is unused")
		capture(s, "third-shader")
		check(s, os.remove(fmt.tprintf("%s/Extra.oshader", s.source_root)) == nil, "remove shader declaration")
		s.smoke_step = 10
	} else if s.smoke_step == 10 {
		if lab.bank_index(s.bank, "Extra_main") >= 0 do return
		capture(s, "parameter-texture")
		if !s.failed do fmt.println("PASS: 2D/3D reload, oshader parsing rollback/recovery, layout migration, textures, discovery, UI, resize")
		delete(s.parameter_source)
		s.parameter_source = ""
		foster.Exit(app)
	}
}

press_widget :: proc(s: ^State, app: ^foster.App, id: string, fraction: f32) {
	data := clay.GetElementData(clay.ID(id))
	check(s, data.found, "widget exists")
	box := data.boundingBox
	size := foster.Size(&app.Window)
	pixels := foster.SizeInPixels(&app.Window)
	position := foster.Vec2f{(s.region.X + (box.x + box.width*fraction)*s.ui_scale)*f32(size.X)/f32(pixels.X),
		(s.region.Y + (box.y + box.height*0.5)*s.ui_scale)*f32(size.Y)/f32(pixels.Y)}
	foster.InputMouseMove(&app.Input, position, {}, app.Time.Elapsed)
	foster.InputMouseButton(&app.Input, .Left, true, app.Time.Elapsed)
}

// Clay 元素哈希表保留历史布局；控件是否仍存在应看刚完成这一帧的交互列表。
widget_present :: proc(s: ^State, id: string) -> bool {
	key := clay.ID(id).id
	for widget in s.ctx.previous_widgets {
		if widget.id == key do return true
	}
	return false
}
