package main

import "core:fmt"
import foster "olib:foster"

quad_mesh: foster.Mesh
quad_material: foster.Material
quad_texture: foster.Texture
offscreen_target: foster.Target
quad_command: foster.DrawCommand
offscreen_command: foster.DrawCommand
quad_vertex_shader: foster.Shader
quad_fragment_shader: foster.Shader

startup :: proc(app: ^foster.App) {
	foster.MeshInitTyped(foster.BatcherVertex, &quad_mesh, &app.GraphicsDevice, foster.IndexFormat.Sixteen, "SampleQuad")
	verts := [6]foster.BatcherVertex{
		foster.MakeBatcherVertex([2]f32{-0.5, -0.5}, [2]f32{0, 1}, foster.Red, foster.Color{0, 0, 255, 255}),
		foster.MakeBatcherVertex([2]f32{-0.5, 0.5}, [2]f32{0, 0}, foster.Green, foster.Color{0, 0, 255, 255}),
		foster.MakeBatcherVertex([2]f32{0.5, 0.5}, [2]f32{1, 0}, foster.Blue, foster.Color{0, 0, 255, 255}),
		foster.MakeBatcherVertex([2]f32{-0.5, -0.5}, [2]f32{0, 1}, foster.Red, foster.Color{0, 0, 255, 255}),
		foster.MakeBatcherVertex([2]f32{0.5, 0.5}, [2]f32{1, 0}, foster.Blue, foster.Color{0, 0, 255, 255}),
		foster.MakeBatcherVertex([2]f32{0.5, -0.5}, [2]f32{1, 1}, foster.White, foster.Color{0, 0, 255, 255}),
	}
	foster.MeshSetVerticesTyped(foster.BatcherVertex, &quad_mesh, verts[:])

	foster.TextureInit(&quad_texture, &app.GraphicsDevice, 1, 1, .Color, "SampleWhite")
	pixel := [4]u8{255, 255, 255, 255}
	foster.TextureSetData(&quad_texture, &pixel[0], len(pixel))
	foster.TargetInit(&offscreen_target, &app.GraphicsDevice, 256, 256, "SampleTarget")

	foster.InitDefaultBatchMaterial(&quad_material, &quad_vertex_shader, &quad_fragment_shader, &app.GraphicsDevice)
	quad_material.Fragment.Samplers[0] = foster.BoundSampler{
		Texture = &quad_texture,
		Sampler = foster.TextureSamplerMake(.Linear, .Clamp),
	}

	foster.DrawCommandFromMesh(&offscreen_command, foster.DrawableTargetFromTarget(&offscreen_target), &quad_mesh, &quad_material)
	foster.DrawCommandFromMesh(&quad_command, foster.DrawableTargetFromWindow(&app.Window), &quad_mesh, &quad_material)
	fmt.println("startup:", app.Name)
}

shutdown :: proc(app: ^foster.App) {
	_ = app
	foster.DrawCommandDispose(&offscreen_command)
	foster.DrawCommandDispose(&quad_command)
	foster.TargetDispose(&offscreen_target)
	foster.TextureDispose(&quad_texture)
	foster.ShaderDispose(&quad_vertex_shader)
	foster.ShaderDispose(&quad_fragment_shader)
	foster.MeshDispose(&quad_mesh)
	fmt.println("shutdown:", app.Name)
}

update :: proc(app: ^foster.App) {
	_ = app
}

render :: proc(app: ^foster.App) {
	foster.GraphicsDeviceClear(&app.GraphicsDevice, foster.DrawableTargetFromTarget(&offscreen_target), foster.Transparent)
	quad_material.Fragment.Samplers[0] = foster.BoundSampler{
		Texture = &quad_texture,
		Sampler = foster.TextureSamplerMake(.Linear, .Clamp),
	}
	foster.GraphicsDeviceDraw(quad_mesh.GraphicsDevice, &offscreen_command)

	foster.GraphicsDeviceClear(&app.GraphicsDevice, foster.DrawableTargetFromWindow(&app.Window), foster.Black)
	quad_material.Fragment.Samplers[0] = foster.BoundSampler{
		Texture = foster.TargetAttachment(&offscreen_target),
		Sampler = foster.TextureSamplerMake(.Linear, .Clamp),
	}
	foster.GraphicsDeviceDraw(quad_mesh.GraphicsDevice, &quad_command)
}

main :: proc() {
	config := foster.DefaultAppConfig("FosterOdin", 640, 360)
	config.WindowTitle = "Foster Odin Basic"

	app: foster.App
	foster.InitApp(&app, config)
	defer foster.Dispose(&app)

	app.StartupProc = startup
	app.ShutdownProc = shutdown
	app.UpdateProc = update
	app.RenderProc = render

	fmt.println("foster_framework version:", foster.VersionString())
	fmt.println("sdl version:", foster.SDLVersionString())
	foster.Run(&app)
}
