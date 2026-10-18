package main

import mat "olib:kit/material"
import rendering "olib:kit/rendering"
import params "../shader_lab/shader_params"

// 资源初始化只登记一次；Shader、Material 和贴图的 GPU 生命周期由库负责。
// 发布路径只读预编译字节码；修改源码后运行 tools/shader_lab_assets。
register_materials :: proc(library: ^rendering.Material_Library) -> string {
	driver := library.device.Driver
	backend: int
	#partial switch driver {
	case .Vulkan, .Private:
		backend = 0
	case .D3D12:
		backend = 1
	case .Metal:
		backend = 2
	case:
		return "Unsupported shader backend"
	}
	schemas: [2]mat.Schema
	defer for &schema in schemas do mat.schema_dispose(&schema)
	reason: string
	schemas[0], reason = mat.describe("Sprite", params.Sprite_Shader, "2d", params.sprite_defaults())
	if reason != "" do return reason
	schemas[1], reason = mat.describe("SpriteShade", params.SpriteShade_Shader, "2d", params.spriteshade_defaults())
	if reason != "" do return reason
	vertex := [2][3][]u8{
		{#load("../shader_lab/shaders/Compiled/Sprite.vertex.spv"), #load("../shader_lab/shaders/Compiled/Sprite.vertex.dxil"), #load("../shader_lab/shaders/Compiled/Sprite.vertex.msl")},
		{#load("../shader_lab/shaders/Compiled/SpriteShade.vertex.spv"), #load("../shader_lab/shaders/Compiled/SpriteShade.vertex.dxil"), #load("../shader_lab/shaders/Compiled/SpriteShade.vertex.msl")},
	}
	fragment := [2][3][]u8{
		{#load("../shader_lab/shaders/Compiled/Sprite.fragment.spv"), #load("../shader_lab/shaders/Compiled/Sprite.fragment.dxil"), #load("../shader_lab/shaders/Compiled/Sprite.fragment.msl")},
		{#load("../shader_lab/shaders/Compiled/SpriteShade.fragment.spv"), #load("../shader_lab/shaders/Compiled/SpriteShade.fragment.dxil"), #load("../shader_lab/shaders/Compiled/SpriteShade.fragment.msl")},
	}
	code: [2]rendering.Material_Shader_Code
	for i in 0..<2 {
		code[i] = {
			vertex[i][backend],
			fragment[i][backend],
		}
	}
	return rendering.materials_register(library, params.sprite_effect(), schemas[:], code[:])
}
