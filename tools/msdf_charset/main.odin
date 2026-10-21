package main

// 从 .oshader 收集 Shader Lab 会显示的 Shader、Pass、Shader、文件夹和字段标签，把缺的字补进共享 MSDF 字符集。
// 只追加不删除；之后按 shared/msdf_font/README.md 重新生成图集。-check 只报告缺字，有缺字时退出码为 1。
//   odin run tools/msdf_charset -collection:olib=../olib [-- [-check] [<oshader 目录>...]]
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"

import lang "olib:kit/rendering/shader/lang"

main :: proc() {
	root :: #directory + "/../.."
	charset_path :: root + "/shared/msdf_font/charset.txt"
	check := false
	dirs: [dynamic]string
	for arg in os.args[1:] {
		if arg == "-check" do check = true
		else do append(&dirs, arg)
	}
	if len(dirs) == 0 do append(&dirs, root + "/src/shader_lab/shaders")

	text, read_err := os.read_entire_file(charset_path, context.allocator)
	if read_err != nil {
		fmt.eprintfln("read %s: %v", charset_path, read_err)
		os.exit(1)
	}
	known, ok := charset_codepoints(string(text))
	if !ok {
		fmt.eprintfln("%s: 只支持 [a, b] 区间和 0x 码点", charset_path)
		os.exit(1)
	}

	missing: map[rune]string
	for dir in dirs {
		entries, dir_err := os.read_all_directory_by_path(dir, context.allocator)
		if dir_err != nil {
			fmt.eprintfln("read %s: %v", dir, dir_err)
			os.exit(1)
		}
		for entry in entries {
			if !strings.has_suffix(entry.name, ".oshader") do continue
			source, err := os.read_entire_file(entry.fullpath, context.allocator)
			if err != nil {
				fmt.eprintfln("read %s: %v", entry.fullpath, err)
				os.exit(1)
			}
			doc := lang.parse(string(source), entry.fullpath)
			if doc.error != "" {
				fmt.eprintln(doc.error)
				os.exit(1)
			}
			collect(&missing, known, doc.shader.label)
			for p in doc.shader.passes do collect(&missing, known, p.label)
			for s in doc.schemas {
				collect(&missing, known, s.label)
				collect(&missing, known, s.folder)
				for f in s.fields do collect(&missing, known, f.label)
			}
		}
	}

	added, _ := slice.map_keys(missing)
	slice.sort(added)
	for cp in added do fmt.printfln("missing U+%04X %v in %s", cp, cp, missing[cp])
	if check {
		if len(added) > 0 do os.exit(1)
		return
	}
	if len(added) == 0 {
		fmt.println("charset 已包含全部标签字符")
		return
	}
	b := strings.builder_make()
	strings.write_bytes(&b, text)
	if !strings.has_suffix(string(text), "\n") do strings.write_byte(&b, '\n')
	strings.write_byte(&b, '\n')
	for cp in added do fmt.sbprintfln(&b, "0x%04X", cp)
	if err := os.write_entire_file(charset_path, b.buf[:]); err != nil {
		fmt.eprintfln("write %s: %v", charset_path, err)
		os.exit(1)
	}
	fmt.printfln("已向 %s 追加 %d 个字符；按 shared/msdf_font/README.md 重新生成图集", charset_path, len(added))
}

// 与 Shader Lab 的缺字检查一致：控制字符不需要字形。
collect :: proc(missing: ^map[rune]string, known: map[rune]bool, label: string) {
	for cp in label {
		if cp < ' ' || known[cp] || cp in missing do continue
		missing[cp] = label
	}
}

charset_codepoints :: proc(text: string) -> (known: map[rune]bool, ok: bool) {
	rest := text
	for len(rest) > 0 {
		rest = strings.trim_left_space(rest)
		if len(rest) == 0 do break
		if rest[0] == '[' {
			end := strings.index_byte(rest, ']')
			if end < 0 do return
			bounds := strings.split(rest[1:end], ",", context.temp_allocator)
			if len(bounds) != 2 do return
			lo, lo_ok := strconv.parse_int(strings.trim_space(bounds[0]))
			hi, hi_ok := strconv.parse_int(strings.trim_space(bounds[1]))
			if !lo_ok || !hi_ok do return
			for cp in lo ..= hi do known[rune(cp)] = true
			rest = rest[end + 1:]
			continue
		}
		end := 0
		for end < len(rest) && !strings.is_space(rune(rest[end])) do end += 1
		value, value_ok := strconv.parse_int(rest[:end])
		if !value_ok || !strings.has_prefix(rest, "0x") do return
		known[rune(value)] = true
		rest = rest[end:]
	}
	return known, true
}
