package main

// 百万精灵：一个 Sprite_Buffer，默认 1,000,000 个精灵，只有 1 次 Draw。
// 每个精灵的变换、tint、hue、opacity、运动参数在加载时一次性上传，之后每帧零 CPU 开销：
// 所有精灵每帧都在动，位置由顶点着色器按 Clock 和各自的运动参数计算。
// 真实游戏把可见的精灵分块放进多个缓冲，或只更新变化的区间（sprite_buffer_upload 的 first 参数）。
import "core:math"

import foster "olib:foster"
import r2d "olib:kit/rendering/2d"
import mat "olib:kit/rendering/material"

SWARM_DEFAULT_COUNT :: 1_000_000

Swarm :: struct {
	buffer: r2d.Sprite_Buffer,
	count: int,
	ready: bool,
}

swarm_init :: proc(s: ^State, count: int, width, height: f32) -> string {
	// 字段名解析成槽位句柄：百万次赋值里没有字符串比较；名字写错或不是 [Instance] 时句柄无效。
	hue := mat.instance_slot(s.material, "hue")
	opacity := mat.instance_slot(s.material, "opacity")
	motion := mat.instance_slot(s.material, "motion")
	if !hue.valid || !opacity.valid || !motion.valid do return "Material has no hue / opacity / motion Instance fields"
	// 缓冲的槽数（每个精灵的 [Instance] 字段数）取自材质，平铺数组的步长也用它。
	if reason := r2d.sprite_buffer_init(&s.swarm.buffer, s.material, count, "swarm sprites"); reason != "" {
		return reason
	}
	items := make([]r2d.Sprite_Item, count)
	defer delete(items)
	slots := s.swarm.buffer.slots
	values := make([][4]f32, count*slots) // 每个精灵连续 slots 个 float4
	defer delete(values)
	frame := foster.SubtextureFromTexture(&s.texture)
	columns := int(math.ceil(math.sqrt(f32(count) * width / height)))
	rows := (count + columns - 1) / columns
	spacing := math.min(width / f32(columns), height / f32(rows))
	scale := spacing * 1 / 256 // 精灵比间距略大，相邻精灵稍有重叠
	for &item, i in items {
		x, y := f32(i % columns), f32(i / columns)
		px := width/2 + (x - f32(columns)/2) * spacing
		py := height/2 + (y - f32(rows)/2) * spacing
		item = r2d.sprite_item_make(frame, {128, 128}, {scale, 0, 0, scale, px, py},
			{0.8 + 0.2*math.sin(x*0.05), 0.8 + 0.2*math.sin(y*0.07), 1, 1})
		_ = mat.instance_array_set(values, slots, i, hue, {(x/f32(columns) + y/f32(rows)) * 0.5, 0, 0, 0}) // hue 沿对角线渐变
		_ = mat.instance_array_set(values, slots, i, opacity, {1, 0, 0, 0})
		// 相位沿网格斜向推进，整片形成波纹；半径 64..256 精灵局部像素（最多一个精灵宽），速度略有差异。
		phase := (x*0.04 + y*0.06) + 0.5*swarm_hash(u32(i))
		speed := 1.2 + 0.6*swarm_hash(u32(i)*7 + 3)
		radius := 64 + 192*swarm_hash(u32(i)*13 + 5)
		_ = mat.instance_array_set(values, slots, i, motion, {phase, speed, radius, 0})
	}
	if !r2d.sprite_buffer_upload(&s.swarm.buffer, items, 0, values) do return "Cannot upload sprites"
	s.swarm.count = count
	s.swarm.ready = true
	return ""
}

// 整数哈希到 0..1，让运动参数确定且可重复。
swarm_hash :: proc(value: u32) -> f32 {
	x := value
	x ~= x >> 16
	x *= 0x7feb352d
	x ~= x >> 15
	x *= 0x846ca68b
	x ~= x >> 16
	return f32(x & 0xffffff) / f32(0x1000000)
}

swarm_dispose :: proc(s: ^State) {
	if !s.swarm.ready do return
	r2d.sprite_buffer_dispose(&s.swarm.buffer)
	s.swarm = {}
}
