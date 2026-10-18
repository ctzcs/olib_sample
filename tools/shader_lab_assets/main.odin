package main

// 正式资源构建入口：同一份参数生成头文件，再预编译 Shader Lab 的 HLSL。
import "core:fmt"
import "core:os"
import dev "olib:kit/shaderdev"

main :: proc() {
	root :: #directory + "/../.."
	build := dev.parameters_compile(root + "/src/shader_lab/shader_params")
	defer dev.parameter_build_dispose(&build)
	if build.error != "" { fmt.eprintln(build.error); os.exit(1) }
	reason := dev.parameters_write_headers(build.schemas, root + "/library/shader_dev")
	if reason != "" { fmt.eprintln(reason); os.exit(1) }
	state, out, error, err := os.process_exec({command = []string{
		"odin", "run", root + "/../olib/tools/shaders", "-out:" + root + "/build/shader_assets.exe", "--",
		"-dir:" + root + "/src/shader_lab/shaders",
	}}, context.temp_allocator)
	fmt.print(string(out))
	if err != nil || state.exit_code != 0 { fmt.eprintln(string(error)); os.exit(1) }
}
