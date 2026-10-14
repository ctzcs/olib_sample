package main

// 翻页：页码规则、翻页状态机，以及空中那张纸的形状。

// 分区：
//   页码 —— SPREAD_COUNT / PAGE_COUNT / left_page / right_page
//   翻页状态 —— Turn / begin_turn / advance_turn
//   翻动中的纸 —— stack_pages / turning_leaf_pages / turning_sheet_shape

import "core:math"

// ==============================================================================
// 页码
// ==============================================================================

// 一共六页。第 s 个跨页摊开的是第 2s 页（左）和第 2s + 1 页（右）。
// 一张纸正面是奇数页、背面是下一页，所以能翻动的纸是 1|2 和 3|4。
// 翻到下一跨页时，右边的第 2s + 1 页抬起，它的背面第 2s + 2 页落到左边。
SPREAD_COUNT :: 3
PAGE_COUNT :: SPREAD_COUNT * 2

left_page :: proc(spread: int) -> int {
	return spread * 2
}

right_page :: proc(spread: int) -> int {
	return spread * 2 + 1
}

// ==============================================================================
// 翻页状态
// ==============================================================================

Turn :: struct {
	direction: int,  // +1 翻到下一跨页，-1 翻回上一跨页，0 表示没有纸在动
	progress:  f32,  // 在 `seconds` 内从 0 走到 1
	seconds:   f32,  // 绑定到屏幕上的 Turn duration 滑条
	paused:    bool,
}

begin_turn :: proc(world: ^World, direction: int) {
	if world.turn.direction != 0 || direction == 0 do return
	if world.spread + direction < 0 || world.spread + direction >= SPREAD_COUNT do return
	world.turn.direction = direction
	world.turn.progress = 0
	// Cancel captures before the visible pages change, including held sliders.
	for &page in world.pages {
		page.ctx.active_id = 0
		page.ctx.focused_id = 0
	}
	if direction > 0 {
		world.status = "Turning to the next chapter..."
	} else {
		world.status = "Returning to the previous chapter..."
	}
}

advance_turn :: proc(world: ^World, dt: f32) {
	turn := &world.turn
	if turn.direction == 0 || turn.paused do return
	turn.progress = min(turn.progress + dt / turn.seconds, 1)
	if turn.progress >= 1 {
		world.spread += turn.direction
		turn.direction = 0
		turn.progress = 0
		world.focus_page = right_page(world.spread)
		world.status = "The page has settled. Its controls are ready."
	}
}

// ==============================================================================
// 翻动中的纸
// ==============================================================================

// 空中那张纸的最大弯曲（翻到一半时，书脊到外边缘的角度差，弧度）。
MAX_CURL :: 0.85
// 空中那张纸比两侧书页高出这么多，避免 z-fighting。
TURNING_LEAF_LIFT :: 0.35

// 两侧平放的纸上显示哪一页。一张纸从某侧抬起后，那一侧已经露出下面的页。
stack_pages :: proc(world: ^World) -> (left, right: int) {
	left, right = left_page(world.spread), right_page(world.spread)
	if world.turn.direction > 0 do right = right_page(world.spread + 1)
	if world.turn.direction < 0 do left = left_page(world.spread - 1)
	return
}

// 空中那张纸的正面和背面各是哪一页。
turning_leaf_pages :: proc(world: ^World) -> (front, back: int) {
	if world.turn.direction > 0 {
		front = right_page(world.spread)
	} else {
		front = left_page(world.spread) - 1
	}
	return front, front + 1
}

// 当前进度下，空中那张纸的形状。
turning_sheet_shape :: proc(turn: Turn) -> Sheet {
	t := turn.progress * turn.progress * (3 - 2 * turn.progress) // smoothstep：缓入缓出
	// 从右侧平放（0）扫到左侧平放（PI），翻回时反过来。
	angle := turn.direction > 0 ? PI * t : PI * (1 - t)
	// 外边缘落后于书脊，翻到一半时落后最多。
	curl := math.sin(PI * t) * MAX_CURL * f32(turn.direction)
	return make_sheet(angle, curl, TURNING_LEAF_LIFT)
}
