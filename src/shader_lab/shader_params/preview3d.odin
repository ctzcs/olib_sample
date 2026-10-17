package shader_params

import mat "olib:kit/material"

Preview3D_Shader :: mat.Shader_Path("Preview3D.hlsl")
Preview3D_Ref :: mat.Params_Ref("Preview3D")
Preview3D_Label :: "模型表面"
Preview3D_Preview :: mat.Preview_Mode.Three_D

Preview3D_Params :: struct {
	strength: mat.Scalar `label:"Strength" min:"0" max:"1"`,
	hue: mat.Scalar `label:"Hue" min:"0" max:"1"`,
	speed: mat.Scalar `label:"Flow speed" min:"0" max:"5" step:"0.1"`,
	tint: mat.Color `label:"Tint"`,
	image: mat.Texture_Path `label:"Texture"`,
}

preview3d_defaults :: proc() -> Preview3D_Params {
	return {strength = 0.65, hue = 0.15, speed = 2, tint = {1, 1, 1, 1}}
}

Preview3D_Passes := []mat.Pass_Desc{
	{id = "main", label = "绘制场景", params = Preview3D_Ref, draw = .Preview_Model, output = "color",
		target = {clear = {17.0/255, 21.0/255, 26.0/255, 1}}},
}
Preview3D_Output :: mat.Target_Ref("color")
