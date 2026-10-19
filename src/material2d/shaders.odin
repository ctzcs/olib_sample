package main

import mat "olib:kit/rendering/material"

// 资源初始化只登记一次；Shader、Material 和贴图的 GPU 生命周期由库负责。
// 发布路径只读预编译字节码；修改源码后运行 tools/shader_lab_assets。
// 清单和每个 Pass 的 spv / dxil / msl 都由 tools/shaders 生成，库按当前驱动选择后端。
register_materials :: proc(library: ^mat.Material_Library) -> string {
	passes := [?]mat.Pass_Binaries{
		{ // shadow
			vertex = {
				spv = #load("../shader_lab/shaders/Compiled/SpriteShadow_shadow.vertex.spv"),
				dxil = #load("../shader_lab/shaders/Compiled/SpriteShadow_shadow.vertex.dxil"),
				msl = #load("../shader_lab/shaders/Compiled/SpriteShadow_shadow.vertex.msl"),
			},
			fragment = {
				spv = #load("../shader_lab/shaders/Compiled/SpriteShadow_shadow.fragment.spv"),
				dxil = #load("../shader_lab/shaders/Compiled/SpriteShadow_shadow.fragment.dxil"),
				msl = #load("../shader_lab/shaders/Compiled/SpriteShadow_shadow.fragment.msl"),
			},
			// 缓冲变体顶点：常驻 Sprite_Buffer（swarm）用。
			instanced_vertex = {
				spv = #load("../shader_lab/shaders/Compiled/SpriteShadow_shadow.instanced.vertex.spv"),
				dxil = #load("../shader_lab/shaders/Compiled/SpriteShadow_shadow.instanced.vertex.dxil"),
				msl = #load("../shader_lab/shaders/Compiled/SpriteShadow_shadow.instanced.vertex.msl"),
			},
		},
		{ // body
			vertex = {
				spv = #load("../shader_lab/shaders/Compiled/SpriteShadow_body.vertex.spv"),
				dxil = #load("../shader_lab/shaders/Compiled/SpriteShadow_body.vertex.dxil"),
				msl = #load("../shader_lab/shaders/Compiled/SpriteShadow_body.vertex.msl"),
			},
			fragment = {
				spv = #load("../shader_lab/shaders/Compiled/SpriteShadow_body.fragment.spv"),
				dxil = #load("../shader_lab/shaders/Compiled/SpriteShadow_body.fragment.dxil"),
				msl = #load("../shader_lab/shaders/Compiled/SpriteShadow_body.fragment.msl"),
			},
			// 缓冲变体顶点：常驻 Sprite_Buffer（swarm）用。
			instanced_vertex = {
				spv = #load("../shader_lab/shaders/Compiled/SpriteShadow_body.instanced.vertex.spv"),
				dxil = #load("../shader_lab/shaders/Compiled/SpriteShadow_body.instanced.vertex.dxil"),
				msl = #load("../shader_lab/shaders/Compiled/SpriteShadow_body.instanced.vertex.msl"),
			},
		},
	}
	return mat.material_register_manifest(library,
		#load("../shader_lab/shaders/Compiled/SpriteShadow.shader.json"), passes[:])
}
