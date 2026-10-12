package main

import "core:fmt"
import foster "olib:foster"

// 游戏状态与 App 分开：堆分配后经 AppSetUserData 挂到 App 上。
// 不要把 App 嵌在 World 里，web 下 Run 会把 App 搬到堆上，嵌入的那份即过期。
World :: struct {
	Score: int,
}

startup :: proc(app: ^foster.App) {
	world := foster.AppGetUserDataAs(app, World)
	world.Score = 0
	fmt.println("startup score:", world.Score)
}

update :: proc(app: ^foster.App) {
	world := foster.AppGetUserDataAs(app, World)
	world.Score += 1
	if world.Score >= 60 {
		foster.Exit(app)
	}
}

shutdown :: proc(app: ^foster.App) {
	world := foster.AppGetUserDataAs(app, World)
	fmt.println("shutdown score:", world.Score)
	free(world)
	foster.AppSetUserData(app, nil)
}

main :: proc() {
	app: foster.App
	foster.InitApp(&app, foster.DefaultAppConfig("AppComposition", 320, 180))
	defer foster.Dispose(&app)

	// 必须堆分配（或全局）：web 下 main 在 Run 注册帧循环后立即返回。
	foster.AppSetUserData(&app, new(World))
	app.StartupProc = startup
	app.UpdateProc = update
	app.ShutdownProc = shutdown
	foster.Run(&app)
}
