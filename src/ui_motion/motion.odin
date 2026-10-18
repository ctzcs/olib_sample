package main

import tween "olib:core/tween"
import ui "olib:kit/ui"

// 分区：动画状态 / 可打断补间 / 点击和弹窗编排

Motion :: struct {
	visual: ui.UI_Visual,
	handle: tween.Tween_Handle,
	target: ui.UI_Visual,
	action: bool, // 点击动作播完后再对齐最新悬停/焦点；普通过渡可随时改目标。
}

// 状态位于地址稳定的 Demo 内；重播先取消旧句柄，从当前值接续。
move_to :: proc(s: ^Demo, motion: ^Motion, target: ui.UI_Visual, duration: f32) {
	tween.manager_kill(&s.tweens, motion.handle)
	motion.target = target
	motion.action = false
	motion.handle = tween.manager_add_tween_to(&s.tweens,
		tween.make_ex(motion.visual, target, 0,
			{duration = duration, transition = .EaseOut}, ui.ui_visual_lerp), &motion.visual)
}

sequence_start :: proc(s: ^Demo, motion: ^Motion) -> tween.Tween_Handle {
	tween.manager_kill(&s.tweens, motion.handle)
	motion.action = true
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

jump :: proc(s: ^Demo) {
	m := &s.tiles[1]
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
	s.rewards += 1
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

tile_feedback :: proc(s: ^Demo, index: int, state: ui.UI_Interaction) {
	m := &s.tiles[index]
	running := tween.manager_is_handle_valid(s.tweens, m.handle)
	if !running {
		m.action = false
	}
	if state.clicked {
		switch index {
		case 0:
			rebound(s, m)
			s.attacks += 1
		case 1:
			jump(s)
		case 2:
			rebound(s, m)
			open_modal(s)
		}
		return
	}
	// 新按压可打断点击动作；普通悬停变化等动作完成后再对齐。
	if m.action && !state.pressed && !state.disabled {
		return
	}
	target := ui.UI_VISUAL_DEFAULT
	duration: f32 = 0.10
	if !state.disabled {
		if state.active {
			target.scale = {1.04, 0.93}
			target.offset = {0, 3}
			duration = 0.045
		} else if state.hovered || state.focused {
			target.offset = {0, -5}
			target.scale = {1.025, 1.025}
			target.rotation = index == 1 ? -0.025 : 0.018
		}
	}
	// 比较正在追踪的目标，而不是仅处理 hovered 的单帧边沿。
	// 动作完成后也重新核对实际姿态，持续悬停不需要再移入一次。
	if (running && (m.action || m.target != target)) || (!running && m.visual != target) {
		move_to(s, m, target, duration)
	}
}
