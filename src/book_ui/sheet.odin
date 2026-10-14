package main

// 一张纸的几何：坐标系、弯折、页面 UV 与网格 UV 的换算。
// 这里全是纯函数，不读写 World。

// 分区：
//   常量与类型 —— 页面尺寸 / 网格分辨率 / Sheet
//   构造 —— make_sheet
//   UV 换算 —— flip_for_back / sheet_local_point / sheet_point

import "core:math"
import foster "olib:foster"

// ==============================================================================
// 常量与类型
// ==============================================================================

// 页面纹理的像素尺寸。3D 书也用同样的单位：一个页面像素 = 书空间的一个单位。
PAGE_W :: 360
PAGE_H :: 500
// 纸的网格分辨率。纸只沿 x 方向弯，所以列多行少。
COLS :: 48
ROWS :: 12
PI :: f32(math.PI)

// 绕书脊转动的一张纸，在书空间中：
//   - 书脊是 y 轴（x = 0），y 向上，页面以 y = 0 为中心
//   - z 从摊开的书面指向读者，摊平的页面位于 z = 0
// points[row][col] 的网格 UV 是 (col / COLS, row / ROWS)。第 0 行是上边缘，
// 所以网格 UV 和页面像素同向（y 向下）。GPU 网格与射线拾取用的是同一批点。
Sheet :: struct {
	points:  [ROWS + 1][COLS + 1]foster.Vec3,
	normals: [COLS + 1]foster.Vec3, // 只绕 y 弯，每列一个法线即可
}

// ==============================================================================
// 构造
// ==============================================================================

// 生成绕书脊转过 `angle` 弧度的一张纸：
//   angle = 0  ：平放在右侧，正面朝上（右页）
//   angle = PI ：平放在左侧，背面朝上（左页）
// `curl` 把纸弯成圆弧：在 u 处（0 = 书脊，1 = 外边缘）纸的走向是
// `angle - curl * u`。顶点沿纸面一列一列走出来，所以无论怎么弯，纸长都是
// PAGE_W，不会被拉伸。`base_z` 把整张纸抬离书页堆。
make_sheet :: proc(angle, curl: f32, base_z: f32 = 0) -> Sheet {
	sheet: Sheet
	x, z: f32
	step := f32(PAGE_W) / COLS
	for col in 0..=COLS {
		u := f32(col) / COLS
		if col > 0 {
			// 用这一步中点处的走向前进一列（中点法）。
			mid := angle - curl * (u - 0.5 / COLS)
			x += math.cos(mid) * step
			z += math.sin(mid) * step
		}
		tangent := angle - curl * u
		sheet.normals[col] = {-math.sin(tangent), 0, math.cos(tangent)}
		for row in 0..=ROWS {
			sheet.points[row][col] = {x, (0.5 - f32(row) / ROWS) * PAGE_H, z + base_z}
		}
	}
	return sheet
}

// ==============================================================================
// UV 换算
// ==============================================================================

// 背面的页面是沿 x 镜像显示的（Book.hlsl 用 1 - u 采样背面）：从背后看，
// 网格的 u 轴是从右往左的。页面 UV 与网格 UV 互换都是这同一次翻转。
flip_for_back :: proc(uv: foster.Vec2, back: bool) -> foster.Vec2 {
	return back ? {1 - uv.x, uv.y} : uv
}

// 页面 UV -> 纸上的书空间坐标，即拾取的逆运算。每格用与 GPU 网格相同的两个
// 三角形插值（见 upload_sheet）。
sheet_local_point :: proc(sheet: ^Sheet, page_uv: foster.Vec2, back: bool) -> foster.Vec3 {
	uv := flip_for_back(page_uv, back)
	x, y := math.clamp(uv.x, 0, 1) * COLS, math.clamp(uv.y, 0, 1) * ROWS
	col, row := min(int(x), COLS - 1), min(int(y), ROWS - 1)
	s, t := x - f32(col), y - f32(row)
	a, b := sheet.points[row][col], sheet.points[row][col + 1]
	c, d := sheet.points[row + 1][col + 1], sheet.points[row + 1][col]
	if s >= t do return a * (1 - s) + b * (s - t) + c * t
	return a * (1 - t) + c * s + d * (t - s)
}

// 页面 UV -> 屏幕像素。测试脚本用它瞄准页面上的控件。
sheet_point :: proc(view: Book_View, sheet: ^Sheet, page_uv: foster.Vec2, back: bool) -> foster.Vec2 {
	return project(view, sheet_local_point(sheet, page_uv, back))
}
