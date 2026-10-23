package main

import "core:math"
import "core:math/linalg"
import world "olib:kit/world"

PLAYER_RADIUS :: f32(0.38)
PLAYER_HEIGHT :: f32(1.78)
PLAYER_STEP :: f32(0.30)
PHYSICS_DT :: f32(1.0 / 120.0)
PLAYER_SPAWN :: [3]f32{0, 0, 4.8}

// Upright cylinder against level boxes. Axes come from the same transform as
// the rendered mesh, including the rotated crates and rocks.
Collision_Box :: struct {
	center, half, axis_x, axis_z: [3]f32,
}

Player :: struct {
	position, velocity: [3]f32, // position is at the feet
	yaw, gait, coyote, jump_buffer: f32,
	grounded: bool,
}

Player_Input :: struct {
	move: [2]f32, // screen right / forward
	sprint, jump: bool,
}

Follow_Camera :: struct {
	yaw, pitch, distance, boom, lift: f32,
	focus: [3]f32,
}

collision_box :: proc(center, size: [3]f32, yaw: f32 = 0) -> Collision_Box {
	rotation := place({}, {1, 1, 1}, yaw)
	return {center, size * 0.5,
		world.matrix4_transform_vector(rotation, {1, 0, 0}),
		world.matrix4_transform_vector(rotation, {0, 0, 1})}
}

box_local :: proc(box: Collision_Box, vector: [3]f32) -> [3]f32 {
	return {linalg.dot(vector, box.axis_x), vector.y, linalg.dot(vector, box.axis_z)}
}

// Minimum horizontal push-out for a circle/rotated rectangle, including the
// inside-box case. Rounded corners allow sliding instead of sticking.
box_contact :: proc(box: Collision_Box, position: [3]f32, radius: f32) -> (normal: [3]f32, depth: f32) {
	p := box_local(box, position - box.center)
	dx := p.x - math.clamp(p.x, -box.half.x, box.half.x)
	dz := p.z - math.clamp(p.z, -box.half.z, box.half.z)
	d2 := dx*dx + dz*dz
	if d2 >= radius*radius do return {}, 0
	if d2 > 0.0000001 {
		d := math.sqrt(d2)
		return (box.axis_x*dx + box.axis_z*dz) / d, radius - d
	}
	x, z := box.half.x - math.abs(p.x), box.half.z - math.abs(p.z)
	if x < z do return box.axis_x * (p.x < 0 ? f32(-1) : f32(1)), radius + x
	return box.axis_z * (p.z < 0 ? f32(-1) : f32(1)), radius + z
}

player_clear :: proc(position: [3]f32, boxes: []Collision_Box) -> bool {
	if position.y < terrain_height(position.x,position.z)-0.005 do return false
	for box in boxes {
		if position.y >= box.center.y + box.half.y - 0.001 ||
		   position.y + PLAYER_HEIGHT <= box.center.y - box.half.y + 0.001 {
			continue
		}
		_, depth := box_contact(box, position, PLAYER_RADIUS)
		if depth > 0.001 do return false
	}
	return true
}

movement_direction :: proc(input: [2]f32, camera_yaw: f32) -> [3]f32 {
	move := input
	length := linalg.length(move)
	if length > 1 do move /= length // diagonal movement has the same speed
	c, s := math.cos(camera_yaw), math.sin(camera_yaw)
	return {c*move.x - s*move.y, 0, -s*move.x - c*move.y}
}

player_step :: proc(p: ^Player, input: Player_Input, camera_yaw: f32, boxes: []Collision_Box, dt: f32) {
	if input.jump do p.jump_buffer = 0.12
	p.coyote = p.grounded ? 0.10 : max(0, p.coyote - dt)
	if p.jump_buffer > 0 && p.coyote > 0 {
		p.velocity.y = 9
		p.grounded = false
		p.jump_buffer, p.coyote = 0, 0
	}
	p.jump_buffer = max(0, p.jump_buffer - dt)
	direction := movement_direction(input.move, camera_yaw)
	speed: f32 = input.sprint ? 6.5 : 4.2
	horizontal := [3]f32{p.velocity.x, 0, p.velocity.z}
	change := direction*speed - horizontal
	acceleration: f32 = p.grounded ? 38 : 14
	length := linalg.length(change)
	if length > acceleration*dt do change *= acceleration*dt / length
	horizontal += change
	p.velocity.x, p.velocity.z = horizontal.x, horizontal.z
	if linalg.length(direction) > 0.01 {
		yaw := math.atan2(direction.x, -direction.z)
		delta := math.atan2(math.sin(yaw - p.yaw), math.cos(yaw - p.yaw))
		p.yaw += delta * (1 - math.exp(-18*dt))
	}
	previous := p.position
	follow_ground := p.grounded && p.velocity.y <= 0 && math.abs(previous.y-terrain_height(previous.x,previous.z))<0.04
	p.position += horizontal * dt
	if follow_ground do p.position.y = max(p.position.y,terrain_height(p.position.x,p.position.z))
	// Resolve multiple contacts (e.g. a corner between two crates).
	for _ in 0..<4 {
		for box in boxes {
			top, bottom := box.center.y + box.half.y, box.center.y - box.half.y
			if p.position.y >= top - 0.001 || p.position.y + PLAYER_HEIGHT <= bottom + 0.001 do continue
			normal, depth := box_contact(box, p.position, PLAYER_RADIUS)
			if depth <= 0 do continue
			step_position := p.position
			step_position.y = top
			if p.grounded && top - p.position.y <= PLAYER_STEP && player_clear(step_position, boxes) {
				p.position = step_position
				continue
			}
			p.position += normal * (depth + 0.0001)
			into := linalg.dot(p.velocity, normal)
			if into < 0 do p.velocity -= normal * into
		}
	}
	// Sweep the vertical interval, so landing and head hits cannot tunnel.
	old_y := p.position.y
	p.velocity.y -= 22 * dt
	next_y := old_y + p.velocity.y * dt
	p.grounded = false
	for box in boxes {
		_, depth := box_contact(box, p.position, PLAYER_RADIUS - 0.002)
		if depth <= 0 do continue
		top, bottom := box.center.y + box.half.y, box.center.y - box.half.y
		if p.velocity.y <= 0 && old_y >= top - 0.001 && next_y <= top {
			next_y = top
			p.velocity.y = 0
			p.grounded = true
		} else if p.velocity.y > 0 && old_y + PLAYER_HEIGHT <= bottom + 0.001 && next_y + PLAYER_HEIGHT >= bottom {
			next_y = bottom - PLAYER_HEIGHT
			p.velocity.y = 0
		}
	}
	floor := terrain_height(p.position.x,p.position.z)
	if next_y <= floor || (follow_ground && p.velocity.y <= 0 && old_y-floor<0.15) {
		next_y = floor
		p.velocity.y = 0
		p.grounded = true
	}
	p.position.y = next_y
	// Keep the controller on the finite 240 x 240 ground mesh.
	p.position.x = math.clamp(p.position.x, -110, 110)
	p.position.z = math.clamp(p.position.z, -110, 110)
	if p.grounded {
		delta := p.position - previous
		p.gait += math.sqrt(delta.x*delta.x + delta.z*delta.z) * 10
	}
}

// A segment against expanded OBBs is a conservative camera sphere sweep.
// Returning zero when the start is inside also keeps the boom out of solids.
camera_fraction :: proc(start, finish: [3]f32, boxes: []Collision_Box, padding: f32) -> f32 {
	fraction: f32 = 1
	if min(start.y,finish.y) < padding {
		delta := finish-start
		steps := max(1,int(math.ceil(linalg.length(delta)/0.1)))
		for i in 0..=steps {
			t := f32(i)/f32(steps)
			p := start+delta*t
			if p.y < terrain_height(p.x,p.z)+padding {
				lo,hi := max(0,f32(i-1)/f32(steps)),t
				for _ in 0..<8 {
					mid := (lo+hi)*0.5
					q := start+delta*mid
					if q.y < terrain_height(q.x,q.z)+padding { hi=mid } else { lo=mid }
				}
				fraction=lo
				break
			}
		}
	}
	for box in boxes {
		origin := box_local(box, start - box.center)
		delta := box_local(box, finish - start)
		half := box.half + [3]f32{padding, padding, padding}
		enter, leave: f32 = 0, 1
		for axis in 0..<3 {
			if math.abs(delta[axis]) < 0.000001 {
				if math.abs(origin[axis]) > half[axis] { leave = -1; break }
			} else {
				a := (-half[axis] - origin[axis]) / delta[axis]
				b := (half[axis] - origin[axis]) / delta[axis]
				enter = max(enter, min(a, b))
				leave = min(leave, max(a, b))
			}
		}
		if enter <= leave && leave >= 0 do fraction = min(fraction, enter)
	}
	return fraction
}

camera_position_clear :: proc(position: [3]f32, boxes: []Collision_Box, padding: f32) -> bool {
	return camera_fraction(position,position,boxes,padding) == 1
}

// Occlusion is handled by the hero silhouette. Only the camera's own volume
// constrains its distance: a wall between player and camera is not a collision.
camera_fit_distance :: proc(focus, direction: [3]f32, requested: f32,
	boxes: []Collision_Box, padding: f32) -> f32 {
	if camera_position_clear(focus+direction*requested,boxes,padding) do return requested
	steps := max(1,int(math.ceil(requested/0.1)))
	blocked := requested
	for i in 1..=steps {
		candidate := max(0.02,requested-f32(i)*0.1)
		if camera_position_clear(focus+direction*candidate,boxes,padding) {
			clear := candidate
			for _ in 0..<8 {
				mid := (clear+blocked)*0.5
				if camera_position_clear(focus+direction*mid,boxes,padding) { clear=mid } else { blocked=mid }
			}
			return max(0.02,clear-0.01)
		}
		blocked=candidate
	}
	return 0.02
}

follow_camera_step :: proc(rig: ^Follow_Camera, camera: ^world.Camera3D, player: Player,
	boxes: []Collision_Box, dt: f32, snap := false) {
	target := player.position + [3]f32{0, 1.05, 0}
	weight: f32 = snap ? 1 : 1 - math.exp(-12*dt)
	rig.focus += (target - rig.focus) * weight
	// A lagging target must not pass through a wall as the player rounds it.
	if camera_fraction(target, rig.focus, boxes, 0.08) < 1 do rig.focus = target
	rig.focus.y = max(rig.focus.y, player.position.y + 0.65)
	padding := 0.15 + camera.near_clip * math.tan(camera.field_of_view*0.5) *
		math.sqrt(1 + camera.aspect_ratio*camera.aspect_ratio)
	// Lift only when it actually reveals the player. Tall occluders retain the
	// requested pitch and framing; their hidden hero is drawn as a silhouette.
	requested_lift: f32 = 0
	auto_pitch := max(rig.pitch,1.10)
	for attempt in 0..=10 {
		angle := rig.pitch+(auto_pitch-rig.pitch)*f32(attempt)/10
		direction := [3]f32{math.sin(rig.yaw)*math.cos(angle), math.sin(angle), math.cos(rig.yaw)*math.cos(angle)}
		fraction := camera_fraction(rig.focus, rig.focus + direction*rig.distance, boxes, padding)
		if fraction == 1 {
			requested_lift=angle-rig.pitch
			break
		}
	}
	rig.lift += (requested_lift - rig.lift) * (snap ? f32(1) : 1 - math.exp(-10*dt))
	angle := min(rig.pitch + rig.lift, 1.35)
	direction := [3]f32{math.sin(rig.yaw)*math.cos(angle), math.sin(angle), math.cos(rig.yaw)*math.cos(angle)}
	allowed := camera_fit_distance(rig.focus,direction,rig.distance,boxes,padding)
	// If the requested endpoint itself is buried in a solid, try a higher
	// position before accepting a close-up. Ordinary occlusion never enters here.
	if allowed < min(rig.distance,3) {
		for attempt in 1..=10 {
			candidate := angle+(1.35-angle)*f32(attempt)/10
			axis := [3]f32{math.sin(rig.yaw)*math.cos(candidate),math.sin(candidate),math.cos(rig.yaw)*math.cos(candidate)}
			distance := camera_fit_distance(rig.focus,axis,rig.distance,boxes,padding)
			if distance>allowed {
				direction,allowed = axis,distance
				rig.lift=candidate-rig.pitch
			}
			if allowed>=min(rig.distance,3) do break
		}
	}
	// Pull out of an actual solid immediately; recover the requested zoom gently.
	if snap || allowed < rig.boom { rig.boom = allowed } else { rig.boom += (allowed - rig.boom) * (1 - math.exp(-5*dt)) }
	// Zoom recovery and a moving focus must not leave intermediate positions
	// inside a wall, even when the final requested endpoint is clear.
	rig.boom=camera_fit_distance(rig.focus,direction,rig.boom,boxes,padding)
	world.camera3d_set_target(camera, rig.focus)
	world.camera3d_set_position(camera, rig.focus + direction * rig.boom)
}

reset_controller :: proc(s: ^State) {
	s.player = {position = PLAYER_SPAWN, grounded = true}
	s.follow = {pitch = 0.38, distance = 7.5, boom = 7.5}
	s.physics_accumulator = 0
	follow_camera_step(&s.follow, &s.camera, s.player, s.colliders[:], 0, true)
}

// Blob follows the highest supporting surface below the feet, including boxes.
player_shadow_height :: proc(p: Player, boxes: []Collision_Box) -> f32 {
	height := terrain_height(p.position.x,p.position.z)
	for box in boxes {
		local := box_local(box, p.position - box.center)
		top := box.center.y + box.half.y
		if math.abs(local.x) <= box.half.x && math.abs(local.z) <= box.half.z && top <= p.position.y + 0.01 {
			height = max(height, top)
		}
	}
	return height
}
