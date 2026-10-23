#+test
package main

import "core:math"
import "core:math/linalg"
import "core:testing"
import world "olib:kit/world"

@(test)
sun_projection_covers_player :: proc(t: ^testing.T) {
	_, vp := sun_shadow_matrix(PLAYER_SPAWN)
	p, ok := world.matrix4_transform_point(vp,PLAYER_SPAWN)
	testing.expect(t,ok && math.abs(p.x)<0.01 && math.abs(p.y)<0.01 && p.z>0.4 && p.z<0.6)
	light := linalg.normalize(SUN_DIRECTION)
	near, _ := world.matrix4_transform_point(vp,PLAYER_SPAWN-light*39)
	far, _ := world.matrix4_transform_point(vp,PLAYER_SPAWN+light*45)
	testing.expect(t,math.abs(near.z)<0.001 && math.abs(far.z-1)<0.001)
}
