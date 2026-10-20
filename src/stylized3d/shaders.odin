package main

import mat "olib:kit/rendering/material"

// 预编译 Shader 的登记。改了 shaders/ 下的源码后，在示例仓库根目录运行
// odin run ../olib/tools/shaders -- -dir:src/stylized3d/shaders
// 重新生成 Compiled/（清单与每个 Pass 的 spv / dxil / msl）。
register_effects :: proc(library: ^mat.Material_Library) -> string {
	toon := [?]mat.Pass_Binaries{
		{
			vertex = {
				spv = #load("shaders/Compiled/Toon_scene.vertex.spv"),
				dxil = #load("shaders/Compiled/Toon_scene.vertex.dxil"),
				msl = #load("shaders/Compiled/Toon_scene.vertex.msl"),
			},
			fragment = {
				spv = #load("shaders/Compiled/Toon_scene.fragment.spv"),
				dxil = #load("shaders/Compiled/Toon_scene.fragment.dxil"),
				msl = #load("shaders/Compiled/Toon_scene.fragment.msl"),
			},
		},
	}
	hero := [?]mat.Pass_Binaries{
		{ // silhouette
			vertex = {
				spv = #load("shaders/Compiled/Hero_silhouette.vertex.spv"),
				dxil = #load("shaders/Compiled/Hero_silhouette.vertex.dxil"),
				msl = #load("shaders/Compiled/Hero_silhouette.vertex.msl"),
			},
			fragment = {
				spv = #load("shaders/Compiled/Hero_silhouette.fragment.spv"),
				dxil = #load("shaders/Compiled/Hero_silhouette.fragment.dxil"),
				msl = #load("shaders/Compiled/Hero_silhouette.fragment.msl"),
			},
		},
		{ // body
			vertex = {
				spv = #load("shaders/Compiled/Hero_body.vertex.spv"),
				dxil = #load("shaders/Compiled/Hero_body.vertex.dxil"),
				msl = #load("shaders/Compiled/Hero_body.vertex.msl"),
			},
			fragment = {
				spv = #load("shaders/Compiled/Hero_body.fragment.spv"),
				dxil = #load("shaders/Compiled/Hero_body.fragment.dxil"),
				msl = #load("shaders/Compiled/Hero_body.fragment.msl"),
			},
		},
	}
	sky := [?]mat.Pass_Binaries{
		{
			vertex = {
				spv = #load("shaders/Compiled/Sky_sky.vertex.spv"),
				dxil = #load("shaders/Compiled/Sky_sky.vertex.dxil"),
				msl = #load("shaders/Compiled/Sky_sky.vertex.msl"),
			},
			fragment = {
				spv = #load("shaders/Compiled/Sky_sky.fragment.spv"),
				dxil = #load("shaders/Compiled/Sky_sky.fragment.dxil"),
				msl = #load("shaders/Compiled/Sky_sky.fragment.msl"),
			},
		},
	}
	billboard := [?]mat.Pass_Binaries{
		{
			vertex = {
				spv = #load("shaders/Compiled/Billboard_transparent.vertex.spv"),
				dxil = #load("shaders/Compiled/Billboard_transparent.vertex.dxil"),
				msl = #load("shaders/Compiled/Billboard_transparent.vertex.msl"),
			},
			fragment = {
				spv = #load("shaders/Compiled/Billboard_transparent.fragment.spv"),
				dxil = #load("shaders/Compiled/Billboard_transparent.fragment.dxil"),
				msl = #load("shaders/Compiled/Billboard_transparent.fragment.msl"),
			},
		},
	}
	edge := [?]mat.Pass_Binaries{
		{
			vertex = {
				spv = #load("shaders/Compiled/DepthEdge_edge.vertex.spv"),
				dxil = #load("shaders/Compiled/DepthEdge_edge.vertex.dxil"),
				msl = #load("shaders/Compiled/DepthEdge_edge.vertex.msl"),
			},
			fragment = {
				spv = #load("shaders/Compiled/DepthEdge_edge.fragment.spv"),
				dxil = #load("shaders/Compiled/DepthEdge_edge.fragment.dxil"),
				msl = #load("shaders/Compiled/DepthEdge_edge.fragment.msl"),
			},
		},
	}
	if reason := mat.material_register_manifest(library, #load("shaders/Compiled/Toon.shader.json"), toon[:]); reason != "" do return reason
	if reason := mat.material_register_manifest(library, #load("shaders/Compiled/Hero.shader.json"), hero[:]); reason != "" do return reason
	if reason := mat.material_register_manifest(library, #load("shaders/Compiled/Sky.shader.json"), sky[:]); reason != "" do return reason
	if reason := mat.material_register_manifest(library, #load("shaders/Compiled/Billboard.shader.json"), billboard[:]); reason != "" do return reason
	return mat.material_register_manifest(library, #load("shaders/Compiled/DepthEdge.shader.json"), edge[:])
}
