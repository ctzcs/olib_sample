package main

import mat "olib:kit/rendering/material"

// 资源初始化只登记一次；Shader、Material 和贴图的 GPU 生命周期由库负责。
// 发布路径只读预编译字节码；修改源码后运行 tools/shader_lab_assets。
// 清单和每个 Pass 的 spv / dxil / msl 都由 tools/shaders 生成，库按当前驱动选择后端。
register_materials :: proc(library: ^mat.Material_Library) -> string {
	passes := [?]mat.Pass_Binaries{
		{ // body
			vertex = {
				spv = #load("../shader_lab/shaders/Compiled/Outlined_body.vertex.spv"),
				dxil = #load("../shader_lab/shaders/Compiled/Outlined_body.vertex.dxil"),
				msl = #load("../shader_lab/shaders/Compiled/Outlined_body.vertex.msl"),
			},
			fragment = {
				spv = #load("../shader_lab/shaders/Compiled/Outlined_body.fragment.spv"),
				dxil = #load("../shader_lab/shaders/Compiled/Outlined_body.fragment.dxil"),
				msl = #load("../shader_lab/shaders/Compiled/Outlined_body.fragment.msl"),
			},
		},
		{ // outline
			vertex = {
				spv = #load("../shader_lab/shaders/Compiled/Outlined_outline.vertex.spv"),
				dxil = #load("../shader_lab/shaders/Compiled/Outlined_outline.vertex.dxil"),
				msl = #load("../shader_lab/shaders/Compiled/Outlined_outline.vertex.msl"),
			},
			fragment = {
				spv = #load("../shader_lab/shaders/Compiled/Outlined_outline.fragment.spv"),
				dxil = #load("../shader_lab/shaders/Compiled/Outlined_outline.fragment.dxil"),
				msl = #load("../shader_lab/shaders/Compiled/Outlined_outline.fragment.msl"),
			},
		},
	}
	return mat.material_register_manifest(library,
		#load("../shader_lab/shaders/Compiled/Outlined.shader.json"), passes[:])
}

// 实例化效果：每个实例的世界矩阵 / tint / hue 来自 Model_Buffer（见 swarm.odin）。
register_swarm :: proc(library: ^mat.Material_Library) -> string {
	passes := [?]mat.Pass_Binaries{
		{ // body
			vertex = {
				spv = #load("../shader_lab/shaders/Compiled/Swarm_body.vertex.spv"),
				dxil = #load("../shader_lab/shaders/Compiled/Swarm_body.vertex.dxil"),
				msl = #load("../shader_lab/shaders/Compiled/Swarm_body.vertex.msl"),
			},
			fragment = {
				spv = #load("../shader_lab/shaders/Compiled/Swarm_body.fragment.spv"),
				dxil = #load("../shader_lab/shaders/Compiled/Swarm_body.fragment.dxil"),
				msl = #load("../shader_lab/shaders/Compiled/Swarm_body.fragment.msl"),
			},
		},
	}
	return mat.material_register_manifest(library,
		#load("../shader_lab/shaders/Compiled/Swarm.shader.json"), passes[:])
}
