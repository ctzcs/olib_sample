package shader_lab_files

// SDL 桌面文件选择与拖放接线；回调只投递拥有的数据，GPU/工具修改回到主线程。
// 分区：状态与回调 / 生命周期 / 主线程收取。
import "base:runtime"
import "core:c"
import "core:strings"
import "core:sync"

import lab "olib:kit/tools/shader_lab"
import SDL "vendor:sdl3"

Pending :: struct {
	mutex: sync.Mutex,
	id: u64,
	done, abandoned: bool,
	path: string,
	filter: SDL.DialogFileFilter,
}

Bridge :: struct {
	window: ^SDL.Window,
	window_id: SDL.WindowID,
	mutex: sync.Mutex,
	queued, frame: [dynamic]string,
	queued_x, queued_y, frame_x, frame_y: f32,
	pending: ^Pending,
	watching: bool,
	consumed: bool,
}

dialog_callback :: proc "c" (userdata: rawptr, paths: [^]cstring, filter: c.int) {
	context = runtime.default_context()
	context.allocator = runtime.heap_allocator()
	p := cast(^Pending)userdata
	sync.mutex_lock(&p.mutex)
	if p.abandoned {
		sync.mutex_unlock(&p.mutex)
		free(p)
		return
	}
	if paths != nil && paths[0] != nil do p.path = strings.clone(string(paths[0]))
	p.done = true
	sync.mutex_unlock(&p.mutex)
	_ = filter
}

drop_callback :: proc "c" (userdata: rawptr, event: ^SDL.Event) -> bool {
	context = runtime.default_context()
	context.allocator = runtime.heap_allocator()
	b := cast(^Bridge)userdata
	if event.type != .DROP_FILE || event.drop.windowID != b.window_id || event.drop.data == nil do return true
	sync.mutex_lock(&b.mutex)
	append(&b.queued, strings.clone(string(event.drop.data)))
	b.queued_x = event.drop.x
	b.queued_y = event.drop.y
	sync.mutex_unlock(&b.mutex)
	return true
}

// 交给 Shader Lab 的 Config.open_file：用系统默认程序打开源码文件。
open_file :: proc(path: string) -> bool {
	url, _ := strings.replace_all(path, "\\", "/", context.temp_allocator)
	url = strings.has_prefix(url, "/") ? strings.concatenate({"file://", url}, context.temp_allocator) :
		strings.concatenate({"file:///", url}, context.temp_allocator)
	return SDL.OpenURL(strings.clone_to_cstring(url, context.temp_allocator))
}

init :: proc(b: ^Bridge, window: ^SDL.Window) {
	b.window = window
	b.window_id = SDL.GetWindowID(window)
	b.watching = SDL.AddEventWatch(drop_callback, b)
	SDL.SetEventEnabled(.DROP_FILE, true)
}

dispose :: proc(b: ^Bridge) {
	context.allocator = runtime.heap_allocator()
	if b.watching do SDL.RemoveEventWatch(drop_callback, b)
	if p := b.pending; p != nil {
		sync.mutex_lock(&p.mutex)
		done := p.done
		p.abandoned = true
		sync.mutex_unlock(&p.mutex)
		if done {
			delete(p.path)
			free(p)
		}
		// 未完成对话框的独立 Pending 由回调释放，不再借用宿主或 Session。
	}
	for path in b.queued do delete(path)
	for path in b.frame do delete(path)
	delete(b.queued)
	delete(b.frame)
	b^ = {}
}

update :: proc(b: ^Bridge, tool: ^lab.Session) {
	context.allocator = runtime.heap_allocator()
	if b.consumed {
		for path in b.frame do delete(path)
		clear(&b.frame)
		b.consumed = false
	}
	sync.mutex_lock(&b.mutex)
	if len(b.queued) > 0 {
		append(&b.frame, ..b.queued[:])
		clear(&b.queued)
		b.frame_x = b.queued_x
		b.frame_y = b.queued_y
	}
	sync.mutex_unlock(&b.mutex)
	if p := b.pending; p != nil {
		sync.mutex_lock(&p.mutex)
		done := p.done
		sync.mutex_unlock(&p.mutex)
		if done {
			_ = lab.file_reply(tool, p.id, p.path)
			delete(p.path)
			free(p)
			b.pending = nil
		}
	}
	request := lab.file_request(tool)
	if b.pending != nil || request.id == 0 do return
	p := new(Pending)
	p.id = request.id
	b.pending = p
	if request.action == .Texture {
		p.filter = {"Images", "png;jpg;jpeg;qoi"}
	} else {
		p.filter = {request.shader != "" ? "Model material" : "Shader preset", "json"}
	}
	if request.action == .Save_Preset {
		SDL.ShowSaveFileDialog(dialog_callback, p, b.window, &p.filter, 1, request.shader != "" ? "material.json" : "shader-preset.json")
	} else {
		SDL.ShowOpenFileDialog(dialog_callback, p, b.window, &p.filter, 1, nil, false)
	}
}

// 本帧拖入的文件与位置，交给 lab.draw。SDL drop 坐标是窗口逻辑坐标，与 ImGui 坐标相同；
// 路径借用到下一次 update，每批只交出一次。
drops :: proc(b: ^Bridge) -> (paths: []string, position: [2]f32) {
	if b.consumed || len(b.frame) == 0 do return nil, {}
	b.consumed = true
	return b.frame[:], {b.frame_x, b.frame_y}
}
