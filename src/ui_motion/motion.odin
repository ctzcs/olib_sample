package main

import tween "olib:core/tween"
import ui "olib:kit/ui"

// 分区：动画状态 / 可打断补间 / 卡牌动作和弹窗编排

Motion :: struct {
	visual: ui.UI_Visual,
	handle: tween.Tween_Handle,
	target: ui.UI_Visual,
}

// 状态位于地址稳定的 Demo 内；重播先取消旧句柄，从当前值接续。
move_to :: proc(s: ^Demo, motion: ^Motion, target: ui.UI_Visual, duration: f32) {
	tween.manager_kill(&s.tweens, motion.handle)
	motion.target = target
	motion.handle = tween.manager_add_tween_to(&s.tweens,
		tween.make_ex(motion.visual, target, 0,
			{duration = duration, transition = .EaseOut}, ui.ui_visual_lerp), &motion.visual)
}

sequence_start :: proc(s: ^Demo, motion: ^Motion) -> tween.Tween_Handle {
	tween.manager_kill(&s.tweens, motion.handle)
	motion.handle = tween.manager_add_sequence(&s.tweens)
	return motion.handle
}

sequence_step :: proc(s: ^Demo, motion: ^Motion, from, to: ui.UI_Visual, duration: f32) {
	_, ok := tween.sequence_append_tween_to(&s.tweens, motion.handle,
		tween.make_ex(from, to, 0, {duration = duration, transition = .EaseOut}, ui.ui_visual_lerp),
		&motion.visual)
	assert(ok)
}

// 数值集中在这里：轻微倾斜、短促过冲，一次动作在半秒内收稳。
rebound :: proc(s: ^Demo, motion: ^Motion) {
	sequence_start(s, motion)
	peak := ui.UI_VISUAL_DEFAULT
	peak.scale = {1.10, 1.10}
	peak.rotation = -0.045
	settle := ui.UI_VISUAL_DEFAULT
	settle.scale = {0.985, 0.985}
	sequence_step(s, motion, motion.visual, peak, 0.085)
	sequence_step(s, motion, peak, settle, 0.10)
	sequence_step(s, motion, settle, ui.UI_VISUAL_DEFAULT, 0.085)
}

jump :: proc(s: ^Demo, m: ^Motion) {
	sequence_start(s, m)
	windup := ui.UI_VISUAL_DEFAULT
	windup.scale = {1.10, 0.88}
	windup.pivot = {0.5, 1}
	peak := ui.UI_VISUAL_DEFAULT
	peak.offset = {0, -48}
	peak.scale = {0.95, 1.06}
	peak.rotation = -0.14
	land := ui.UI_VISUAL_DEFAULT
	land.scale = {1.12, 0.87}
	land.rotation = 0.035
	land.pivot = {0.5, 1}
	sequence_step(s, m, m.visual, windup, 0.055)
	sequence_step(s, m, windup, peak, 0.15)
	sequence_step(s, m, peak, land, 0.16)
	sequence_step(s, m, land, ui.UI_VISUAL_DEFAULT, 0.13)
}

// 出招：后撤蓄力，向上前冲，再落回原位。
strike :: proc(s: ^Demo, m: ^Motion) {
	sequence_start(s, m)
	windup := ui.UI_VISUAL_DEFAULT
	windup.offset = {0, 8}
	windup.scale = {1.06, 0.92}
	windup.rotation = 0.05
	lunge := ui.UI_VISUAL_DEFAULT
	lunge.offset = {10, -40}
	lunge.scale = {1.12, 1.12}
	lunge.rotation = -0.09
	sequence_step(s, m, m.visual, windup, 0.07)
	sequence_step(s, m, windup, lunge, 0.07)
	sequence_step(s, m, lunge, ui.UI_VISUAL_DEFAULT, 0.20)
}

// 落位：以底边为支点压扁再弹回，让卡牌“放进”槽里。
land :: proc(s: ^Demo, m: ^Motion) {
	sequence_start(s, m)
	squash := ui.UI_VISUAL_DEFAULT
	squash.scale = {1.08, 0.9}
	squash.pivot = {0.5, 1}
	stretch := ui.UI_VISUAL_DEFAULT
	stretch.scale = {0.98, 1.03}
	stretch.pivot = {0.5, 1}
	sequence_step(s, m, m.visual, squash, 0.05)
	sequence_step(s, m, squash, stretch, 0.08)
	sequence_step(s, m, stretch, ui.UI_VISUAL_DEFAULT, 0.08)
}

open_modal :: proc(s: ^Demo) {
	if s.modal_open && !s.modal_closing do return
	if !s.modal_open {
		s.modal.visual = ui.UI_VISUAL_DEFAULT
		s.modal.visual.scale = {0.86, 0.86}
		s.modal.visual.offset = {0, 32}
		s.modal.visual.rotation = -0.035
		s.modal.visual.opacity = 0
	}
	s.modal_open = true
	s.modal_closing = false
	sequence_start(s, &s.modal)
	peak := ui.UI_VISUAL_DEFAULT
	peak.scale = {1.025, 1.025}
	sequence_step(s, &s.modal, s.modal.visual, peak, 0.18)
	sequence_step(s, &s.modal, peak, ui.UI_VISUAL_DEFAULT, 0.10)
}

close_modal :: proc(s: ^Demo) {
	if !s.modal_open || s.modal_closing do return
	s.modal_closing = true
	target := ui.UI_VISUAL_DEFAULT
	target.offset = {0, 16}
	target.scale = {0.96, 0.96}
	target.opacity = 0
	move_to(s, &s.modal, target, 0.13)
}
