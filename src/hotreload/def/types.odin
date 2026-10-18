// 无引擎依赖的游戏常量与命令；热重载服务协议另放 contract。
package def

WORLD_SIZE :: [2]f32{1000, 640}
PICKUPS :: [8][2]f32{
	{260, 320}, {500, 320}, {740, 320}, {840, 160},
	{600, 140}, {360, 140}, {340, 500}, {720, 500},
}

Commands :: struct {
	toggle_pause: bool,
	new_run: bool,
}

Tuning :: struct {
	move_speed: f32,
	pickup_score: i64,
}
