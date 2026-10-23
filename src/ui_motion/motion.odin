package main

import tween "olib:core/tween"
import ui "olib:kit/ui"

// 分区：手感参数 / 时间轴补间 / 卡牌动作编排
//
// 四层用法在本示例中各有一处：
//   原语        —— 槽位悬停放大 ui_motion、卡牌回弹 ui_motion_kick、奖励弹窗 ui_presence
//   自算 Visual —— 卡牌拖动跟手、倾斜与抬起（cards.odin 的 card_step / card_visual）
//   时间轴      —— 出招、跳跃、落位（本文件的 Sequence）
//   非变换数值  —— 槽位描边颜色、托盘卡座宽度（view.odin 的 approach）

// ==============================================================================
// 手感参数 —— 全部集中在这里，改完重跑或热重载即可比较
// ==============================================================================

MOTION_SLOT :: ui.UI_Motion{time = 0.22, bounce = 0.35}
MOTION_POP :: ui.UI_Motion{time = 0.3, bounce = 0.4}
MODAL_ENTER :: ui.UI_Motion{time = 0.4, bounce = 0.25}
MODAL_EXIT :: ui.UI_Motion{time = 0.15}

SLOT_HOVER :: ui.UI_Visual{scale = {1.06, 1.06}, pivot = {0.5, 0.5}, opacity = 1}
// 回弹冲击：放大并轻微左倾，弹簧带着一点过冲回到原样。
POP_KICK :: ui.UI_Visual{scale = {6, 6}, rotation = -2.4}
// 弹窗入场从下方小一圈、略倾斜处浮起；退场只轻轻下沉淡出，不沿原路倒放。
MODAL_HIDDEN_IN :: ui.UI_Visual{offset = {0, 32}, scale = {0.86, 0.86}, rotation = -0.035, pivot = {0.5, 0.5}}
MODAL_HIDDEN_OUT :: ui.UI_Visual{offset = {0, 16}, scale = {0.96, 0.96}, pivot = {0.5, 0.5}}

// ==============================================================================
// 时间轴补间
// ==============================================================================

Motion :: struct {
	visual: ui.UI_Visual,
	handle: tween.Tween_Handle,
	target: ui.UI_Visual,
}

// 状态位于地址稳定的 Demo 内；重播先取消旧句柄，从当前值接续。
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

// ==============================================================================
// 卡牌动作编排
// ==============================================================================

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
