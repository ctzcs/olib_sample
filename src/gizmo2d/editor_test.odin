#+test
package main

import "core:math"
import "core:testing"

import "editor"

import foster "olib:foster"
import gizmo "olib:kit/gizmo"
import world "olib:kit/world"

@(test)
transactions :: proc(t: ^testing.T) {
	e: editor.Session
	editor.init(&e)
	defer editor.destroy(&e)
	original := e.values
	editor.begin(&e, 0)
	for i in 1..=10 {
		v := e.values
		v[0].position.x = f32(i)
		v[1].rotation += 0.1
		testing.expect(t, editor.apply(&e, v))
	}
	editor.commit(&e)
	testing.expect(t, len(e.history) == 1 && e.dirty)
	edited := e.values
	editor.undo(&e)
	testing.expect(t, e.values == original && !e.dirty)
	editor.begin(&e, 0)
	editor.apply(&e, edited)
	editor.cancel(&e)
	testing.expect(t, e.values == original && e.cursor == 0 && len(e.history) == 1)
	editor.redo(&e)
	testing.expect(t, e.values == edited)
	editor.begin(&e, 1)
	bad := e.values
	bad[0].position.x = 99
	bad[2].scale.y = math.nan_f32()
	testing.expect(t, !editor.apply(&e, bad) && e.values == edited, "atomic rejection")
	editor.commit(&e)
	testing.expect(t, len(e.history) == 1, "no-op has no history")
	editor.reset(&e)
	testing.expect(t, e.values == original && !e.dirty && len(e.history) == 2)
	editor.undo(&e)
	testing.expect(t, e.values == edited, "reset is one undoable multi-object edit")
}

@(test)
input_release_cancel_and_capture :: proc(t: ^testing.T) {
	e: editor.Session
	editor.init(&e)
	defer editor.destroy(&e)
	rects := [3]foster.Rect{{10, 20, 300, 300}, {330, 20, 300, 300}, {650, 20, 300, 300}}
	for &c in e.cameras do world.camera2d_set_viewport(&c, 300, 300)
	editor.input(&e, rects, {}, 1)
	g := gizmo.transform2d_geometry(&e.cameras[0], e.values[0], rects[0], .Translate)
	start := g.axes.origin
	end := start+foster.Vec2{20, 10}
	editor.input(&e, rects, {pointer = start, pressed = true, down = true, enabled = true, allow_start = true}, 1)
	testing.expect(t, e.active)
	editor.input(&e, rects, {pointer = end, enabled = true}, 1)
	testing.expect(t, !e.active && len(e.history) == 1 && e.values[0].position != foster.Vec2{},
		"release-frame movement applied before commit")
	before := e.values
	g = gizmo.transform2d_geometry(&e.cameras[0], e.values[0], rects[0], .Translate)
	editor.input(&e, rects, {pointer = g.axes.origin, pressed = true, down = true, enabled = true, allow_start = true}, 1)
	editor.input(&e, rects, {pointer = g.axes.origin+foster.Vec2{30, 0}, down = true, enabled = true}, 1)
	testing.expect(t, e.values != before)
	editor.input(&e, rects, {down = true, enabled = false}, 1)
	testing.expect(t, e.values == before && !e.active && e.handles[0].captured && len(e.history) == 1,
		"focus loss restores content and retains capture")
	other := gizmo.transform2d_geometry(&e.cameras[1], e.values[1], rects[1], .Rotate)
	editor.input(&e, rects, {pointer = other.axes.origin+foster.Vec2{other.radius, 0}, pressed = true,
		down = true, enabled = true, allow_start = true}, 1)
	testing.expect(t, !e.active && !e.handles[1].dragging, "held input cannot transfer viewports")
	editor.input(&e, rects, {}, 1)
	testing.expect(t, !e.handles[0].captured)
}
