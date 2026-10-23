package main

import "core:math"
import "core:math/linalg"

import tween "olib:core/tween"
import foster "olib:foster"
import ui "olib:kit/ui"

// 分区：卡牌数据 / 拖放与归位 / 跟随物理 / 执行队列

CARD_COUNT :: 4
SLOT_COUNT :: 3

Card_Kind :: enum {
	Attack,
	Relic,
	Gate,
	Guard,
}

// 卡牌只记住自己的“家”：手牌卡座按 Demo.hand 的顺序排列，行动槽由 Demo.slots 反查。
Card :: struct {
	kind: Card_Kind,
	queued: bool,
	slot: int,
	pos, vel: foster.Vec2, // 逻辑坐标左上角；不拖动时用临界阻尼弹簧追家
	tilt, lift: f32,
	flying, placed: bool,
	motion: Motion, // 落地挤压、出招等补间姿态
}

Drag :: struct {
	card: int, // -1 表示没有拖动
	grab, start: foster.Vec2,
	moved: bool,
	hover_slot: int,
	insert: int, // 悬停在托盘上时的插入位置（Demo.hand 下标），-1 表示不在托盘上
}

DRAG_NONE :: Drag{card = -1, hover_slot = -1, insert = -1}

// ==============================================================================
// 拖放与归位
// ==============================================================================

cards_init :: proc(s: ^Demo) {
	for &card, i in s.cards {
		card.kind = Card_Kind(i)
		card.motion.visual = ui.UI_VISUAL_DEFAULT
	}
	for &slot in s.slots {
		slot = -1
	}
	for &open in s.hand_open {
		open = 1
	}
	for &entry, i in s.hand {
		entry = i
	}
	s.drag = DRAG_NONE
}

// 放到行动槽：目标槽已有卡牌时与被拖卡牌的原位置交换。
place :: proc(s: ^Demo, index, slot: int) {
	card := &s.cards[index]
	if card.queued && card.slot == slot {
		card.flying = true
		return
	}
	other := s.slots[slot]
	if card.queued {
		s.slots[card.slot] = other
		if other >= 0 {
			s.cards[other].slot = card.slot
			s.cards[other].flying = true
		}
	} else if other >= 0 {
		s.cards[other].queued = false
		s.cards[other].flying = true
	}
	s.slots[slot] = index
	card.queued = true
	card.slot = slot
	card.flying = true
}

return_home :: proc(s: ^Demo, index: int) {
	card := &s.cards[index]
	if card.queued {
		s.slots[card.slot] = -1
	}
	card.queued = false
	card.flying = true
}

// 点击 / Enter：手牌进入第一个空槽，槽内卡牌回到手牌。
toggle :: proc(s: ^Demo, index: int) {
	if s.cards[index].queued {
		return_home(s, index)
		return
	}
	for occupant, slot in s.slots {
		if occupant < 0 {
			place(s, index, slot)
			return
		}
	}
	// 槽满时轻轻摇一下，表示没有位置。
	rebound(s, &s.cards[index].motion)
}

drop :: proc(s: ^Demo, index: int) {
	if !s.drag.moved {
		toggle(s, index)
	} else if s.drag.hover_slot >= 0 {
		place(s, index, s.drag.hover_slot)
	} else if s.drag.insert >= 0 {
		insert_hand(s, index, s.drag.insert)
	} else {
		return_home(s, index)
	}
	s.drag = DRAG_NONE
}

// 把卡牌插到手牌顺序的 at 位置（at 是移除前的下标，可为 CARD_COUNT 表示末尾）。
// 卡座接管该位置空隙已展开的宽度，托盘不跳变；其他空隙随即收起。
insert_hand :: proc(s: ^Demo, index, at: int) {
	from := 0
	for entry, i in s.hand {
		if entry == index do from = i
	}
	to := at > from ? at - 1 : at
	if to > from {
		copy(s.hand[from:to], s.hand[from + 1:to + 1])
	} else if to < from {
		copy(s.hand[to + 1:from + 1], s.hand[to:from])
	}
	s.hand[to] = index
	s.hand_open[index] = s.gap_open[at]
	s.gap_open = {}
	return_home(s, index)
}

// 卡牌中心在托盘范围内时，插入到第一张中心在它右侧的可见手牌之前。
insert_at :: proc(s: ^Demo, center: foster.Vec2) -> int {
	r := s.tray_rect
	margin := s.card_size.y * 0.35
	if center.x < r.X - margin || center.x > r.X + r.Width + margin ||
	   center.y < r.Y - margin || center.y > r.Y + r.Height + margin {
		return -1
	}
	for entry, i in s.hand {
		if !in_hand(s, entry) do continue
		if center.x < rect_center(s.hand_rects[entry]).x {
			return i
		}
	}
	return CARD_COUNT
}

in_hand :: proc(s: ^Demo, index: int) -> bool {
	return !s.cards[index].queued && !(s.drag.card == index && s.drag.moved)
}

// 卡牌中心落在槽内（含少量容差）即命中；多个命中时取最近。
slot_at :: proc(s: ^Demo, center: foster.Vec2) -> int {
	best, best_distance := -1, f32(math.F32_MAX)
	for rect, slot in s.slot_rects {
		margin := rect.Width * 0.25
		if center.x < rect.X - margin || center.x > rect.X + rect.Width + margin ||
		   center.y < rect.Y - margin || center.y > rect.Y + rect.Height + margin {
			continue
		}
		distance := linalg.length(center - rect_center(rect))
		if distance < best_distance {
			best, best_distance = slot, distance
		}
	}
	return best
}

home_rect :: proc(s: ^Demo, index: int) -> foster.Rect {
	card := s.cards[index]
	return card.queued ? s.slot_rects[card.slot] : s.hand_rects[index]
}

rect_center :: proc(r: foster.Rect) -> foster.Vec2 {
	return {r.X + r.Width * 0.5, r.Y + r.Height * 0.5}
}

// ==============================================================================
// 跟随物理 —— 拖动时一比一跟手，松开后弹簧归位并按水平速度倾斜
// ==============================================================================

card_step :: proc(s: ^Demo, index: int, pointer: foster.Vec2, hovered: bool, dt: f32) {
	card := &s.cards[index]
	home := home_rect(s, index)
	target := rect_center(home) - s.card_size * 0.5
	if !card.placed {
		card.pos = target
		card.placed = true
	}
	dragging := s.drag.card == index && s.drag.moved
	if dragging {
		next := pointer - s.drag.grab
		if dt > 0 {
			card.vel = (next - card.pos) / dt
		}
		card.pos = next
		s.drag.hover_slot = slot_at(s, card.pos + s.card_size * 0.5)
		s.drag.insert = s.drag.hover_slot < 0 ? insert_at(s, card.pos + s.card_size * 0.5) : -1
	} else if !card.flying {
		// 静止的卡牌贴住卡座：托盘伸缩时与卡座同步滑动，不带弹簧滞后。
		card.pos = target
		card.vel = {}
	} else {
		card.pos, card.vel = tween.smooth_damp(card.pos, card.vel, target, 0.075, dt)
		if card.flying && linalg.length(target - card.pos) < 1 && linalg.length(card.vel) < 60 {
			card.pos = target
			card.vel = {}
			card.flying = false
			land(s, &card.motion)
		}
	}
	lift: f32 = dragging ? 1 : (hovered ? 0.45 : 0)
	card.lift = tween.approach(card.lift, lift, 18, dt)
	card.tilt = tween.approach(card.tilt, math.clamp(card.vel.x * 0.00032, -0.32, 0.32), 16, dt)
}

// 补间姿态叠加拖动的抬起、倾斜；布局位置由 floating offset 决定。
card_visual :: proc(card: Card) -> ui.UI_Visual {
	v := card.motion.visual
	v.scale *= 1 + 0.07 * card.lift
	v.offset.y -= 7 * min(card.lift, 0.45) / 0.45
	v.rotation += card.tilt
	return v
}

// ==============================================================================
// 执行队列 —— 按槽位顺序出招，结束后全部回手
// ==============================================================================

PLAY_INTERVAL :: 0.42

execute :: proc(s: ^Demo) {
	if s.playing do return
	for occupant in s.slots {
		if occupant >= 0 {
			s.playing = true
			s.play_slot = 0
			s.play_timer = 0
			s.gate_opened = false
			return
		}
	}
}

play_step :: proc(s: ^Demo, dt: f32) {
	if !s.playing do return
	s.play_timer -= dt
	if s.play_timer > 0 do return
	for s.play_slot < SLOT_COUNT {
		slot := s.play_slot
		s.play_slot += 1
		if index := s.slots[slot]; index >= 0 {
			perform(s, index)
			s.play_timer = PLAY_INTERVAL
			return
		}
	}
	s.playing = false
	for i in 0..<CARD_COUNT {
		if s.cards[i].queued {
			return_home(s, i)
		}
	}
	if s.gate_opened {
		open_modal(s)
	}
}

perform :: proc(s: ^Demo, index: int) {
	card := &s.cards[index]
	switch card.kind {
	case .Attack:
		strike(s, &card.motion)
		s.attacks += 1
	case .Relic:
		jump(s, &card.motion)
		s.rewards += 1
	case .Gate:
		strike(s, &card.motion)
		s.gate_opened = true
	case .Guard:
		rebound(s, &card.motion)
		s.guards += 1
	}
}
