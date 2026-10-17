package shader_params

import mat "olib:kit/material"

// 同一包中的每组声明通过前缀关联；路径相对于 Shader Lab 的 source 目录。
Preview2D_Shader :: mat.Shader_Path("Preview2D.hlsl")
Preview2D_Ref :: mat.Params_Ref("Preview2D")
Preview2D_Label :: "流动纹理"
Preview2D_Preview :: mat.Preview_Mode.Two_D

Preview2D_Params :: struct {
	strength: mat.Scalar `label:"Strength" min:"0" max:"1"`,
	hue: mat.Scalar `label:"Hue" min:"0" max:"1"`,
	speed: mat.Scalar `label:"Flow speed" min:"0" max:"5" step:"0.1"`,
	tint: mat.Color `label:"Tint"`,
	image: mat.Texture_Path `label:"Texture"`,
}

preview2d_defaults :: proc() -> Preview2D_Params {
	return {strength = 0.65, hue = 0.15, speed = 2, tint = {1, 1, 1, 1}}
}

// 明确作为可选效果展示；仅有 Params / Shader 的资源不会进入效果列表。
Preview2D_Passes := []mat.Pass_Desc{
	{id = "main", label = "绘制场景", params = Preview2D_Ref, draw = .Preview_Model, output = "color",
		target = {clear = {17.0/255, 21.0/255, 26.0/255, 1}}},
}
Preview2D_Output :: mat.Target_Ref("color")
