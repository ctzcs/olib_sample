package main

// 先画所有阴影，再画所有本体；空格切换逐对象绘制，控制台报告真实 Draw 次数。
import "core:fmt"
import "core:math"
import foster "olib:foster"
import rendering "olib:kit/rendering"

State :: struct {
	resources: foster.StorageContainer,
	materials: rendering.Material_Library,
	renderer: rendering.Sprite_Renderer,
	sprites: [12]rendering.Sprite_Instance,
	texture: foster.Texture,
	time: f32,
	failed: bool,
	grouped: bool,
	reported: bool,
	last_grouped: bool,
	last_draw_calls: int,
}

main :: proc() {
	s := new(State)
	defer free(s)
	s.grouped = true
	app: foster.App
	foster.InitApp(&app, foster.DefaultAppConfig("Material2D | Space: grouped/object passes | R: reload left | Esc: exit", 1000, 640))
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
	instances: [2]^rendering.Material
	for &material in instances {
		reason: string
		material, reason = rendering.material_load(&s.materials, "material.json")
		if reason != "" {
			fail(app, reason)
			return
		}
	}
	_ = rendering.material_set_number(instances[1], "Sprite", "hue", {0.7, 0, 0, 0})
	for &sprite, i in s.sprites {
		sprite.frame = foster.SubtextureFromTexture(&s.texture)
		sprite.origin = {128, 128}
		sprite.material = instances[i/6]
	}
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
	if foster.KeyboardPressed(keys, .Space) do s.grouped = !s.grouped
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
	transforms: [len(s.sprites)]foster.Matrix3x2
	for &transform, i in transforms {
		x := f32(target.WidthInPixels)/2 + (f32(i/3)-1.5)*125
		y := f32(target.HeightInPixels)/2 + (f32(i%3)-1)*125 + math.sin(s.time+f32(i))*12
		transform = {0.75, 0, 0, 0.75, x, y}
	}
	if !rendering.sprite_begin(&s.renderer) {
		fail(app, "Cannot begin sprite rendering")
		return
	}
	if s.grouped {
		// 顺序由使用者选择；Renderer 只合并相邻兼容绘制。
		for sprite, i in s.sprites {
			if !rendering.sprite_draw_pass(&s.renderer, sprite, "shadow", transforms[i], view) {
				fail(app, "Cannot draw sprite shadow")
			}
		}
	}
	for sprite, i in s.sprites {
		ok := false
		if s.grouped {
			ok = rendering.sprite_draw_pass(&s.renderer, sprite, "body", transforms[i], view)
		} else {
			ok = rendering.sprite_draw(&s.renderer, sprite, transforms[i], view)
		}
		if !ok {
			fail(app, "Cannot draw sprite material")
		}
	}
	rendering.sprite_end(&s.renderer)
	if !s.reported || s.last_grouped != s.grouped || s.last_draw_calls != s.renderer.draw_calls {
		fmt.printf("%s: %d sprite passes -> %d draws\n",
			s.grouped ? "All shadows, then all bodies" : "All passes per object",
			s.renderer.sprite_passes, s.renderer.draw_calls)
		s.reported = true
		s.last_grouped = s.grouped
		s.last_draw_calls = s.renderer.draw_calls
	}
}

shutdown :: proc(app: ^foster.App) {
	s := foster.AppGetUserDataAs(app, State)
	rendering.materials_dispose(&s.materials)
	rendering.sprite_renderer_dispose(&s.renderer)
	foster.TextureDispose(&s.texture)
}
