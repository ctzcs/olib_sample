#+test
package main

import "core:math"
import "core:math/linalg"
import "core:testing"
import world "olib:kit/world"

@(test)
camera_relative_movement_and_diagonal_speed :: proc(t: ^testing.T) {
	a := movement_direction({0, 1}, 0)
	b := movement_direction({1, 1}, 0)
	c := movement_direction({0, 1}, math.PI / 2)
	testing.expect(t, linalg.length(a - [3]f32{0, 0, -1}) < 0.0001)
	testing.expect(t, math.abs(linalg.length(b) - 1) < 0.0001)
	testing.expect(t, linalg.length(c - [3]f32{-1, 0, 0}) < 0.0001)
}

@(test)
walking_blocks_and_slides_along_wall :: proc(t: ^testing.T) {
	boxes := [?]Collision_Box{collision_box({0, 1, 0}, {12, 2, 0.2})}
	p := Player{position = {0, 0, 2}, grounded = true}
	for _ in 0..<240 do player_step(&p, {move = {0.35, 1}, sprint = true}, 0, boxes[:], PHYSICS_DT)
	testing.expect(t, p.position.z >= 0.1 + PLAYER_RADIUS - 0.001, "must not tunnel through thin walls")
	testing.expect(t, p.position.x > 2, "must slide along a wall")
	testing.expect(t, player_clear(p.position, boxes[:]))
}

@(test)
rotated_collision_matches_visible_transform :: proc(t: ^testing.T) {
	box := collision_box({2, 0.5, -1}, {2, 1, 0.5}, 0.7)
	visible, ok := world.matrix4_transform_point(place(box.center, {2, 1, 0.5}, 0.7), {0.5, 0, 0})
	testing.expect(t, ok)
	local := box_local(box, visible - box.center)
	testing.expect(t, linalg.length(local - [3]f32{1, 0, 0}) < 0.0001)
	position := box.center + box.axis_z * 0.40
	normal, depth := box_contact(box, position, PLAYER_RADIUS)
	testing.expect(t, math.abs(depth - 0.23) < 0.001)
	testing.expect(t, linalg.dot(normal, box.axis_z) > 0.999)
	_, remaining := box_contact(box, position + normal * (depth + 0.001), PLAYER_RADIUS)
	testing.expect(t, remaining == 0)
}

@(test)
jump_lands_on_platform_and_cannot_double_jump :: proc(t: ^testing.T) {
	boxes := [?]Collision_Box{collision_box({0, 0.575, 0}, {4, 1.15, 0.6})}
	p := Player{position = {0, 0, 1.6}, grounded = true}
	peak: f32 = 0
	for i in 0..<180 {
		input := Player_Input{move = {0, i < 35 ? f32(1) : f32(0)}, jump = i == 0 || i == 45}
		before := p.velocity.y
		player_step(&p, input, 0, boxes[:], PHYSICS_DT)
		if i == 45 do testing.expect(t, p.velocity.y < before, "airborne jump must not add upward velocity")
		peak = max(peak, p.position.y)
	}
	testing.expect(t, peak > 1.6 && peak < 1.9)
	testing.expect(t, p.grounded && math.abs(p.position.y - 1.15) < 0.001, "land on wall top")
}

@(test)
ceiling_landing_step_and_ledge :: proc(t: ^testing.T) {
	ceiling := [?]Collision_Box{collision_box({0, 2.2, 0}, {4, 0.4, 4})}
	p := Player{grounded = true}
	for i in 0..<30 {
		player_step(&p, {jump = i == 0}, 0, ceiling[:], PHYSICS_DT)
		testing.expect(t, p.position.y + PLAYER_HEIGHT <= 2.001, "head cannot cross ceiling")
	}
	platform := [?]Collision_Box{collision_box({0, 0.5, 0}, {2, 1, 2}, 0.4)}
	p = {position = {0, 3, 0}}
	for _ in 0..<120 do player_step(&p, {}, 0, platform[:], PHYSICS_DT)
	testing.expect(t, p.grounded && math.abs(p.position.y - 1) < 0.001)
	for _ in 0..<120 do player_step(&p, {move = {1, 0}}, 0, platform[:], PHYSICS_DT)
	testing.expect(t, p.position.y < 0.1, "walk off a ledge and fall to ground")
	step := [?]Collision_Box{collision_box({0, 0.125, 0}, {3, 0.25, 2})}
	p = {position = {0, 0, 1.8}, grounded = true}
	for _ in 0..<40 do player_step(&p, {move = {0, 1}}, 0, step[:], PHYSICS_DT)
	testing.expect(t, p.position.y > 0.24 && p.grounded, "small steps need no jump")
}

@(test)
jump_buffer_and_coyote_time :: proc(t: ^testing.T) {
	p := Player{position = {0, 0.03, 0}, velocity = {0, -2, 0}}
	for i in 0..<6 do player_step(&p, {jump = i == 0}, 0, nil, PHYSICS_DT)
	testing.expect(t, p.velocity.y > 7, "jump pressed shortly before landing must be buffered")
	p = {position = {0, 1, 0}, coyote = 0.08}
	player_step(&p, {jump = true}, 0, nil, PHYSICS_DT)
	testing.expect(t, p.velocity.y > 8, "allow a jump just after leaving a ledge")
}

@(test)
camera_preserves_distance_behind_tall_wall :: proc(t: ^testing.T) {
	boxes := [?]Collision_Box{collision_box({0, 10, 3}, {40, 20, 0.3}, 0.2)}
	camera: world.Camera3D
	world.camera3d_init(&camera, 1280, 720)
	rig := Follow_Camera{distance = 7.5, pitch = 0.2, boom = 7.5}
	p := Player{grounded = true}
	follow_camera_step(&rig, &camera, p, boxes[:], 1.0/60.0, true)
	testing.expect(t, rig.boom > 7.4, "occlusion alone must preserve the requested zoom")
	testing.expect(t, camera_position_clear(camera.position,boxes[:],0.2))
	testing.expect(t, camera_fraction(rig.focus,camera.position,boxes[:],0.2)<1,"test must actually place the hero behind the wall")
	testing.expect(t,math.abs(rig.lift)<0.001,"a wall too tall to look over must not force a steep pitch")
	testing.expect(t, camera_fraction({0, 1, 3}, {0, 1, 8}, boxes[:], 0.2) == 0)
}

@(test)
camera_resolves_solid_endpoint_and_recovers :: proc(t: ^testing.T) {
	// An overhead slab covers every raised endpoint while leaving the player
	// space below it. The camera must shorten enough to clear its own volume.
	boxes := [?]Collision_Box{collision_box({0,5.5,3},{20,5.8,30})}
	camera: world.Camera3D
	world.camera3d_init(&camera,1280,720)
	rig := Follow_Camera{distance=7.5,pitch=0.2,boom=7.5}
	p := Player{grounded=true}
	follow_camera_step(&rig,&camera,p,boxes[:],1.0/60.0,true)
	testing.expect(t,rig.boom>5 && rig.boom<7.5,"camera volume must stop before a solid at its endpoint")
	testing.expect(t,camera_position_clear(camera.position,boxes[:],0.2))
	before := rig.boom
	follow_camera_step(&rig,&camera,p,nil,1.0/60.0)
	testing.expect(t,rig.boom>before && rig.boom<7.5,"zoom recovers smoothly after an actual collision")
	for _ in 0..<120 do follow_camera_step(&rig,&camera,p,nil,1.0/60.0)
	testing.expect(t,rig.boom>7.4)
}

@(test)
camera_raises_endpoint_out_of_nearby_deep_obstacle :: proc(t: ^testing.T) {
	boxes := [?]Collision_Box{collision_box({0,3,4},{8,6,7.2})}
	camera: world.Camera3D
	world.camera3d_init(&camera,1280,720)
	rig := Follow_Camera{distance=7.5,pitch=0.2,boom=7.5,focus={0,1.05,0}}
	follow_camera_step(&rig,&camera,{grounded=true},boxes[:],1.0/60.0)
	testing.expect(t,rig.boom>=3,"prefer a safe raised camera over collapsing against the player")
	testing.expect(t,camera_position_clear(camera.position,boxes[:],0.2))
}

@(test)
camera_does_not_snap_close_while_low_wall_lift_blends :: proc(t: ^testing.T) {
	boxes := [?]Collision_Box{collision_box({0,0.575,0.8},{5,1.15,0.6})}
	for frame_rate in ([?]f32{30,60,144}) {
		camera: world.Camera3D
		world.camera3d_init(&camera,1280,720)
		rig := Follow_Camera{distance=7.5,pitch=0.12,boom=7.5,focus={0,1.05,0}}
		for _ in 0..<90 {
			follow_camera_step(&rig,&camera,{grounded=true},boxes[:],1/frame_rate)
			testing.expect(t,rig.boom>7.4,"the first obstructed frame must not become a close-up while lift eases in")
			testing.expect(t,camera_position_clear(camera.position,boxes[:],0.2))
		}
		testing.expect(t,rig.lift>0)
	}
}

@(test)
camera_looks_over_low_wall :: proc(t: ^testing.T) {
	boxes := [?]Collision_Box{collision_box({0, 0.575, 0.8}, {5, 1.15, 0.6})}
	camera: world.Camera3D
	world.camera3d_init(&camera, 1280, 720)
	rig := Follow_Camera{distance = 7.5, pitch = 0.2, boom = 7.5}
	follow_camera_step(&rig, &camera, {grounded = true}, boxes[:], 1.0/60.0, true)
	testing.expect(t, rig.boom > 4, "low walls should not force a close-up of the character")
	testing.expect(t, rig.lift > 0)
	testing.expect(t, camera_fraction(rig.focus, camera.position, boxes[:], 0.2) == 1)
}

@(test)
fixed_step_is_consistent_across_frame_rates :: proc(t: ^testing.T) {
	a, b: State
	world.camera3d_init(&a.camera, 1280, 720)
	world.camera3d_init(&b.camera, 1280, 720)
	world.camera3d_init(&a.map_camera, 180, 180)
	world.camera3d_init(&b.map_camera, 180, 180)
	reset_controller(&a)
	reset_controller(&b)
	for _ in 0..<60 do advance_controller(&a, {move = {1, 1}}, 1.0/30.0)
	for _ in 0..<288 do advance_controller(&b, {move = {1, 1}}, 1.0/144.0)
	testing.expect(t, linalg.length(a.player.position - b.player.position) < 0.04)
}
