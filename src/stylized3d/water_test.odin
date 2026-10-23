#+test
package main

import "core:math"
import "core:testing"
import "core:math/linalg"
import world "olib:kit/world"

@(test)
pond_reflection_projection_tracks_orbit_and_aspect :: proc(t: ^testing.T) {
	for size in ([?][2]int{{640,360},{683,384},{360,640}}) {
		for eye in ([?][3]f32{{0,4,10},{-9,2,5},{-4,7,-3}}) {
			camera: world.Camera3D
			world.camera3d_init(&camera,size.x,size.y)
			world.camera3d_set_position(&camera,eye)
			world.camera3d_set_target(&camera,{-4.7,0.4,4})
			reflected := pond_camera(camera)
			testing.expect(t,math.abs(reflected.position.y+camera.position.y-2*WATER_HEIGHT)<0.0001)
			vp := world.camera3d_view_projection(&camera)
			rvp := world.camera3d_view_projection(&reflected)
			// A point on the plane must line up in both views (Y reverses because
			// both cameras retain right-handed winding); objects mirror around it.
			for p in ([?][3]f32{{-4.7,WATER_HEIGHT,4},{-4.6,0.6,2.6},{-5.6,3,-3.4}}) {
				mirror := p
				mirror.y = 2*WATER_HEIGHT-p.y
				a, ok_a := world.matrix4_transform_point(vp,mirror)
				b, ok_b := world.matrix4_transform_point(rvp,p)
				testing.expect(t,ok_a && ok_b)
				testing.expect(t,math.abs(a.x-b.x)<0.0001 && math.abs(a.y+b.y)<0.0001 && math.abs(a.z-b.z)<0.0001,
					"projective reflection must stay attached to the water when orbiting or resizing")
			}
		}
	}
}

@(test)
pond_terrain_mesh_matches_collision_height :: proc(t: ^testing.T) {
	testing.expect(t,terrain_height(POND_CENTER.x,POND_CENTER.y)==POND_BOTTOM)
	testing.expect(t,POND_BOTTOM<WATER_HEIGHT && WATER_HEIGHT<0)
	testing.expect(t,terrain_height(0,4)==0)
	mesh := pond_terrain()
	defer primitive_dispose(&mesh)
	for i in 0..<len(mesh.indices)/3 {
		a := mesh.vertices[mesh.indices[i*3]].position
		b := mesh.vertices[mesh.indices[i*3+1]].position
		c := mesh.vertices[mesh.indices[i*3+2]].position
		testing.expect(t,linalg.cross(b-a,c-a).y>0,"terrain faces must point upwards")
		mid := (a+b+c)/3
		testing.expect(t,math.abs(mid.y-terrain_height(mid.x,mid.z))<0.012,"rendered bank and collision floor must agree")
	}
}

@(test)
player_walks_into_and_out_of_sunken_pond :: proc(t: ^testing.T) {
	for sprint in ([?]bool{false,true}) {
		p := Player{position = {-0.6,0,4},grounded = true}
		lowest: f32 = 0
		for _ in 0..<270 {
			before := p.position.y
			player_step(&p,{move={-1,0},sprint=sprint},0,nil,PHYSICS_DT)
			lowest=min(lowest,p.position.y)
			testing.expect(t,p.grounded && math.abs(p.position.y-terrain_height(p.position.x,p.position.z))<0.001)
			testing.expect(t,math.abs(p.position.y-before)<0.1,"bank movement must not teleport or hover")
		}
		testing.expect(t,lowest<POND_BOTTOM+0.01 && math.abs(p.position.y)<0.001,"walk down to the floor and up the opposite bank")
	}
	p := Player{position={POND_CENTER.x,POND_BOTTOM,POND_CENTER.y},grounded=true}
	peak := p.position.y
	for i in 0..<180 {
		player_step(&p,{jump=i==0},0,nil,PHYSICS_DT)
		peak=max(peak,p.position.y)
	}
	testing.expect(t,peak>WATER_HEIGHT && p.grounded && math.abs(p.position.y-POND_BOTTOM)<0.001)
	testing.expect(t,math.abs(player_shadow_height(p,nil)-POND_BOTTOM)<0.001)
}

@(test)
camera_stops_before_sunken_bank :: proc(t: ^testing.T) {
	start := [3]f32{POND_CENTER.x,-0.25,POND_CENTER.y}
	finish := start+[3]f32{5,0,0}
	fraction := camera_fraction(start,finish,nil,0.15)
	testing.expect(t,fraction>0.2 && fraction<0.7)
	contact := start+(finish-start)*fraction
	testing.expect(t,contact.y>=terrain_height(contact.x,contact.z)+0.149)
}
