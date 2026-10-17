package shader_params

// 纯声明类型，不引入工具 UI 或 GPU；全包仍只生成一个临时程序。
import mat "olib:kit/material"

// 连线与字段名只定义一次；在 Pass 中引用常量，IDE 可以补全。
Scene_Color :: mat.Target_Ref("scene_color")
Blur_X :: mat.Target_Ref("blur_x")
Blur_Y :: mat.Target_Ref("blur_y")
Trail_Result :: mat.Target_Ref("result")
Source_Field :: mat.Field_Ref("source")
History_Field :: mat.Field_Ref("history")
Direction_Field :: mat.Field_Ref("direction")

TrailBlur_Shader :: mat.Shader_Path("TrailBlur.hlsl")
TrailBlur_Ref :: mat.Params_Ref("TrailBlur")
TrailBlur_Label :: "模糊"
TrailBlur_Folder :: "后处理"
TrailBlur_Params :: struct {
	source: mat.Texture_Path `label:"Source"`,
	direction: mat.Vector2 `label:"Direction" min:"-1" max:"1"`,
	radius: mat.Scalar `label:"Radius" min:"0" max:"12"`,
}

trailblur_defaults :: proc() -> TrailBlur_Params {
	return {direction = {1, 0}, radius = 3}
}

TrailFeedback_Shader :: mat.Shader_Path("TrailFeedback.hlsl")
TrailFeedback_Ref :: mat.Params_Ref("TrailFeedback")
TrailFeedback_Label :: "帧反馈"
TrailFeedback_Folder :: "后处理"
TrailFeedback_Params :: struct {
	source: mat.Texture_Path `label:"Source"`,
	history: mat.Texture_Path `label:"History"`,
	retention: mat.Scalar `label:"Retention" min:"0" max:"0.99"`,
}

trailfeedback_defaults :: proc() -> TrailFeedback_Params {
	return {retention = 0.82}
}

// 声明顺序故意不等于执行顺序：工具根据 Current 输入自动排序。
Trail2D_Label :: "二维拖尾"
Trail2D_Preview :: mat.Preview_Mode.Two_D
Trail2D_Passes := []mat.Pass_Desc{
	{id = "feedback", label = "上一帧反馈", params = TrailFeedback_Ref, output = Trail_Result,
		inputs = {{field = Source_Field, target = Blur_Y},
			{field = History_Field, target = Trail_Result, frame = .Previous}}},
	{id = "scene", label = "绘制场景", params = Preview2D_Ref, draw = .Preview_Model, output = Scene_Color,
		target = {format = .Float16}},
	{id = "blur_x", label = "横向模糊", params = TrailBlur_Ref, output = Blur_X,
		inputs = {{field = Source_Field, target = Scene_Color}},
		values = {{field = Direction_Field, number = {1, 0, 0, 0}}},
		target = {scale = 0.5, format = .Float16}},
	{id = "blur_y", label = "纵向模糊", params = TrailBlur_Ref, output = Blur_Y,
		inputs = {{field = Source_Field, target = Blur_X}},
		values = {{field = Direction_Field, number = {0, 1, 0, 0}}},
		target = {scale = 0.5, format = .Float16}},
}
Trail2D_Output :: Trail_Result

Trail3D_Label :: "三维拖尾"
Trail3D_Preview :: mat.Preview_Mode.Three_D
Trail3D_Passes := []mat.Pass_Desc{
	{
		id = "feedback",
		label = "上一帧反馈",
		params = TrailFeedback_Ref,
		output = Trail_Result,
		inputs = {
			{field = Source_Field, target = Blur_Y},
			{field = History_Field, target = Trail_Result, frame = .Previous}
		}
	},
	{
		id = "scene",
		label = "绘制场景",
		params = Preview3D_Ref,
		draw = .Preview_Model,
		output = Scene_Color,
		target = {format = .Float16}
	},
	{
		id = "blur_x", label = "横向模糊", params = TrailBlur_Ref, output = Blur_X,
		inputs = {{field = Source_Field, target = Scene_Color}},
		values = {{field = Direction_Field, number = {1, 0, 0, 0}}},
		target = {scale = 0.5, format = .Float16}},
	{id = "blur_y", label = "纵向模糊", params = TrailBlur_Ref, output = Blur_Y,
		inputs = {{field = Source_Field, target = Blur_X}},
		values = {{field = Direction_Field, number = {0, 1, 0, 0}}},
		target = {scale = 0.5, format = .Float16}},
}
Trail3D_Output :: Trail_Result
