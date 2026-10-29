package main

import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

import foster "olib:foster"
import r2d "olib:kit/rendering/2d"
import "olib:thirdparty/onet/objects"
import voicelib "olib:thirdparty/voice"
import sdl3 "vendor:sdl3"

// ==============================================================================
// 语音诊断：F1 面板逐段显示麦克风 → 发送 → 接收 → 解码 → 输出，并给出结论；
// 同样的内容每 2 秒写进 exe 旁的 net_fps_voice.log（发布版没有控制台，靠它远程排查）。
// ==============================================================================

LOG_PERIOD :: f32(2)
LOG_MAX_LINES :: 5000

Talker_Stat :: struct {
	packets, empty: int, // 收到的包 / 其中显式静音包
	prev:           int,
	rate:           f32, // 包/秒
	last_rx:        f32, // 诊断时钟
	level:          f32, // 解码后音频电平（平滑）
}

Voice_Diag :: struct {
	show:          bool,
	clock:         f32,
	captured:      int,
	prev_captured: int,
	prev_sent:     int,
	capture_rate:  f32,
	send_rate:     f32,
	mic_avg:       f32,
	rate_t:        f32,
	beeps:         int,
	talkers:       map[objects.Network_Id]Talker_Stat,
	log:           ^os.File,
	log_path:      string,
	log_t:         f32,
	log_lines:     int,
	last_verdict:  string,
}

Verdict :: struct {
	text:  string,
	level: int, // 0 正常，1 提示，2 有问题
}

//@region 采集
diag_packet :: proc(v: ^Voice, id: objects.Network_Id, empty: bool) {
	// 先插入再取地址：对不存在的键取 &map[key] 得到 nil。
	if id not_in v.diag.talkers do v.diag.talkers[id] = {}
	t := &v.diag.talkers[id]
	t.packets += 1
	if empty do t.empty += 1
	t.last_rx = v.diag.clock
}

diag_decoded :: proc(v: ^Voice, id: objects.Network_Id, pcm: []f32) {
	t, ok := &v.diag.talkers[id]
	if !ok || len(pcm) == 0 do return
	sum: f32
	for s in pcm do sum += s * s
	rms := math.sqrt(sum / f32(len(pcm)))
	t.level = max(rms, t.level * 0.9)
}

diag_tick :: proc(a: ^App, dt: f32) {
	v := &a.voice
	d := &v.diag
	d.mic_avg += (v.mic_level - d.mic_avg) * min(1, dt * 3)
	d.rate_t += dt
	if d.rate_t >= 1 {
		d.capture_rate = f32(d.captured - d.prev_captured) / d.rate_t
		d.send_rate = f32(v.sent - d.prev_sent) / d.rate_t
		d.prev_captured, d.prev_sent = d.captured, v.sent
		for _, &t in d.talkers {
			t.rate = f32(t.packets - t.prev) / d.rate_t
			t.prev = t.packets
		}
		d.rate_t = 0
	}
	d.log_t += dt
	if d.log_t >= LOG_PERIOD {
		d.log_t = 0
		diag_log_status(a)
	}
}
//@endregion

//@region 结论
// 正在使用的实际设备名：选“系统默认”时也解析出默认设备是谁。
voice_actual_device :: proc(dev_stream: ^sdl3.AudioStream) -> string {
	if dev_stream == nil do return "(not open)"
	name := sdl3.GetAudioDeviceName(sdl3.GetAudioStreamDevice(dev_stream))
	if name == nil do return "(unknown)"
	return ascii_device_name(string(name))
}

talker_name :: proc(a: ^App, id: objects.Network_Id) -> string {
	if obj, ok := objects.get(&a.client_reg, id); ok {
		if p := objects.component_data(obj, Player, PLAYER_TYPE); p != nil do return slot_name(p.slot)
	}
	return fmt.tprintf("#%d", id)
}

voice_verdicts :: proc(a: ^App) -> [dynamic]Verdict {
	v := &a.voice
	d := &v.diag
	out := make([dynamic]Verdict, context.temp_allocator)
	if !v.ready {
		append(&out, Verdict{v.status != "" ? v.status : "voice is off", 2})
		return out
	}
	mic := v.test_tone ? "voicetest tone" : voice_actual_device(v.mic.stream)
	switch {
	case !v.has_mic:
		append(&out, Verdict{"No microphone could be opened - you can only listen. Press M to try another one.", 1})
	case d.capture_rate < 40:
		append(&out, Verdict{fmt.tprintf("Microphone '%s' delivers only %.0f frames/s (expected 50).", mic, d.capture_rate), 2})
	case d.mic_avg < 0.0003 && !v.test_tone:
		append(&out, Verdict{fmt.tprintf("Your mic '%s' is (nearly) silent - speak and watch the level; M switches mic, or raise its Windows input volume.", mic), 2})
	case:
		append(&out, Verdict{fmt.tprintf("Your microphone '%s' picks up sound.", mic), 0})
	}
	if v.talking {
		append(&out, Verdict{fmt.tprintf("Sending your voice: %.0f frames/s.", d.send_rate), 0})
	} else {
		append(&out, Verdict{"Not sending - hold V to talk.", 1})
	}
	output := voice_actual_device(v.speaker.stream)
	if len(d.talkers) == 0 {
		append(&out, Verdict{"No voice received yet - ask the other player to hold V.", 1})
	}
	for id, t in d.talkers {
		name := talker_name(a, id)
		age := d.clock - t.last_rx
		switch {
		case age > 2:
			append(&out, Verdict{fmt.tprintf("%s: last voice %.0f s ago.", name, age), 1})
		case t.level < 0.0005:
			append(&out, Verdict{fmt.tprintf("%s: voice arrives (%.0f packets/s) but is SILENT - their microphone does not pick up sound.", name, t.rate), 2})
		case:
			append(&out, Verdict{fmt.tprintf("%s: playing their voice (level %.3f) on '%s'. Hear nothing? That output is wrong: T plays a test beep, O switches.", name, t.level, output), 0})
		}
	}
	return out
}
//@endregion

//@region 日志
diag_open_log :: proc(v: ^Voice) {
	exe_dir := filepath.dir(os.args[0])
	v.diag.log_path = strings.concatenate({exe_dir, "/net_fps_voice.log"})
	f, err := os.create(v.diag.log_path)
	if err != nil do return
	v.diag.log = f
}

diag_close :: proc(v: ^Voice) {
	diag_write(v, "log closed")
	if v.diag.log != nil do os.close(v.diag.log)
	delete(v.diag.log_path)
	delete(v.diag.talkers)
	delete(v.diag.last_verdict)
	v.diag.log = nil
}

diag_write :: proc(v: ^Voice, line: string) {
	d := &v.diag
	if d.log == nil || d.log_lines >= LOG_MAX_LINES do return
	os.write_string(d.log, fmt.tprintf("[%7.1fs] %s\n", d.clock, line))
	d.log_lines += 1
}

diag_log_startup :: proc(v: ^Voice) {
	now := time.now()
	y, mo, day := time.date(now)
	h, mi, s := time.clock(now)
	diag_write(v, fmt.tprintf("net_fps voice log  %04d-%02d-%02d %02d:%02d:%02d (UTC)  args: %v", y, int(mo), day, h, mi, s, os.args[1:]))
	env := os.get_env_alloc("SDL_AUDIODRIVER", context.temp_allocator)
	driver := sdl3.GetCurrentAudioDriver()
	diag_write(v, fmt.tprintf("audio driver: %s   SDL_AUDIODRIVER env: '%s'   opus: %v   rnnoise: %v", driver != nil ? string(driver) : "(none)", env, v.opus.library != nil, v.has_rnnoise))
	if !v.ready {
		diag_write(v, fmt.tprintf("VOICE OFF: %s", v.status))
		return
	}
	diag_write(v, fmt.tprintf("microphone in use: %s   output in use: %s", v.test_tone ? "voicetest tone" : voice_actual_device(v.mic.stream), voice_actual_device(v.speaker.stream)))
	for n in v.rec_names do diag_write(v, fmt.tprintf("  recording device: %s", n))
	for n in v.play_names do diag_write(v, fmt.tprintf("  playback device:  %s", n))
}

diag_log_status :: proc(a: ^App) {
	v := &a.voice
	d := &v.diag
	if !v.ready do return
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "mic='%s' level=%.4f captured=%.0f/s talking=%v sent=%.0f/s | out='%s' queued=%dms peak=%.3f",
		v.test_tone ? "tone" : voice_actual_device(v.mic.stream), d.mic_avg, d.capture_rate, v.talking, d.send_rate,
		voice_actual_device(v.speaker.stream), voice_queued_ms(v), v.peak)
	for id, t in d.talkers {
		under := 0
		buffer := 0
		if r, ok := v.receivers[id]; ok {
			under = r.underruns
			buffer = voice_receiver_buffer(r)
		}
		fmt.sbprintf(&b, " | %s: %.0f pk/s last=%.1fs empty=%d level=%.4f buf=%dms underruns=%d",
			talker_name(a, id), t.rate, d.clock - t.last_rx, t.empty, t.level, buffer, under)
	}
	diag_write(v, strings.to_string(b))
	verdict := strings.builder_make(context.temp_allocator)
	for line in voice_verdicts(a) do fmt.sbprintf(&verdict, "%s ", line.text)
	// 比较时去掉数字：电平、包速每次都变，只在结论本身变化时记一行。
	key := strings.builder_make(context.temp_allocator)
	for c in strings.to_string(verdict) do if c < '0' || c > '9' do strings.write_rune(&key, c)
	if text := strings.to_string(key); text != d.last_verdict {
		delete(d.last_verdict)
		d.last_verdict = strings.clone(text)
		diag_write(v, fmt.tprintf("VERDICT: %s", strings.to_string(verdict)))
	}
}

voice_receiver_buffer :: proc(r: ^voicelib.Voice_Receiver) -> int {
	return voicelib.voice_receiver_buffer_ms(r)
}

voice_queued_ms :: proc(v: ^Voice) -> int {
	if v.speaker.stream == nil do return 0
	return int(sdl3.GetAudioStreamQueued(v.speaker.stream)) / (2 * size_of(f32)) * 1000 / v.config.sample_rate
}
//@endregion

//@region F1 面板
draw_voice_diag :: proc(a: ^App, w, h, ui: f32) {
	v := &a.view
	b := &v.ui
	vo := &a.voice
	d := &vo.diag
	verdicts := voice_verdicts(a)
	lines := make([dynamic]string, context.temp_allocator)
	if vo.ready {
		driver := sdl3.GetCurrentAudioDriver()
		append(&lines, fmt.tprintf("driver %s   opus ok   rnnoise %v", driver != nil ? string(driver) : "?", vo.has_rnnoise))
		append(&lines, fmt.tprintf("MIC  %s   level %.4f   captured %.0f/s   %s %.0f/s",
			vo.test_tone ? "voicetest tone" : voice_actual_device(vo.mic.stream), d.mic_avg, d.capture_rate,
			vo.talking ? "SENDING" : "idle", d.send_rate))
		append(&lines, fmt.tprintf("OUT  %s   queued %d ms   test beeps %d", voice_actual_device(vo.speaker.stream), voice_queued_ms(vo), d.beeps))
		for id, t in d.talkers {
			buffer, under := 0, 0
			if r, ok := vo.receivers[id]; ok do buffer, under = voice_receiver_buffer(r), r.underruns
			append(&lines, fmt.tprintf("IN   %s   %.0f packets/s   last %.1f s   decoded level %.4f   buffer %d ms   underruns %d",
				talker_name(a, id), t.rate, d.clock - t.last_rx, t.level, buffer, under))
		}
	}
	line_h := 22 * ui
	panel := foster.Rect{w / 2 - 430 * ui, 96 * ui, 860 * ui, (70 + f32(len(lines) + len(verdicts)) * 22 + 20) * ui}
	round_rect(b, panel, 14 * ui, fade(foster.Color{8, 10, 20, 255}, 0.9))
	x := panel.X + 22 * ui
	y := panel.Y + 14 * ui
	text(v, "VOICE DIAGNOSTICS   (F1 close   T test beep   M mic   O output   L hear yourself)", {x, y}, 15 * ui, NEON)
	y += 30 * ui
	for line in lines {
		text(v, line, {x, y}, 15 * ui, WHITE)
		y += line_h
	}
	y += 8 * ui
	for verdict in verdicts {
		color := verdict.level == 0 ? foster.Color{105, 219, 124, 255} : verdict.level == 1 ? GOLD : DANGER
		r2d.circle(b, foster.Vec2{x + 5 * ui, y + 9 * ui}, 4 * ui, 10, color)
		text(v, verdict.text, {x + 16 * ui, y}, 15 * ui, color)
		y += line_h
	}
	text(v, fmt.tprintf("log: %s", d.log_path != "" ? d.log_path : "(not written)"), {x, y + 4 * ui}, 13 * ui, DIM)
}
//@endregion
