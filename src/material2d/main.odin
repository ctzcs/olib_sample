package main

// 两个精灵使用同一效果、独立参数；和 3D 共用材质资源 API。
import "core:fmt"
import "core:math"
import foster "olib:foster"
import rendering "olib:kit/rendering"

State :: struct {
	resources: foster.StorageContainer,
	materials: rendering.Material_Library,
	renderer: rendering.Sprite_Renderer,
	sprites: [2]rendering.Sprite_Instance,
	texture: foster.Texture,
	time: f32,
	failed: bool,
}

main :: proc() {
	s := new(State)
	defer free(s)
	app: foster.App
	foster.InitApp(&app, foster.DefaultAppConfig("Material2D | R: reload left material | Esc: exit", 1000, 640))
	foster.AppSetUserData(&app, s)
	app.StartupProc = startup
	app.UpdateProc = update
	app.RenderProc = render
	app.ShutdownProc = shutdown
	foster.Run(&app)
	foster.Dispose(&app)
	delete(app.GraphicsDevice.WindowRenderTarget.Attachments)
}

startup :: proc(app: ^foster.App) {
	s := foster.AppGetUserDataAs(app, State)
	s.resources.Root = #directory
	s.materials = {device = &app.GraphicsDevice, storage = &s.resources}
	if reason := register_materials(&s.materials); reason != "" {
		fail(app, reason)
		return
	}
	rendering.sprite_renderer_init(&s.renderer, &app.GraphicsDevice)
	image := foster.ImageMake(256, 256)
	defer foster.ImageDispose(&image)
	for y in 0..<256 {
		for x in 0..<256 {
			dx, dy := f32(x)-127.5, f32(y)-127.5
			alpha := math.clamp(104-math.sqrt(dx*dx+dy*dy), 0, 1)
			value := (x/32+y/32)%2 == 0 ? u8(255) : u8(150)
			foster.ImageSetPixel(&image, x, y, {value, value, value, u8(alpha*255)})
		}
	}
	foster.ImagePremultiply(&image)
	s.texture = foster.TextureFromImage(&app.GraphicsDevice, &image, "sprite frame")
	for &sprite in s.sprites {
		sprite.frame = foster.SubtextureFromTexture(&s.texture)
		sprite.origin = {128, 128}
		reason: string
		sprite.material, reason = rendering.material_load(&s.materials, "material.json")
		if reason != "" {
			fail(app, reason)
			return
		}
	}
	_ = rendering.material_set_number(s.sprites[1].material, "Sprite", "hue", {0.7, 0, 0, 0})
}

fail :: proc(app: ^foster.App, reason: string) {
	fmt.eprintln(reason)
	foster.AppGetUserDataAs(app, State).failed = true
	foster.Exit(app)
}

update :: proc(app: ^foster.App) {
	s := foster.AppGetUserDataAs(app, State)
	s.time += f32(app.Time.Delta)
	keys := &app.Input.State.Keyboard
	if foster.KeyboardPressed(keys, .Escape) do foster.Exit(app)
	if foster.KeyboardPressed(keys, .R) {
		if reason := rendering.material_reload(&s.materials, s.sprites[0].material); reason != "" {
			fmt.eprintln(reason)
		}
	}
}

render :: proc(app: ^foster.App) {
	s := foster.AppGetUserDataAs(app, State)
	if s.failed do return
	target := foster.DrawableTargetFromWindow(&app.Window)
	foster.GraphicsDeviceClear(&app.GraphicsDevice, target, foster.Color{31, 38, 51, 255})
	view := rendering.Sprite_View{target = target, time = s.time}
	for sprite, i in s.sprites {
		x := f32(target.WidthInPixels)/2 + (i == 0 ? -130 : 130)
		y := f32(target.HeightInPixels)/2 + math.sin(s.time+f32(i))*25
		if !rendering.sprite_draw(&s.renderer, sprite, {1.3, 0, 0, 1.3, x, y}, view) {
			fail(app, "Cannot draw sprite material")
		}
	}
}

shutdown :: proc(app: ^foster.App) {
	s := foster.AppGetUserDataAs(app, State)
	rendering.materials_dispose(&s.materials)
	rendering.sprite_renderer_dispose(&s.renderer)
	foster.TextureDispose(&s.texture)
}
