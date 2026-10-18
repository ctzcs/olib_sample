package main

// 两个模型共用 Shader/Effect，分别持有 Material 实例。无 shaderdev 或 Shader Lab 依赖。
import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import dasset "olib:core/dasset"
import foster "olib:foster"
import rendering "olib:kit/rendering"
import r3d "olib:kit/rendering3d"
import world "olib:kit/world"

State :: struct {
	resources: foster.StorageContainer,
	materials: rendering.Material_Library,
	models: [2]r3d.Model,
	mesh: foster.Mesh,
	target: foster.Target,
	batch: foster.Batcher,
	camera: world.Camera3D,
	time: f32,
	outline: bool,
	path: string,
	failed: bool,
}

main :: proc() {
	s := new(State)
	defer free(s)
	s.outline = true
	// 从 Shader Lab “保存材质”得到的文件；R 重新载入到左侧模型，右侧保持独立。
	s.path = len(os.args) > 1 ? os.args[1] : #directory + "/material.json"
	absolute, path_error := filepath.abs(s.path)
	if path_error != nil do os.exit(1)
	defer delete(absolute)
	s.resources.Root = filepath.dir(absolute)
	s.path = filepath.base(absolute)
	app: foster.App
	foster.InitApp(&app, foster.DefaultAppConfig("Material3D | Space: outline | R: reload left material | Esc: exit", 1100, 720))
	foster.AppSetUserData(&app, s)
	app.StartupProc, app.UpdateProc, app.RenderProc, app.ShutdownProc = startup, update, render, shutdown
	foster.Run(&app)
	foster.Dispose(&app)
	delete(app.GraphicsDevice.WindowRenderTarget.Attachments)
	if s.failed do os.exit(1)
}

fail :: proc(app: ^foster.App, reason: string) {
	fmt.eprintln(reason)
	foster.AppGetUserDataAs(app, State).failed = true
	foster.Exit(app)
}

startup :: proc(app: ^foster.App) {
	s := foster.AppGetUserDataAs(app, State)
	device := &app.GraphicsDevice
	s.materials = {device = device, storage = &s.resources}
	if reason := register_materials(&s.materials); reason != "" {
		fail(app, reason)
		return
	}
	for &model in s.models {
		reason: string
		model.mesh = &s.mesh
		model.material, reason = rendering.material_load(&s.materials, s.path)
		if reason != "" {
			fail(app, reason)
			return
		}
	}
	_ = rendering.material_set_number(s.models[1].material, "Preview3D", "hue", {0.7, 0, 0, 0})
	primitive := sphere()
	defer delete(primitive.vertices)
	defer delete(primitive.indices)
	if !r3d.mesh3d_upload(&s.mesh, device, &primitive) {
		fail(app, "Cannot upload model")
		return
	}
	foster.BatcherInit(&s.batch, device)
	world.camera3d_init(&s.camera, 1100, 720)
	world.camera3d_set_position(&s.camera, {0, 1.2, 6})
}

update :: proc(app: ^foster.App) {
	s := foster.AppGetUserDataAs(app, State)
	s.time += f32(app.Time.Delta)
	keys := &app.Input.State.Keyboard
	if foster.KeyboardPressed(keys, .Escape) do foster.Exit(app)
	if foster.KeyboardPressed(keys, .Space) do s.outline = !s.outline
	if foster.KeyboardPressed(keys, .R) {
		if reason := rendering.material_reload(&s.materials, s.models[0].material); reason != "" {
			fmt.eprintln(reason)
		}
	}
}

render :: proc(app: ^foster.App) {
	s := foster.AppGetUserDataAs(app, State)
	if s.failed do return
	device := &app.GraphicsDevice
	window := foster.DrawableTargetFromWindow(&app.Window)
	w, h := window.WidthInPixels, window.HeightInPixels
	if s.target.Width != w || s.target.Height != h {
		foster.TargetDispose(&s.target)
		foster.TargetInit(&s.target, device, w, h, []foster.TargetAttachmentSpec{{.Color, .Four}, {.Depth32, .Four}}, "model material")
	}
	target := foster.DrawableTargetFromTarget(&s.target)
	colors := [1]foster.Color{{31,38,51,255}}
	foster.GraphicsDeviceClear(device, target, colors[:], 1, 0, foster.ClearMask.Color | foster.ClearMask.Depth)
	world.camera3d_set_viewport(&s.camera, w, h)
	view := r3d.Model_View{target = target, view_projection = world.camera3d_view_projection(&s.camera),
		time = s.time, pass_limit = s.outline ? 0 : 1}
	for model, i in s.models {
		transform := world.matrix4_translation(i == 0 ? -1.25 : 1.25, 0, 0)
		if !r3d.model_draw(model, transform, view) {
			fail(app, "Cannot bind model material")
		}
	}
	foster.BatcherClear(&s.batch)
	foster.BatcherQuadTexture(&s.batch, foster.TargetAttachment(&s.target), {0,0}, {f32(w),0}, {f32(w),f32(h)}, {0,f32(h)}, {0,0},{1,0},{1,1},{0,1}, foster.White)
	foster.BatcherRender(&s.batch, window)
}

shutdown :: proc(app: ^foster.App) {
	s := foster.AppGetUserDataAs(app, State)
	rendering.materials_dispose(&s.materials)
	foster.MeshDispose(&s.mesh)
	foster.TargetDispose(&s.target)
	foster.BatcherDispose(&s.batch)
}

sphere :: proc() -> dasset.Dasset_Primitive {
	rings, segments :: 48, 64
	p := dasset.Dasset_Primitive{vertices = make([]dasset.Dasset_Vertex, (rings+1)*(segments+1)), indices = make([]u32, rings*segments*6)}
	for r in 0..=rings do for n in 0..=segments {
		theta, phi := f32(r)/rings*math.PI, f32(n)/segments*2*math.PI
		normal := [3]f32{math.sin(theta)*math.cos(phi), math.cos(theta), math.sin(theta)*math.sin(phi)}
		p.vertices[r*(segments+1)+n] = {position = normal, normal = normal, uv = {f32(n)/segments,f32(r)/rings}, tangent = {-math.sin(phi),0,math.cos(phi),1}}
	}
	for r in 0..<rings do for n in 0..<segments {
		a := u32(r*(segments+1)+n)
		copy(p.indices[(r*segments+n)*6:], []u32{a,a+1,a+segments+2,a,a+segments+2,a+segments+1})
	}
	return p
}
