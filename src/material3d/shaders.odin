package main

import mat "olib:kit/material"
import rendering "olib:kit/rendering"
import r3d "olib:kit/rendering3d"
import params "../shader_lab/shader_params"

// 资源初始化只登记一次；Shader、Material 和贴图的 GPU 生命周期由库负责。
// 发布路径只读预编译字节码；修改源码后运行 tools/shader_lab_assets。
register_materials :: proc(library: ^rendering.Material_Library) -> string {
	driver := library.device.Driver
	if !r3d.shader3d_driver_supported(driver) do return "Unsupported shader backend"
	schemas: [2]mat.Schema
	defer for &schema in schemas do mat.schema_dispose(&schema)
	reason: string
	schemas[0], reason = mat.describe("Preview3D", params.Preview3D_Shader, "3d", params.preview3d_defaults())
	if reason != "" do return reason
	schemas[1], reason = mat.describe("Outline", params.Outline_Shader, "3d", params.outline_defaults())
	if reason != "" do return reason
	vertex := [2][3][]u8{
		{#load("../shader_lab/shaders/Compiled/Preview3D.vertex.spv"), #load("../shader_lab/shaders/Compiled/Preview3D.vertex.dxil"), #load("../shader_lab/shaders/Compiled/Preview3D.vertex.msl")},
		{#load("../shader_lab/shaders/Compiled/Outline.vertex.spv"), #load("../shader_lab/shaders/Compiled/Outline.vertex.dxil"), #load("../shader_lab/shaders/Compiled/Outline.vertex.msl")},
	}
	fragment := [2][3][]u8{
		{#load("../shader_lab/shaders/Compiled/Preview3D.fragment.spv"), #load("../shader_lab/shaders/Compiled/Preview3D.fragment.dxil"), #load("../shader_lab/shaders/Compiled/Preview3D.fragment.msl")},
		{#load("../shader_lab/shaders/Compiled/Outline.fragment.spv"), #load("../shader_lab/shaders/Compiled/Outline.fragment.dxil"), #load("../shader_lab/shaders/Compiled/Outline.fragment.msl")},
	}
	code: [2]rendering.Material_Shader_Code
	for i in 0..<2 {
		code[i] = {
			r3d.shader3d_pick_code(driver, vertex[i][0], vertex[i][1], vertex[i][2]),
			r3d.shader3d_pick_code(driver, fragment[i][0], fragment[i][1], fragment[i][2]),
		}
	}
	return rendering.materials_register(library, params.outlined_effect(), schemas[:], code[:])
}
