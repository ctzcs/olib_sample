package main

// 书在固定相机前的姿态：四元数旋转、平移、相机与投影，以及鼠标拖拽。

// 分区：
//   类型 —— Book_Pose / Book_View / Book_Drag
//   四元数 —— quat_mul / quat_axis
//   姿态变换 —— default_pose / rotate_book / move_book / dolly_book
//   视图与投影 —— book_view / project
//   鼠标操作 —— manipulate_book

import "core:math"
import foster "olib:foster"
import kw "olib:kit/world"

// ==============================================================================
// 类型
// ==============================================================================

// 旋转用单位四元数 (x, y, z, w)，书可以不受万向锁限制地自由转 360 度。
Book_Pose :: struct {
	position: foster.Vec3,
	rotation: [4]f32,
}

// 书空间与屏幕互换所需的一切。由 pose 派生：pose 或窗口尺寸可能变化后立即用
// book_view 重建。
Book_View :: struct {
	camera:              kw.Camera3D,
	model, inverse_model: kw.Matrix4, // 书空间 <-> 世界空间
	mvp:                 kw.Matrix4,  // 书空间 -> 裁剪空间
	w, h:                f32,            // 可绘制区域的像素尺寸
}

Drag_Mode :: enum {
	None,
	Rotate,
	Roll,
	Pan,
}

Book_Drag :: struct {
	mode:     Drag_Mode,
	previous: foster.Vec2, // 上一帧的指针位置
}

ROTATE_RADIANS_PER_PIXEL :: 0.008
DOLLY_UNITS_PER_WHEEL_STEP :: 65

// ==============================================================================
// 四元数
// ==============================================================================

// Hamilton 乘积，结果重新归一化，多次细小拖拽也不会累积漂移。
quat_mul :: proc(a, b: [4]f32) -> [4]f32 {
	av, bv := foster.Vec3{a[0], a[1], a[2]}, foster.Vec3{b[0], b[1], b[2]}
	xyz := av * b[3] + bv * a[3] + kw.v3_cross(av, bv)
	w := a[3] * b[3] - kw.v3_dot(av, bv)
	l := math.sqrt(kw.v3_dot(xyz, xyz) + w * w)
	return {xyz.x / l, xyz.y / l, xyz.z / l, w / l}
}

quat_axis :: proc(axis: foster.Vec3, angle: f32) -> [4]f32 {
	s := math.sin(angle * 0.5)
	return {axis.x * s, axis.y * s, axis.z * s, math.cos(angle * 0.5)}
}

// ==============================================================================
// 姿态变换
// ==============================================================================

// 初始姿态：比中心略低、离相机略近，像放在桌上一样往后仰，再带一点转动和
// 侧倾，避免看起来是平的。
default_pose :: proc() -> Book_Pose {
	roll := quat_axis({0, 0, 1}, -0.035)
	yaw := quat_axis({0, 1, 0}, 0.08)
	pitch := quat_axis({1, 0, 0}, -0.38)
	return {{0, -35, 170}, quat_mul(roll, quat_mul(yaw, pitch))}
}

// 水平拖动偏航、竖直拖动俯仰；`roll` 时水平拖动改为绕屏幕轴侧倾。
rotate_book :: proc(pose: ^Book_Pose, delta: foster.Vec2, roll: bool) {
	k :: ROTATE_RADIANS_PER_PIXEL
	q: [4]f32
	if roll {
		q = quat_axis({0, 0, 1}, -delta.x * k)
	} else {
		q = quat_mul(quat_axis({0, 1, 0}, delta.x * k), quat_axis({1, 0, 0}, delta.y * k))
	}
	pose.rotation = quat_mul(q, pose.rotation)
}

// 平移书，让它在当前深度上正好跟住指针。
move_book :: proc(pose: ^Book_Pose, delta: foster.Vec2, view: Book_View) {
	depth := view.camera.position.z - pose.position.z
	units_per_pixel := 2 * depth * math.tan(view.camera.field_of_view * 0.5) / view.h
	pose.position += foster.Vec3{delta.x * units_per_pixel, -delta.y * units_per_pixel, 0}
}

dolly_book :: proc(pose: ^Book_Pose, wheel: f32) {
	pose.position.z = math.clamp(pose.position.z + wheel * DOLLY_UNITS_PER_WHEEL_STEP, -2000, 650)
}

// ==============================================================================
// 视图与投影
// ==============================================================================

book_view :: proc(pose: Book_Pose, w, h: f32) -> Book_View {
	v: Book_View
	v.w, v.h = w, h
	kw.camera3d_init(&v.camera, int(w), int(h))
	kw.camera3d_set_field_of_view(&v.camera, PI / 4)
	// Geometry uses pixel-sized world units. A 20-unit near plane preserves
	// precision between the top page and its paper block at a 1400-unit camera.
	kw.camera3d_set_near_clip(&v.camera, 20)
	kw.camera3d_set_far_clip(&v.camera, 6000)
	// 窗口较窄时相机后退，保证摊开的书仍放得下。
	kw.camera3d_set_position(&v.camera, {0, 0, max(1400, 1600 / (w / max(h, 1)))})
	kw.camera3d_set_target(&v.camera, {0, 0, 0})
	// kit/world 用行向量：先旋转，再平移。
	rotation := kw.matrix4_from_quaternion(pose.rotation)
	translation := kw.matrix4_translation(pose.position.x, pose.position.y, pose.position.z)
	v.model = kw.matrix4_multiply(rotation, translation)
	ok: bool
	v.inverse_model, ok = kw.matrix4_inverse(v.model)
	assert(ok)
	v.mvp = kw.matrix4_multiply(v.model, kw.camera3d_view_projection(&v.camera))
	return v
}

// 书空间 -> 屏幕像素。相机背后的点投到屏幕外很远处。
project :: proc(v: Book_View, p: foster.Vec3) -> foster.Vec2 {
	h := kw.matrix4_transform_vec4(v.mvp, {p.x, p.y, p.z, 1})
	if h.w <= 0.001 do return {-10000, -10000}
	return {(h.x / h.w + 1) * v.w * 0.5, (1 - h.y / h.w) * v.h * 0.5}
}

// ==============================================================================
// 鼠标操作
// ==============================================================================

// 右键拖动旋转（按住 Shift 为侧倾），中键拖动平移，滚轮调深度，R 复位。
// 左键留给页面 UI。
manipulate_book :: proc(world: ^World, app: ^foster.App, over_overlay: bool) {
	if world.opts.test do return
	mouse := &app.Input.State.Mouse
	key := &app.Input.State.Keyboard
	if foster.KeyboardPressed(key, .R) {
		reset_pose(world)
	}
	if world.drag.mode == .None && !over_overlay {
		if foster.MousePressed(mouse, .Right) {
			shift := foster.KeyboardDown(key, .LeftShift) || foster.KeyboardDown(key, .RightShift)
			world.drag = {shift ? .Roll : .Rotate, world.pointer}
		} else if foster.MousePressed(mouse, .Middle) {
			world.drag = {.Pan, world.pointer}
		}
		if mouse.Wheel.Y != 0 {
			dolly_book(&world.pose, mouse.Wheel.Y)
		}
	}
	if world.drag.mode != .None {
		button: foster.MouseButtons = world.drag.mode == .Pan ? .Middle : .Right
		if !foster.MouseDown(mouse, button) {
			world.drag.mode = .None
			return
		}
		delta := world.pointer - world.drag.previous
		if world.drag.mode == .Pan {
			move_book(&world.pose, delta, world.view)
		} else {
			rotate_book(&world.pose, delta, world.drag.mode == .Roll)
		}
		world.drag.previous = world.pointer
	}
}

reset_pose :: proc(world: ^World) {
	world.pose = default_pose()
	world.drag.mode = .None
}
