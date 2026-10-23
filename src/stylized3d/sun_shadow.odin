package main

import "core:math"
import "core:math/linalg"
import foster "olib:foster"
import mat "olib:kit/rendering/material"
import world "olib:kit/world"

SHADOW_SIZE :: 2048
SHADOW_SPAN :: f32(48)
SUN_DIRECTION :: [3]f32{-0.6,-1,0.4}

sun_shadow_init :: proc(s: ^State, device: ^foster.GraphicsDevice) -> bool {
	attachments := [?]foster.TargetAttachmentSpec{{Format = .Color},{Format = .Depth32}}
	foster.TargetInit(&s.sun_target,device,SHADOW_SIZE,SHADOW_SIZE,attachments[:],"stylized sun depth")
	for material in ([?]^mat.Material{s.ground,s.toon,s.grass_material,s.flower_material}) {
		if !mat.material_set_texture(material,"Toon_scene","sunDepth",foster.TargetAttachment(&s.sun_target,1)) do return false
	}
	return mat.material_set_texture(s.hero,"Hero_body","sunDepth",foster.TargetAttachment(&s.sun_target,1))
}

sun_shadow_matrix :: proc(center: [3]f32) -> (view, projection: world.Matrix4) {
	light := linalg.normalize(SUN_DIRECTION)
	right := linalg.normalize(linalg.cross(light,[3]f32{0,1,0}))
	up := linalg.cross(right,light)
	focus := center
	focus.y = 0
	texel := SHADOW_SPAN / SHADOW_SIZE
	// Snap light-space XY to shadow texels, keeping a moving camera from making
	// static shadow edges crawl across the pixel-art ground.
	x,y := linalg.dot(focus,right),linalg.dot(focus,up)
	focus += right*(math.round(x/texel)*texel-x) + up*(math.round(y/texel)*texel-y)
	view = world.matrix4_look_at(focus-light*40,focus,{0,1,0})
	// Right-handed orthographic depth [0,1], near 1, far 85.
	ortho := world.Matrix4{{2/SHADOW_SPAN,0,0,0},{0,2/SHADOW_SPAN,0,0},{0,0,-1.0/84,-1.0/84},{0,0,0,1}}
	return view,world.matrix4_multiply(view,ortho)
}
