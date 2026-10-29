package main

import "core:math"
import "core:math/linalg"

import dasset "olib:core/dasset"
import foster "olib:foster"
import r2d "olib:kit/rendering/2d"
import r3d "olib:kit/rendering/3d"
import mat "olib:kit/rendering/material"
import world "olib:kit/world"
import "olib:thirdparty/onet/objects"

// ==============================================================================
// 3D 表现：关卡与角色都是着色的盒子，一个实例化 Shader 三种材质（场景/角色/发光）
// ==============================================================================

SKY :: [4]f32{0.62, 0.72, 0.84, 1}
cube_bounds := dasset.Dasset_Bounds{min = {-0.5, -0.5, -0.5}, max = {0.5, 0.5, 0.5}}
FOV :: f32(1.25)

Tracer :: struct {
	from, to: [3]f32,
	life:     f32,
	own:      bool,
}

Remote :: struct {
	pos:    [3]f32,
	health: i32,
	flash:  f32,
	seen:   bool,
}

View :: struct {
	// 3D
	materials:    mat.Material_Library,
	renderer:     r3d.Render3D,
	cube:         foster.Mesh,
	solid, actor, glow: ^mat.Material,
	scene:        foster.Target,
	camera:       world.Camera3D,
	items:        [dynamic]r3d.Model_Item, // 每帧重建的场景/角色实例
	glows:        [dynamic]r3d.Model_Item,
	ready:        bool,
	error:        string,
	// 2D
	ui:           r2d.Render2D,
	font_source:  foster.Font,
	font:         foster.SpriteFont,
	font_big:     foster.SpriteFont,
	has_font:     bool,
	// 效果与表现状态
	remotes:      map[objects.Network_Id]Remote,
	tracers:      [dynamic]Tracer,
	feed:         [dynamic]Feed,
	muzzle, kick: f32,
	spread:       f32,
	hitmarker:    f32,
	hit_head:     bool,
	damage_flash: f32,
	last_health:  i32,
	time:         f32,
}

register_shaders :: proc(library: ^mat.Material_Library) -> string {
	arena := [?]mat.Pass_Binaries{{
		vertex = {
			spv = #load("shaders/Compiled/Arena_main.vertex.spv"),
			dxil = #load("shaders/Compiled/Arena_main.vertex.dxil"),
			msl = #load("shaders/Compiled/Arena_main.vertex.msl"),
		},
		fragment = {
			spv = #load("shaders/Compiled/Arena_main.fragment.spv"),
			dxil = #load("shaders/Compiled/Arena_main.fragment.dxil"),
			msl = #load("shaders/Compiled/Arena_main.fragment.msl"),
		},
	}}
	return mat.material_register_manifest(library, #load("shaders/Compiled/Arena.shader.json"), arena[:])
}

view_init :: proc(v: ^View, app: ^foster.App) {
	device := &app.GraphicsDevice
	// Render2D 借用材质库：先建库，再初始化 2D；释放时顺序相反。
	v.materials = {device = device}
	hud_init(v, app)
	if v.error = register_shaders(&v.materials); v.error != "" do return
	reason: string
	if v.solid, reason = mat.material_create(&v.materials, "Arena"); reason != "" {
		v.error = reason
		return
	}
	v.actor, _ = mat.material_create(&v.materials, "Arena")
	v.glow, _ = mat.material_create(&v.materials, "Arena")
	_ = mat.material_set_number(v.actor, "Arena_main", "grid", {0, 0, 0, 0})
	_ = mat.material_set_number(v.glow, "Arena_main", "grid", {0, 0, 0, 0})
	_ = mat.material_set_number(v.glow, "Arena_main", "emissive", {1, 0, 0, 0})
	cube := cube_primitive()
	defer delete(cube.vertices)
	defer delete(cube.indices)
	if !r3d.mesh_upload(&v.cube, device, &cube) {
		v.error = "Cannot upload cube mesh"
		return
	}
	if v.error = r3d.init(&v.renderer, &v.materials); v.error != "" do return
	world.camera3d_init(&v.camera, 1280, 800)
	world.camera3d_set_field_of_view(&v.camera, FOV)
	world.camera3d_set_near_clip(&v.camera, 0.04)
	world.camera3d_set_far_clip(&v.camera, 160)
	v.ready = true
}

view_destroy :: proc(v: ^View) {
	r3d.dispose(&v.renderer)
	r3d.mesh_dispose(&v.cube)
	foster.TargetDispose(&v.scene)
	hud_destroy(v)
	mat.material_library_dispose(&v.materials)
	delete(v.items)
	delete(v.glows)
	delete(v.remotes)
	delete(v.tracers)
	delete(v.feed)
}

view_reset :: proc(v: ^View) {
	clear(&v.remotes)
	clear(&v.tracers)
	clear(&v.feed)
	v.muzzle, v.kick, v.hitmarker, v.damage_flash = 0, 0, 0, 0
}

// 单位立方体，每面 4 个顶点保留硬边法线；正面逆时针配合 Cull Back。
cube_primitive :: proc() -> dasset.Dasset_Primitive {
	p := dasset.Dasset_Primitive{vertices = make([]dasset.Dasset_Vertex, 24), indices = make([]u32, 36)}
	faces := [6][3][3]f32{
		{{1, 0, 0}, {0, 0, -1}, {0, 1, 0}},
		{{-1, 0, 0}, {0, 0, 1}, {0, 1, 0}},
		{{0, 1, 0}, {1, 0, 0}, {0, 0, -1}},
		{{0, -1, 0}, {1, 0, 0}, {0, 0, 1}},
		{{0, 0, 1}, {1, 0, 0}, {0, 1, 0}},
		{{0, 0, -1}, {-1, 0, 0}, {0, 1, 0}},
	}
	corners := [4][2]f32{{-1, -1}, {1, -1}, {1, 1}, {-1, 1}}
	for face, f in faces {
		n, u, w := face[0], face[1], face[2]
		for c, k in corners {
			position := n * 0.5 + u * (c[0] * 0.5) + w * (c[1] * 0.5)
			p.vertices[f * 4 + k] = {position = position, normal = n, uv = {c[0] * 0.5 + 0.5, 0.5 - c[1] * 0.5},
				tangent = {u[0], u[1], u[2], 1}}
		}
		base := u32(f * 4)
		copy(p.indices[f * 6:], []u32{base, base + 1, base + 2, base, base + 2, base + 3})
	}
	return p
}

// 先缩放，再绕 X 俯仰、绕 Y 偏航，最后平移（行向量约定 v * S * Rx * Ry * T）。
// 盒子的长轴是 -Z，yaw/pitch 与 look_dir 同一约定；行向量下四元数矩阵按反方向旋转，所以角度取负。
place :: proc(center, size: [3]f32, yaw: f32 = 0, pitch: f32 = 0) -> world.Matrix4 {
	m := world.matrix4_scaling(size.x, size.y, size.z)
	if pitch != 0 {
		m = world.matrix4_multiply(m, world.matrix4_from_quaternion({math.sin(-pitch * 0.5), 0, 0, math.cos(pitch * 0.5)}))
	}
	if yaw != 0 {
		m = world.matrix4_multiply(m, world.matrix4_from_quaternion({0, math.sin(-yaw * 0.5), 0, math.cos(yaw * 0.5)}))
	}
	return world.matrix4_multiply(m, world.matrix4_translation(center.x, center.y, center.z))
}

// 沿 from → to 拉长的细盒子。
beam :: proc(from, to: [3]f32, thickness: f32) -> world.Matrix4 {
	d := to - from
	length := linalg.length(d)
	yaw := math.atan2(-d.x, -d.z)
	pitch := math.atan2(d.y, linalg.length(d.xz))
	return place((from + to) * 0.5, {thickness, thickness, max(length, 0.01)}, yaw, pitch)
}

slot_tint :: proc(slot: i32) -> [4]f32 {
	c := SLOT_COLORS[int(slot) % MAX_PLAYERS]
	return {f32(c.R) / 255, f32(c.G) / 255, f32(c.B) / 255, 1}
}

// 纯服务器没有客户端世界，观战画面直接读权威 Registry。
view_registry :: proc(a: ^App) -> ^objects.Registry {
	return a.client_ready ? &a.client_reg : &a.server_reg
}

fx_shot :: proc(v: ^View, from, to: [3]f32, own: bool) {
	append(&v.tracers, Tracer{from, to, 0.09, own})
	if own {
		v.muzzle, v.kick, v.spread = 1, 1, min(v.spread + 0.35, 1)
	}
}

// ==============================================================================
// 每帧：远端角色平滑、效果衰减、受伤检测
// ==============================================================================

view_update :: proc(a: ^App, dt: f32) {
	v := &a.view
	follow := 1 - math.exp(-20 * dt)
	for _, &r in v.remotes do r.seen = false
	my_id, me := local_player(a)
	for id, obj in view_registry(a).objects {
		p := objects.component_data(obj, Player, PLAYER_TYPE)
		if p == nil || id == my_id do continue
		if id not_in v.remotes do v.remotes[id] = Remote{pos = p.pos, health = p.health}
		r := &v.remotes[id]
		r.seen = true
		// 远端角色的世界快照直接写最新权威值；显示层自己插值去掉 50 Hz 的阶梯感。
		r.pos = linalg.lerp(r.pos, p.pos, follow)
		if linalg.length(r.pos - p.pos) > 3 do r.pos = p.pos // 重生瞬移
		if p.health < r.health do r.flash = 1
		r.health = p.health
		r.flash = max(0, r.flash - dt * 8)
	}
	gone := make([dynamic]objects.Network_Id, context.temp_allocator)
	for id, r in v.remotes do if !r.seen do append(&gone, id)
	for id in gone do delete_key(&v.remotes, id)

	if me != nil {
		if me.health < v.last_health do v.damage_flash = 1
		v.last_health = me.health
	}
	for i := len(v.tracers) - 1; i >= 0; i -= 1 {
		v.tracers[i].life -= dt
		if v.tracers[i].life <= 0 do unordered_remove(&v.tracers, i)
	}
	for i := len(v.feed) - 1; i >= 0; i -= 1 {
		v.feed[i].life -= dt
		if v.feed[i].life <= 0 do ordered_remove(&v.feed, i)
	}
	v.muzzle = max(0, v.muzzle - dt * 18)
	v.kick = max(0, v.kick - dt * 10)
	v.spread = max(0, v.spread - dt * 3)
	v.hitmarker = max(0, v.hitmarker - dt * 4)
	v.damage_flash = max(0, v.damage_flash - dt * 2.5)
}

// ==============================================================================
// 绘制：场景画进带深度的离屏目标，再和 HUD 一起画到窗口
// ==============================================================================

camera_pose :: proc(a: ^App) -> (eye: [3]f32, yaw, pitch: f32, ok: bool) {
	_, me := local_player(a)
	if me != nil {
		// 本地角色由预测逐 tick 推进；视角直接用本帧鼠标值，不等 tick。阵亡时不画枪。
		return eye_of(me.pos), a.yaw, a.pitch, me.respawn <= 0
	}
	// 观战 / 等待连接：绕场地缓慢旋转。
	t := a.view.time * 0.12
	eye = {math.sin(t) * 22, 11, math.cos(t) * 22}
	yaw = math.atan2(eye.x, eye.z)
	pitch = -math.atan2(eye.y - 1, linalg.length(eye.xz))
	return eye, yaw, pitch, false
}

render_game :: proc(a: ^App, app: ^foster.App, target: foster.DrawableTarget) {
	v := &a.view
	device := &app.GraphicsDevice
	w, h := target.WidthInPixels, target.HeightInPixels
	if !v.ready || w <= 0 || h <= 0 {
		return
	}
	if v.scene.Width != w || v.scene.Height != h {
		r3d.clear(&v.renderer)
		foster.TargetDispose(&v.scene)
		attachments := [2]foster.TargetAttachmentSpec{{Format = .Color}, {Format = .Depth32}}
		foster.TargetInit(&v.scene, device, w, h, attachments[:], "net_fps scene")
	}

	eye, yaw, pitch, alive := camera_pose(a)
	forward := look_dir(yaw, pitch)
	world.camera3d_set_viewport(&v.camera, w, h)
	world.camera3d_set_position(&v.camera, eye)
	world.camera3d_set_target(&v.camera, eye + forward)

	r3d.clear(&v.renderer)
	record_scene(a, eye, yaw, pitch, alive)
	scene := foster.DrawableTargetFromTarget(&v.scene)
	sky := [1]foster.Color{{158, 184, 214, 255}}
	foster.GraphicsDeviceClear(device, scene, sky[:], 1, 0, foster.ClearMask.Color | foster.ClearMask.Depth)
	view := r3d.View{target = scene, view_projection = world.camera3d_view_projection(&v.camera),
		view_matrix = world.camera3d_view(&v.camera), time = v.time}
	if err := r3d.submit(&v.renderer, view); err != .None {
		v.error = mat.draw_error_text(err)
	}

	b := &v.ui
	foster.GraphicsDeviceClear(device, target, foster.Black)
	r2d.texture(b, foster.TargetAttachment(&v.scene, 0), foster.Matrix3x2Identity)
	draw_hud(a, f32(w), f32(h))
	if err := r2d.submit(b, {target = target, time = v.time}); err != .None {
		v.error = mat.draw_error_text(err)
	}
}

record_scene :: proc(a: ^App, eye: [3]f32, yaw, pitch: f32, alive: bool) {
	v := &a.view
	clear(&v.items)
	clear(&v.glows)
	for b in level {
		append(&v.items, r3d.Model_Item{place((b.min + b.max) * 0.5, b.max - b.min), b.color})
	}
	r3d.models(&v.renderer, &v.cube, v.solid, v.items[:], &cube_bounds)

	clear(&v.items)
	for id, r in v.remotes {
		obj, ok := objects.get(view_registry(a), id)
		if !ok do continue
		p := objects.component_data(obj, Player, PLAYER_TYPE)
		if p == nil || p.respawn > 0 do continue
		tint := slot_tint(p.slot)
		if r.flash > 0 do tint = linalg.lerp(tint, [4]f32{1, 1, 1, 1}, r.flash)
		dark := [4]f32{tint.r * 0.45, tint.g * 0.45, tint.b * 0.45, 1}
		append(&v.items, r3d.Model_Item{place(r.pos + {0, 0.42, 0}, {0.5, 0.84, 0.34}, p.yaw), dark})
		append(&v.items, r3d.Model_Item{place(r.pos + {0, 1.13, 0}, {0.64, 0.62, 0.4}, p.yaw), tint})
		append(&v.items, r3d.Model_Item{place(r.pos + {0, 1.6, 0}, {0.4, 0.4, 0.4}, p.yaw), tint})
		fwd := [3]f32{-math.sin(p.yaw), 0, -math.cos(p.yaw)}
		right := [3]f32{math.cos(p.yaw), 0, -math.sin(p.yaw)}
		gun := r.pos + {0, 1.2, 0} + right * 0.3 + look_dir(p.yaw, p.pitch) * 0.3
		append(&v.items, r3d.Model_Item{place(gun, {0.09, 0.12, 0.62}, p.yaw, p.pitch), {0.16, 0.17, 0.2, 1}})
		append(&v.glows, r3d.Model_Item{place(r.pos + {0, 1.64, 0} + fwd * 0.2, {0.3, 0.09, 0.04}, p.yaw), {0.95, 0.98, 1, 1}})
	}

	// 第一人称枪：相机坐标系里的固定位置，开火时后坐。
	if alive {
		fwd := look_dir(yaw, pitch)
		right := [3]f32{math.cos(yaw), 0, -math.sin(yaw)}
		up := linalg.cross(right, fwd)
		_, me := local_player(a)
		bob := me != nil ? math.sin(v.time * 9) * 0.006 * min(1, linalg.length(me.vel.xz) / MOVE_SPEED) : 0
		base := eye + fwd * (0.55 - v.kick * 0.05) + right * 0.17 - up * (0.15 - bob)
		append(&v.items, r3d.Model_Item{place(base, {0.045, 0.06, 0.3}, yaw, pitch + v.kick * 0.04), {0.2, 0.21, 0.25, 1}})
		append(&v.items, r3d.Model_Item{place(base - fwd * 0.09 - up * 0.05, {0.04, 0.09, 0.05}, yaw, pitch + 0.25), {0.32, 0.24, 0.17, 1}})
		append(&v.items, r3d.Model_Item{place(base + up * 0.036 - fwd * 0.03, {0.012, 0.012, 0.12}, yaw, pitch), {0.2, 0.7, 0.62, 1}})
		if v.muzzle > 0 {
			tip := base + fwd * 0.18
			s := 0.03 + 0.025 * v.muzzle
			append(&v.glows, r3d.Model_Item{place(tip, {s, s, s}, yaw + v.time * 7, pitch), {1, 0.85, 0.45, 1}})
		}
	}
	if len(v.items) > 0 do r3d.models(&v.renderer, &v.cube, v.actor, v.items[:], &cube_bounds)

	for t in v.tracers {
		from := t.from
		if t.own && alive {
			fwd := look_dir(yaw, pitch)
			right := [3]f32{math.cos(yaw), 0, -math.sin(yaw)}
			from = eye + fwd * 0.72 + right * 0.17 - linalg.cross(right, fwd) * 0.13
		}
		k := t.life / 0.09
		append(&v.glows, r3d.Model_Item{beam(from, t.to, 0.025 * k + 0.01), {1, 0.9, 0.55, 1}})
		append(&v.glows, r3d.Model_Item{place(t.to, {0.12, 0.12, 0.12} * k, v.time * 5), {1, 0.75, 0.35, 1}})
	}
	if len(v.glows) > 0 do r3d.models(&v.renderer, &v.cube, v.glow, v.glows[:], &cube_bounds)
}
