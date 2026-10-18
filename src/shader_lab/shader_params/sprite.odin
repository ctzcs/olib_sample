package shader_params

import mat "olib:kit/material"

Sprite_Shader :: mat.Shader_Path("Sprite.hlsl")
Sprite_Ref :: mat.Params_Ref("Sprite")
Sprite_Label :: "精灵材质"
Sprite_Preview :: mat.Preview_Mode.Two_D
Sprite_Params :: struct {
	image: mat.Texture_Path `label:"Sprite image"`,
	hue: mat.Scalar `min:"0" max:"1" label:"Hue"`,
	opacity: mat.Scalar `min:"0" max:"1" label:"Opacity"`,
}

SpriteShade_Shader :: mat.Shader_Path("SpriteShade.hlsl")
SpriteShade_Ref :: mat.Params_Ref("SpriteShade")
SpriteShade_Label :: "阴影参数"
SpriteShade_Preview :: mat.Preview_Mode.Two_D
SpriteShade_Params :: Sprite_Params
spriteshade_defaults :: proc() -> SpriteShade_Params {
	return sprite_defaults()
}
sprite_defaults :: proc() -> Sprite_Params {
	return {hue = 0.15, opacity = 1}
}

SpriteShadow_Label :: "精灵材质 / 阴影 + 本体"
SpriteShadow_Preview :: mat.Preview_Mode.Two_D
SpriteShadow_Output :: mat.Target_Ref("color")
SpriteShadow_Target :: mat.Target_Desc{clear = {0.12, 0.15, 0.20, 1}}
SpriteShadow_Passes := []mat.Pass_Desc{
	{id = "shadow", label = "阴影", params = SpriteShade_Ref, draw = .Sprite,
		output = SpriteShadow_Output, target = SpriteShadow_Target, sprite_texture = "image"},
	{id = "body", label = "本体", params = Sprite_Ref, draw = .Sprite,
		output = SpriteShadow_Output, target = SpriteShadow_Target, sprite_texture = "image"},
}

sprite_effect :: proc() -> mat.Effect_Desc {
	return {name = "SpriteShadow", label = SpriteShadow_Label, preview = "2d",
		output = SpriteShadow_Output, passes = SpriteShadow_Passes}
}
