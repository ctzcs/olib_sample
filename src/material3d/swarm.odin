package main

// 大批量实例化：一个低模球体 + 一个 Model_Buffer，默认 100 万个实例，每个 Pass 只有 1 次 Draw。
// 实例数据（世界矩阵、tint、hue）在加载时一次性上传，之后每帧零 CPU 开销；颜色动画在着色器里按 Clock 计算。
// 真实游戏做视锥/遮挡剔除时，把实例按空间分块放进多个 Model_Buffer，只画可见的块。
import "core:math"

import foster "olib:foster"
import r3d "olib:kit/rendering/3d"
import mat "olib:kit/rendering/material"
import world "olib:kit/world"

SWARM_DEFAULT_COUNT :: 1_000_000

Swarm :: struct {
	mesh: foster.Mesh,
	material: ^mat.Material,
	instances: r3d.Model_Buffer,
	count: int,
	ready: bool,
}

// 整数哈希到 0..1，让摆放确定且可重复。
swarm_hash :: proc(value: u32) -> f32 {
	x := value
	x ~= x >> 16
	x *= 0x7feb352d
	x ~= x >> 15
	x *= 0x846ca68b
	x ~= x >> 16
	return f32(x & 0xffffff) / f32(0x1000000)
}

swarm_init :: proc(s: ^State, device: ^foster.GraphicsDevice, count: int) -> string {
	swarm := &s.swarm
	primitive := sphere(s.rings, s.segments)
	defer delete(primitive.vertices)
	defer delete(primitive.indices)
	if !r3d.mesh3d_upload(&swarm.mesh, device, &primitive, "swarm") do return "Cannot upload swarm mesh"
	material, reason := mat.material_load(&s.materials, "swarm.json")
	if reason != "" do return reason
	swarm.material = material
	// 字段名解析成槽位句柄：百万次赋值里没有字符串比较。
	hue := mat.instance_slot(material, "hue")
	if !hue.valid do return "Material has no hue Instance field"
	// 缓冲的槽数（每个实例的 [Instance] 字段数）取自材质，平铺数组的步长也用它。
	if !r3d.model_buffer_init(&swarm.instances, material, count, "swarm instances") {
		return "Cannot create instance buffer"
	}
	instances := make([]r3d.Model_Item, count)
	defer delete(instances)
	slots := swarm.instances.slots
	values := make([][4]f32, count*slots) // 每个实例连续 slots 个 float4
	defer delete(values)
	side := int(math.ceil(math.pow(f32(count), 1.0/3.0)))
	spacing :: f32(0.6)
	for &instance, i in instances {
		layer := i / (side*side)
		// 相机在 +Z：z 大的更近。默认先画近处，让提前深度测试丢掉被挡住的片元；参数 back 反过来（最差情况）。
		if !s.back do layer = side - 1 - layer
		x, y, z := f32(i % side), f32((i / side) % side), f32(layer)
		half := f32(side) / 2
		jitter := swarm_hash(u32(i))
		scale := 0.10 + 0.14*swarm_hash(u32(i) + 0x9e3779b9)
		translation := world.matrix4_translation((x-half)*spacing, (y-half)*spacing, (z-half)*spacing)
		instance.world = world.matrix4_multiply(world.matrix4_scaling(scale, scale, scale), translation)
		instance.tint = {0.75 + 0.25*jitter, 0.75 + 0.25*swarm_hash(u32(i)*3 + 1), 1, 1}
		_ = mat.instance_array_set(values, slots, i, hue, {z/f32(side), 0, 0, 0}) // hue 沿 Z 轴渐变
	}
	if !r3d.model_buffer_upload(&swarm.instances, instances, 0, values) do return "Cannot upload instances"
	swarm.count = count
	swarm.ready = true
	return ""
}

swarm_dispose :: proc(s: ^State) {
	if !s.swarm.ready do return
	r3d.model_buffer_dispose(&s.swarm.instances)
	foster.MeshDispose(&s.swarm.mesh)
	s.swarm = {}
}
