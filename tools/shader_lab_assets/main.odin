package main

// 正式资源构建入口：从 .oshader 同时生成材质清单和预编译字节码。
import "core:fmt"
import "core:os"

main :: proc() {
	root :: #directory + "/../.."
	state, out, error, err := os.process_exec({command = []string{
		"odin", "run", root + "/../olib/tools/shaders", "-out:" + root + "/build/shader_assets.exe", "--",
		"-dir:" + root + "/src/shader_lab/shaders",
	}}, context.temp_allocator)
	fmt.print(string(out))
	if err != nil || state.exit_code != 0 { fmt.eprintln(string(error)); os.exit(1) }
}
