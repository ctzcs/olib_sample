package main

import "core:math"

import foster "olib:foster"
import r2d "olib:kit/rendering/2d"

// ==============================================================================
// Render2D 之上的圆角矩形：以中心为扇心的三角形扇（实心）与内外轮廓间的四边形（描边），
// 半透明时没有重叠，不会叠深。
// ==============================================================================

CORNER_STEPS :: 6

@(private = "file")
rounded_outline :: proc(rect: foster.Rect, radius: f32) -> [4 * (CORNER_STEPS + 1)]foster.Vec2 {
	r := min(radius, rect.Width * 0.5, rect.Height * 0.5)
	x0, y0, x1, y1 := rect.X, rect.Y, rect.X + rect.Width, rect.Y + rect.Height
	// 顺时针：右上、右下、左下、左上四个角的圆心与起始角。
	centers := [4]foster.Vec2{{x1 - r, y0 + r}, {x1 - r, y1 - r}, {x0 + r, y1 - r}, {x0 + r, y0 + r}}
	starts := [4]f32{-math.PI / 2, 0, math.PI / 2, math.PI}
	points: [4 * (CORNER_STEPS + 1)]foster.Vec2
	for c in 0 ..< 4 {
		for k in 0 ..= CORNER_STEPS {
			a := starts[c] + f32(k) / CORNER_STEPS * (math.PI / 2)
			points[c * (CORNER_STEPS + 1) + k] = centers[c] + {math.cos(a), math.sin(a)} * r
		}
	}
	return points
}

round_rect :: proc(r: ^r2d.Render2D, rect: foster.Rect, radius: f32, color: foster.Color) {
	if rect.Width <= 0 || rect.Height <= 0 do return
	points := rounded_outline(rect, radius)
	center := foster.Vec2{rect.X + rect.Width * 0.5, rect.Y + rect.Height * 0.5}
	for i in 0 ..< len(points) {
		r2d.triangle(r, center, points[i], points[(i + 1) % len(points)], color)
	}
}

round_rect_line :: proc(r: ^r2d.Render2D, rect: foster.Rect, radius, thickness: f32, color: foster.Color) {
	if rect.Width <= 0 || rect.Height <= 0 do return
	t := thickness * 0.5
	outer := rounded_outline({rect.X - t, rect.Y - t, rect.Width + t * 2, rect.Height + t * 2}, radius + t)
	inner := rounded_outline({rect.X + t, rect.Y + t, rect.Width - t * 2, rect.Height - t * 2}, max(radius - t, 0))
	for i in 0 ..< len(outer) {
		j := (i + 1) % len(outer)
		r2d.quad(r, inner[i], outer[i], outer[j], inner[j], color)
	}
}
