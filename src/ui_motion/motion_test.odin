#+test
package main

import "core:testing"

import tween "olib:core/tween"
import ui "olib:kit/ui"

test_demo :: proc(s: ^Demo) {
	s.tweens = tween.manager_make()
	cards_init(s)
	s.card_size = {100, 140}
	for i in 0..<CARD_COUNT {
		s.hand_rects[i] = {f32(i) * 120, 400, 110, 150}
	}
	for i in 0..<SLOT_COUNT {
		s.slot_rects[i] = {f32(i) * 130, 100, 120, 160}
	}
}

settle :: proc(s: ^Demo, frames: int) {
	for _ in 0..<frames {
		tween.manager_update(&s.tweens, 1.0 / 60)
		for i in 0..<CARD_COUNT {
			card_step(s, i, {}, false, 1.0 / 60)
		}
	}
}

// 放到已占用的槽：两张卡互换，手牌位置不丢失。
@(test)
drop_on_occupied_slot_swaps :: proc(t: ^testing.T) {
	s: Demo
	test_demo(&s)
	defer tween.manager_delete(&s.tweens)
	place(&s, 0, 0)
	place(&s, 1, 1)
	place(&s, 2, 0)
	testing.expect(t, s.slots == {2, 1, -1})
	testing.expect(t, !s.cards[0].queued, "displaced hand card returns home")
	// 槽内卡牌拖到另一个已占用槽：两者交换槽位。
	place(&s, 1, 0)
	testing.expect(t, s.slots == {1, 2, -1} && s.cards[2].slot == 1)
}

@(test)
click_fills_first_empty_slot_then_returns :: proc(t: ^testing.T) {
	s: Demo
	test_demo(&s)
	defer tween.manager_delete(&s.tweens)
	place(&s, 3, 0)
	toggle(&s, 1)
	testing.expect(t, s.slots == {3, 1, -1})
	toggle(&s, 3)
	testing.expect(t, s.slots == {-1, 1, -1} && !s.cards[3].queued)
}

// 松开后卡牌弹簧归位、落地挤压播完，最终严格停在槽中心。
@(test)
released_card_settles_in_slot :: proc(t: ^testing.T) {
	s: Demo
	test_demo(&s)
	defer tween.manager_delete(&s.tweens)
	settle(&s, 1)
	s.drag = {card = 0, grab = {50, 70}, start = {50, 470}, moved = true, hover_slot = -1}
	card_step(&s, 0, {300, 250}, false, 1.0 / 60)
	card_step(&s, 0, {320, 200}, false, 1.0 / 60)
	testing.expect(t, s.drag.hover_slot == 2, "card center over slot 3")
	drop(&s, 0)
	settle(&s, 90)
	card := s.cards[0]
	testing.expect(t, s.slots[2] == 0 && !card.flying)
	testing.expect(t, card.pos == rect_center(s.slot_rects[2]) - s.card_size * 0.5)
	testing.expect(t, card.motion.visual == ui.UI_VISUAL_DEFAULT && abs(card.tilt) < 0.01)
}

@(test)
execute_plays_slots_in_order_then_returns :: proc(t: ^testing.T) {
	s: Demo
	test_demo(&s)
	defer tween.manager_delete(&s.tweens)
	place(&s, 1, 2)
	place(&s, 0, 0)
	execute(&s)
	play_step(&s, 1.0 / 60)
	testing.expect(t, s.attacks == 1 && s.rewards == 0, "slot 1 plays first")
	for _ in 0..<60 {
		play_step(&s, 1.0 / 60)
	}
	testing.expect(t, s.rewards == 1 && !s.playing && s.slots == {-1, -1, -1})
}

// 托盘重排：插入位置是移除前的下标，前移和后移都要保持其余顺序。
@(test)
insert_hand_reorders_and_takes_gap_width :: proc(t: ^testing.T) {
	s: Demo
	test_demo(&s)
	defer tween.manager_delete(&s.tweens)
	s.gap_open[4] = 0.7
	insert_hand(&s, 0, 4)
	testing.expect(t, s.hand == {1, 2, 3, 0})
	testing.expect(t, s.hand_open[0] == 0.7 && s.gap_open == {}, "socket inherits the open gap width")
	insert_hand(&s, 3, 0)
	testing.expect(t, s.hand == {3, 1, 2, 0})
	insert_hand(&s, 1, 2)
	testing.expect(t, s.hand == {3, 1, 2, 0}, "inserting next to itself keeps order")
	// 从行动槽拖回托盘指定位置。
	place(&s, 2, 0)
	insert_hand(&s, 2, 0)
	testing.expect(t, s.hand == {2, 3, 1, 0} && !s.cards[2].queued && s.slots[0] == -1)
}
