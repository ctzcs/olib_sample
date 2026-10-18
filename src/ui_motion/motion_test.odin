#+test
package main

import "core:testing"

import tween "olib:core/tween"
import ui "olib:kit/ui"

// 快速移入移出必须保留最新目标，不能因旧补间未完成而丢失离开事件。
@(test)
hover_leave_during_transition_returns_to_rest :: proc(t: ^testing.T) {
	s: Demo
	s.tweens = tween.manager_make()
	defer tween.manager_delete(&s.tweens)
	s.tiles[0].visual = ui.UI_VISUAL_DEFAULT
	tile_feedback(&s, 0, {hovered = true})
	tween.manager_update(&s.tweens, 0.025)
	tile_feedback(&s, 0, {})
	for _ in 0..<30 {
		tween.manager_update(&s.tweens, 1.0 / 60)
		tile_feedback(&s, 0, {})
	}
	testing.expect(t, s.tiles[0].visual == ui.UI_VISUAL_DEFAULT, "leaving during hover must restore pose")
	testing.expect(t, !tween.manager_is_handle_valid(s.tweens, s.tiles[0].handle))
}

@(test)
click_finishes_in_current_focus_pose :: proc(t: ^testing.T) {
	s: Demo
	s.tweens = tween.manager_make()
	defer tween.manager_delete(&s.tweens)
	s.tiles[0].visual = ui.UI_VISUAL_DEFAULT
	tile_feedback(&s, 0, {pressed = true, active = true, focused = true})
	tween.manager_update(&s.tweens, 0.025)
	tile_feedback(&s, 0, {released = true, clicked = true, focused = true})
	for _ in 0..<60 {
		tween.manager_update(&s.tweens, 1.0 / 60)
		tile_feedback(&s, 0, {focused = true})
	}
	testing.expect(t, s.attacks == 1)
	testing.expect(t, s.tiles[0].visual.offset.y == -5 && s.tiles[0].visual.scale.x == 1.025,
		"action completion must reconcile the current focus target")
	// 禁用可以在恢复焦点动画期间发生，最后必须回到原位。
	tile_feedback(&s, 0, {disabled = true})
	for _ in 0..<30 {
		tween.manager_update(&s.tweens, 1.0 / 60)
		tile_feedback(&s, 0, {disabled = true})
	}
	testing.expect(t, s.tiles[0].visual == ui.UI_VISUAL_DEFAULT)
}

@(test)
press_drag_out_and_release_cancels_without_sticking :: proc(t: ^testing.T) {
	s: Demo
	s.tweens = tween.manager_make()
	defer tween.manager_delete(&s.tweens)
	s.tiles[1].visual = ui.UI_VISUAL_DEFAULT
	tile_feedback(&s, 1, {pressed = true, active = true, hovered = true})
	tween.manager_update(&s.tweens, 0.01)
	tile_feedback(&s, 1, {active = true})
	tween.manager_update(&s.tweens, 0.01)
	tile_feedback(&s, 1, {released = true})
	for _ in 0..<30 {
		tween.manager_update(&s.tweens, 1.0 / 60)
		tile_feedback(&s, 1, {})
	}
	testing.expect(t, s.rewards == 0 && s.tiles[1].visual == ui.UI_VISUAL_DEFAULT)
}
