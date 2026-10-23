package main

import "core:mem"
import "core:math"
import "core:math/linalg"
import dasset "olib:core/dasset"
import foster "olib:foster"
import r3d "olib:kit/rendering/3d"
import mat "olib:kit/rendering/material"
import world "olib:kit/world"

POND_CENTER :: [2]f32{-4.7, 4.0}
POND_RADIUS :: [2]f32{3.1, 2.8}
WATER_HEIGHT :: f32(-0.38)
POND_BOTTOM :: f32(-0.95)
GROUND_BOUNDS :: dasset.Dasset_Bounds{min = {-120,-1, -120}, max = {120,0,120}}

// Broad, rounded corners echo a tile-built pond while keeping the banks walkable.
pond_distance :: proc(d: [2]f32) -> f32 {
	squared := d*d
	return math.sqrt(math.sqrt(squared.x*squared.x+squared.y*squared.y))
}

// Shared height field for visible terrain, player support and camera collision.
terrain_height :: proc(x, z: f32) -> f32 {
	d := ([2]f32{x,z} - POND_CENTER) / POND_RADIUS
	r := pond_distance(d)
	if r >= 1.14 do return 0
	if r <= 0.56 do return POND_BOTTOM
	angle := math.atan2(d.y,d.x)
	edge := r + 0.022*math.sin(angle*5+0.7) + 0.014*math.sin(angle*9-0.3)
	u := math.clamp((edge-0.60)/0.50,0,1)
	return POND_BOTTOM * (1-u*u*(3-2*u))
}

// Concentrate tessellation around the pond; the four outer strips remain flat.
// Shared boundary vertices leave no overlapping ground lid or cracks.
pond_terrain :: proc() -> dasset.Dasset_Primitive {
	CELLS :: 80
	N :: CELLS + 3
	p := dasset.Dasset_Primitive{vertices = make([]dasset.Dasset_Vertex,N*N), indices = make([]u32,(N-1)*(N-1)*6)}
	xs,zs: [N]f32
	xs[0],zs[0],xs[N-1],zs[N-1] = -120,-120,120,120
	for i in 0..=CELLS {
		q := f32(i)/CELLS*2-1
		xs[i+1] = POND_CENTER.x+q*POND_RADIUS.x*1.3
		zs[i+1] = POND_CENTER.y+q*POND_RADIUS.y*1.3
	}
	for z in 0..<N do for x in 0..<N {
		px,pz := xs[x],zs[z]
		normal := linalg.normalize([3]f32{terrain_height(px-0.01,pz)-terrain_height(px+0.01,pz),0.02,
			terrain_height(px,pz-0.01)-terrain_height(px,pz+0.01)})
		p.vertices[z*N+x] = {position = {px,terrain_height(px,pz),pz},normal = normal,uv = {px,pz},tangent = {1,0,0,1}}
		if x<N-1 && z<N-1 {
			a := u32(z*N+x)
			copy(p.indices[(z*(N-1)+x)*6:],[]u32{a,a+N+1,a+1,a,a+N,a+N+1})
		}
	}
	return p
}

// The bank geometry hides the outer part of this submerged plane.
pond_plane :: proc() -> dasset.Dasset_Primitive {
	p := quad()
	for &v in p.vertices {
		v.position = {v.position.x * 2, 0, v.position.y * 2}
		v.normal = {0, 1, 0}
	}
	return p
}

pond_contains :: proc(x, z: f32, margin: f32 = 0) -> bool {
	d := ([2]f32{x,z} - POND_CENTER) / (POND_RADIUS + [2]f32{margin,margin})
	return pond_distance(d) < 1
}

pond_camera :: proc(source: world.Camera3D) -> world.Camera3D {
	cam := source
	cam.position.y = 2 * WATER_HEIGHT - cam.position.y
	cam.target.y = 2 * WATER_HEIGHT - cam.target.y
	// Keep a right-handed camera and ordinary back-face culling. Projective UVs
	// use this same view, so no screen-space flip or mirrored mesh is needed.
	cam.up = {0,1,0}
	cam.dirty = true
	return cam
}

render_reflection :: proc(app: ^foster.App, t: f32) -> bool {
	s := foster.AppGetUserDataAs(app, State)
	target := foster.DrawableTargetFromTarget(&s.reflection)
	colors := [1]foster.Color{{160,192,190,255}}
	foster.GraphicsDeviceClear(&app.GraphicsDevice, target, colors[:], 1, 0, foster.ClearMask.Color | foster.ClearMask.Depth)
	globals := scene_view(s, &s.reflection_camera, 1)
	globals.water_view.y = 1 // clip geometry below the water plane
	view := r3d.View{target = target, view_projection = s.reflection_projection,
		view_matrix = world.camera3d_view(&s.reflection_camera), time = t, globals = mem.ptr_to_bytes(&globals)}
	// Reuse resident scenery instances, current player pose and floating coins.
	// Water and silhouette are excluded; Blob discards itself in reflection views.
	for pass in ([?]mat.Pass_Id{"sky", "scene", "body", "transparent"}) {
		if !submit(app, view, pass) do return false
	}
	return true
}
