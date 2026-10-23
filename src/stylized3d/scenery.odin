package main

import "core:math"
import dasset "olib:core/dasset"
import foster "olib:foster"
import r3d "olib:kit/rendering/3d"
import mat "olib:kit/rendering/material"
import world "olib:kit/world"

Scenery_Kind :: enum {Stonework, Crowns, Rocks, Trunks, Grass, Flowers}
Scenery_Batch :: struct {
	mesh: ^foster.Mesh,
	material: ^mat.Material,
	instances: r3d.Model_Buffer,
	count: int,
	bounds: dasset.Dasset_Bounds,
	casts_shadow: bool,
}

meadow_hash :: proc(value: u32) -> f32 {
	x := value
	x ~= x >> 16; x *= 0x7feb352d; x ~= x >> 15; x *= 0x846ca68b; x ~= x >> 16
	return f32(x & 0xffffff) / f32(0x1000000)
}

// Keep in sync with the ground shader. Decoration deliberately leaves this route clear.
meadow_path :: proc(z: f32) -> f32 {
	return 2.8 * math.exp(-math.pow((z-1)/3, 2)) + 0.55 * math.sin(z*0.38)
}

build_level :: proc(s: ^State) -> string {
	groups: [Scenery_Kind][dynamic]r3d.Model_Item
	defer for &items in groups do delete(items)
	add :: proc(groups: ^[Scenery_Kind][dynamic]r3d.Model_Item, kind: Scenery_Kind, p, size: [3]f32, color: [4]f32, yaw: f32 = 0) {
		append(&groups[kind], r3d.Model_Item{place(p, size, yaw), color})
	}
	STONE :: [4]f32{0.78, 0.72, 0.55, 1}
	// The original obstacle stays the same size; seams, individual caps and moss
	// provide readable detail without introducing tiny collision obstacles.
	append(&s.colliders, collision_box({-0.8,0.575,1.4}, {5,1.15,0.6}))
	for row in 0..<2 do for column in 0..<6 {
		x := -2.88 + f32(column)*0.835
		jitter := meadow_hash(u32(row*6+column))
		add(&groups, .Stonework, {x,0.24+f32(row)*0.48,1.4}, {0.815,0.46,0.60}, STONE*[4]f32{0.96+jitter*0.08,0.96+jitter*0.08,0.96+jitter*0.08,1})
	}
	for column in 0..<6 {
		x := -2.88 + f32(column)*0.835
		add(&groups, .Stonework, {x,1.055,1.4}, {0.83,0.19,0.76}, {0.88,0.82,0.64,1})
		if column % 3 == 0 do add(&groups, .Stonework, {x,1.157,1.43}, {0.45,0.015,0.48}, {0.45,0.55,0.26,1})
	}
	// An ochre ledge, with an irregular grass lip rather than a single flat strip.
	append(&s.colliders, collision_box({0,0.7,-13}, {44,1.4,8}))
	append(&s.colliders, collision_box({0,1.5,-13}, {44,0.2,8.2}))
	add(&groups, .Stonework, {0,0.7,-13}, {44,1.4,8}, {0.56,0.43,0.28,1})
	add(&groups, .Stonework, {0,1.5,-13}, {44,0.2,8.2}, {0.52,0.65,0.29,1})
	for i in 0..<30 {
		x := -21.4 + f32(i)*1.46
		add(&groups, .Stonework, {x,1.32,-9.0}, {1.4,0.20+meadow_hash(u32(i))*0.22,0.25}, {0.46,0.58,0.25,1})
	}
	ROCKS :: [?]struct{p,size:[3]f32,yaw:f32}{
		{{3,0.12,3.4},{0.7,0.45,0.55},0.35}, {{3.5,0.08,3.9},{0.4,0.3,0.35},-0.6},
		{{-4.6,0.15,0.92},{0.8,0.5,0.6},-0.5}, {{6.4,0.1,2.2},{0.5,0.35,0.5},0.8},
	}
	for rock, i in ROCKS {
		p := rock.p + [3]f32{0,terrain_height(rock.p.x,rock.p.z),0}
		append(&s.colliders, collision_box(p,rock.size,rock.yaw))
		add(&groups,.Rocks,p,rock.size*0.65,{0.59+f32(i)*0.025,0.61,0.57,1},rock.yaw)
	}
	CRATES :: [?]struct{p:[3]f32,yaw:f32}{{{4.3,0.4,-1.4},0.15},{{5.2,0.4,-1.1},-0.3},{{4.7,1.2,-1.3},0.5}}
	for crate in CRATES {
		append(&s.colliders, collision_box(crate.p,{0.8,0.8,0.8},crate.yaw))
		add(&groups,.Stonework,crate.p,{0.8,0.8,0.8},{0.63,0.38,0.19,1},crate.yaw)
		parent := place(crate.p,{1,1,1},crate.yaw)
		for side in 0..<2 do for edge in 0..<2 {
			z: f32 = side == 0 ? -0.411 : 0.411
			x: f32 = edge == 0 ? -0.30 : 0.30
			append(&groups[.Stonework],r3d.Model_Item{world.matrix4_multiply(place({x,0,z},{0.095,0.8,0.035}),parent),{0.85,0.63,0.34,1}})
			append(&groups[.Stonework],r3d.Model_Item{world.matrix4_multiply(place({0,x,z},{0.8,0.095,0.035}),parent),{0.85,0.63,0.34,1}})
		}
		for plank in 0..<3 {
			append(&groups[.Stonework],r3d.Model_Item{world.matrix4_multiply(place({f32(plank-1)*0.26,0.407,0},{0.24,0.025,0.78}),parent),{0.77,0.52,0.27,1}})
		}
	}
	TREES :: [?][3]f32{{-5.6,0,-3.4},{6.2,0,-4.4},{-8.2,0,1.6},{8.6,0,0.6},{-10.5,0,-5.5},{10.8,0,-6.2},{1.8,0,-7.0}, {-14,0,-3}, {14,0,-2}}
	for p, i in TREES {
		v := meadow_hash(u32(i+100))
		height := 1.75 + v*0.45
		add(&groups,.Trunks,p,{1.2,height,1.2},{0.42,0.29,0.18,1},f32(i)*1.8)
		append(&s.colliders,collision_box(p+[3]f32{0,height*0.5,0},{0.48,height,0.48}))
		for crown in 0..<3 {
			offset := [3]f32{f32(crown-1)*0.62, height + 0.30 + (crown == 1 ? f32(0.62) : 0), f32(crown%2)*0.25}
			scale := crown == 1 ? [3]f32{0.95,1.05,0.9} : [3]f32{1.05,0.82,1.0}
			scale *= 0.91 + v*0.25
			leaf := [4]f32{0.38 + v*0.12 + f32(crown)*0.035, 0.56 + v*0.10, 0.22 + v*0.06, 1}
			add(&groups,.Crowns,p+offset,scale,leaf,f32(i+crown)*0.7)
			// Shared low-poly crowns use conservative bounds for controller/camera.
			append(&s.colliders,collision_box(p+offset,scale*2))
		}
	}
	// Distant crowns above the ledge make a layered orchard silhouette.
	for i in 0..<9 {
		x := -25 + f32(i)*6.0
		p := [3]f32{x,0,-24-meadow_hash(u32(i+800))*4}
		add(&groups,.Trunks,p,{1.5,2.6,1.5},{0.45,0.39,0.25,1},f32(i))
		add(&groups,.Crowns,p+[3]f32{0,3,0},{2.3,1.5+meadow_hash(u32(i+910))*0.6,2.0},{0.46,0.59,0.35,1},f32(i))
		append(&s.colliders,collision_box(p+[3]f32{0,1.3,0},{0.6,2.6,0.6}))
		append(&s.colliders,collision_box(p+[3]f32{0,3,0},{4.6,5.6,4}))
	}
	// Static decoration: deterministic placement, sparse near the playable path.
	for i in 0..<1200 {
		seed := u32(i)*11
		x, z := -15 + meadow_hash(seed+1)*30, -8.4 + meadow_hash(seed+2)*19
		if math.abs(x-meadow_path(z)) < 1.42 do continue
		if pond_contains(x,z,0.3) do continue
		p := [3]f32{x,0,z}
		blocked := false
		for box in s.colliders {
			if box.center.y-box.half.y > 0.4 do continue
			_, depth := box_contact(box,p,0.22)
			if depth > 0 { blocked = true; break }
		}
		if blocked do continue
		v := meadow_hash(seed+3)
		if meadow_hash(seed+4) < 0.70 {
			size := 0.22+v*0.22
			add(&groups,.Grass,p,{size,0.18+v*0.23,size},{0.40+v*0.12,0.55+v*0.10,0.20+v*0.06,1},meadow_hash(seed+5)*6.28)
		} else if meadow_hash(seed+6) > 0.35 {
			size := 0.44+v*0.24
			color := [4]f32{0.96,0.88,0.64,1}
			if v < 0.32 do color = {0.76,0.60,0.76,1}
			if v > 0.7 do color = {0.97,0.69,0.47,1}
			add(&groups,.Flowers,p,{size,size,size},color,meadow_hash(seed+5)*6.28)
		}
	}
	// Taller waterside tufts share the resident grass mesh, material and wind.
	for i in 0..<22 {
		v := meadow_hash(u32(i+2100))
		if v < 0.23 do continue
		angle := f32(i)*2*math.PI/22
		direction := [2]f32{math.cos(angle),math.sin(angle)}
		p2 := POND_CENTER+direction/pond_distance(direction)*POND_RADIUS*(1.08+v*0.07)
		p := [3]f32{p2.x,terrain_height(p2.x,p2.y),p2.y}
		blocked := false
		for box in s.colliders {
			if box.center.y-box.half.y > p.y+0.8 do continue
			_,depth := box_contact(box,p,0.35)
			if depth>0 { blocked=true; break }
		}
		if !blocked do add(&groups,.Grass,p,{0.32+v*0.12,0.50+v*0.35,0.32+v*0.12},{0.32+v*0.06,0.48+v*0.08,0.22,1},angle+v)
	}
	for &coin, i in s.coins {
		x := -4.8+f32(i)*1.2
		z: f32 = i%3 == 0 ? -2.2 : 3
		coin = {place({x,0.95,z},{0.5,0.5,0.5}),{1,0.78,0.24,1}}
	}
	meshes := [Scenery_Kind]^foster.Mesh{.Stonework=&s.cube,.Crowns=&s.crown_mesh,.Rocks=&s.facet,.Trunks=&s.trunk_mesh,.Grass=&s.grass_mesh,.Flowers=&s.flower_mesh}
	materials := [Scenery_Kind]^mat.Material{.Stonework=s.toon,.Crowns=s.toon,.Rocks=s.toon,.Trunks=s.toon,.Grass=s.grass_material,.Flowers=s.flower_material}
	for &batch, kind in s.scenery {
		items := groups[kind][:]
		batch.mesh, batch.material = meshes[kind],materials[kind]
		batch.count = len(items)
		batch.casts_shadow = kind != .Grass && kind != .Flowers
		batch.bounds = {min = {-30,-0.5,-32},max = {30,8,12}} // includes wind displacement
		if reason := r3d.model_buffer_init(&batch.instances,batch.material,len(items),"meadow static instances"); reason != "" do return reason
		if !r3d.model_buffer_upload(&batch.instances,items) do return "Cannot upload scenery instances"
		s.scenery_instances += len(items)
	}
	return ""
}

record_scenery :: proc(s: ^State) -> bool {
	for &batch in s.scenery {
		if r3d.buffer(&s.renderer,batch.mesh,batch.material,&batch.instances,batch.count,&batch.bounds) != .None do return false
		// Shadow material has the same zero-slot instance layout, reusing the GPU data.
		if batch.casts_shadow && r3d.buffer(&s.renderer,batch.mesh,s.sun_caster,&batch.instances,batch.count,&batch.bounds) != .None do return false
	}
	return true
}
