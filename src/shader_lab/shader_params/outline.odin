package shader_params

import mat "olib:kit/material"

Outline_Shader :: mat.Shader_Path("Outline.hlsl")
Outline_Ref :: mat.Params_Ref("Outline")
Outline_Label :: "描边颜色"
Outline_Preview :: mat.Preview_Mode.Three_D
Outline_Params :: struct { color: mat.Color `label:"Outline color"` }
outline_defaults :: proc() -> Outline_Params { return {color = {0.03, 0.04, 0.07, 1}} }

// 两个 Pass 共用目标、深度和网格；本体先写深度，外扩背面只留下轮廓。
Outlined_Label :: "模型材质 / 本体 + 描边"
Outlined_Preview :: mat.Preview_Mode.Three_D
Outlined_Output :: mat.Target_Ref("color")
Outlined_Target :: mat.Target_Desc{clear = {0.12, 0.15, 0.20, 1}}
Outlined_Passes := []mat.Pass_Desc{
	{id = "body", label = "本体", params = Preview3D_Ref, draw = .Model, output = Outlined_Output,
		target = Outlined_Target, state = {cull = .Back, blend = .Opaque, depth = .Less, depth_write = .On}},
	{id = "outline", label = "描边", params = Outline_Ref, draw = .Model, output = Outlined_Output,
		target = Outlined_Target, state = {cull = .Front, blend = .Opaque, depth = .Less_Equal, depth_write = .Off}},
}

outlined_effect :: proc() -> mat.Effect_Desc {
	return {name = "Outlined", label = Outlined_Label, preview = "3d", output = Outlined_Output, passes = Outlined_Passes}
}
