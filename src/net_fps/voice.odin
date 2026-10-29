package main

import "core:math"
import "core:math/linalg"
import "core:strings"

import audio "olib:kit/audio"
import "olib:thirdparty/onet/core"
import "olib:thirdparty/onet/objects"
import "olib:thirdparty/onet/rpc"
import voicelib "olib:thirdparty/voice"
import sdl3 "vendor:sdl3"

// ==============================================================================
// 语音：按住 V 说话。麦克风 → RNNoise（可选）→ Opus → 不可靠 RPC 经服务器转发；
// 每个说话人一个 Voice_Receiver（抖动缓冲 + 丢包补偿），按距离与方位混成立体声。
// opus.dll 缺失时整块关闭，游戏照常。
// ==============================================================================

RPC_VOICE :: rpc.Id(4) // 客户端 → 服务器 → 其他人：[帧序号 u32, 发送时间 f64, Opus 包]
VOICE_TAIL_FRAMES :: 3  // 松开后补发的静音帧，让接收端干净收尾
PLAYBACK_LEAD :: f32(0.06) // 回放流里保持的提前量（秒）
CAPTURE_MAX_FRAMES :: 8 // 采集积压上限，菜单停留等造成的旧样本直接丢掉

Voice :: struct {
	ready:        bool,
	status:       string, // 不可用时给 HUD 的原因
	opus:         voicelib.Opus_Library,
	rnnoise:      voicelib.Rnnoise_Library,
	has_rnnoise:  bool,
	config:       voicelib.Config,
	audio_ready:  bool,
	speaker:      audio.Audio_Device,
	mic:          audio.Audio_Device,
	has_mic:      bool,
	sender:       voicelib.Voice_Sender,
	sender_ready: bool,
	capture:      [dynamic]f32,
	read_buf:     [dynamic]f32,
	talking:      bool,
	tail:         int,
	level:        f32, // 最近一帧麦克风 RMS，HUD 电平
	receivers:    map[objects.Network_Id]^voicelib.Voice_Receiver,
	mono, mix:    [dynamic]f32,
	// voicetest：用正弦音代替麦克风并一直发送，验证整条链路
	test_tone:    bool,
	tone_phase:   f32,
	tone_carry:   f32,
	sent, received: int,
	peak:         f32, // 写进回放流的最大幅度（诊断用）
	// 设备选择：-1 为系统默认。虚拟声卡（Steam、远程桌面）常被设成默认，所以允许在游戏里切换。
	rec_ids, play_ids:     [dynamic]sdl3.AudioDeviceID,
	rec_names, play_names: [dynamic]string,
	mic_choice, out_choice: int,
	mic_level:    f32, // 不论是否说话都更新的麦克风电平
	silent_time:  f32, // 按住说话但麦克风一直是 0 的时长
	monitor:      bool, // L：把麦克风直接放到当前输出，一个人也能检查麦克风和扬声器
	open_mic:     bool, // openmic：不按 V 也一直发送
	mic_pick, out_pick: string, // 命令行 mic / out：按名称片段选设备
	notice:       string,
	notice_time:  f32,
	diag:         Voice_Diag, // F1 诊断面板与 net_fps_voice.log，见 voice_diag.odin
}

Voice_Packet :: struct {
	index:     int,
	timestamp: f64,
	data:      []u8,
}

voice_init :: proc(v: ^Voice, a: ^App) {
	diag_open_log(v)
	defer diag_log_startup(v)
	v.config = voicelib.config_default()
	if !voicelib.config_init(&v.config) {
		v.status = "voice off: bad config"
		return
	}
	if !voicelib.opus_load(&v.opus) {
		v.status = "voice off: opus.dll not found"
		return
	}
	v.has_rnnoise = voicelib.rnnoise_load(&v.rnnoise)
	if !audio.audio_init() {
		v.status = "voice off: no audio subsystem"
		return
	}
	v.audio_ready = true
	voice_list_devices(v)
	v.mic_choice = voice_find_device(v.rec_names, v.mic_pick)
	v.out_choice = voice_find_device(v.play_names, v.out_pick)
	out_id := v.out_choice < 0 ? 0 : v.play_ids[v.out_choice]
	if !voice_open(&v.speaker, out_id, false) {
		v.status = "voice off: no playback device"
		return
	}
	// 没有麦克风也能听别人说话。
	mic_id := v.mic_choice < 0 ? 0 : v.rec_ids[v.mic_choice]
	v.has_mic = voice_open(&v.mic, mic_id, true) || v.test_tone
	rn := v.has_rnnoise ? &v.rnnoise : nil
	v.sender_ready = voicelib.voice_sender_init(&v.sender, &v.config, &v.opus, rn, voicelib.OPUS_MAX_PACKET_BYTES, voice_relay, a)
	if !v.has_mic do v.status = "no microphone - listening only"
	v.ready = true
}

voice_shutdown :: proc(v: ^Voice) {
	voice_reset(v)
	delete(v.receivers)
	delete(v.capture)
	delete(v.read_buf)
	delete(v.mono)
	delete(v.mix)
	if v.sender_ready do voicelib.voice_sender_dispose(&v.sender)
	audio.audio_device_close(&v.mic)
	audio.audio_device_close(&v.speaker)
	for n in v.rec_names do delete(n)
	for n in v.play_names do delete(n)
	delete(v.rec_names)
	delete(v.play_names)
	delete(v.rec_ids)
	delete(v.play_ids)
	if v.audio_ready do audio.audio_shutdown()
	if v.has_rnnoise do voicelib.rnnoise_dispose(&v.rnnoise)
	voicelib.opus_dispose(&v.opus)
	diag_close(v)
}

// 离开一局：释放所有说话人的接收器。
voice_reset :: proc(v: ^Voice) {
	for _, r in v.receivers {
		voicelib.voice_receiver_dispose(r)
		free(r)
	}
	clear(&v.receivers)
	clear(&v.capture)
	clear(&v.diag.talkers)
	v.talking, v.tail = false, 0
}

voice_speaking :: proc(v: ^Voice, id: objects.Network_Id) -> bool {
	r, ok := v.receivers[id]
	return ok && voicelib.voice_receiver_is_speaking(r)
}

// 每帧：取麦克风样本按 20 ms 切帧发送，再给回放流补足提前量。
voice_update :: proc(a: ^App, dt: f32, talk: bool) {
	v := &a.voice
	v.diag.clock += dt
	if !v.ready do return
	spf := v.config.samples_per_frame
	my_id, _ := local_player(a)

	if v.test_tone {
		// 440 Hz 正弦，按真实时间产生样本。
		v.tone_carry += dt * f32(v.config.sample_rate)
		n := int(v.tone_carry)
		v.tone_carry -= f32(n)
		for _ in 0 ..< n {
			append(&v.capture, 0.25 * math.sin(v.tone_phase))
			v.tone_phase = math.mod(v.tone_phase + math.TAU * 440 / f32(v.config.sample_rate), math.TAU)
		}
	} else if v.has_mic {
		avail := audio.audio_device_available_samples(&v.mic)
		if avail > 0 {
			resize(&v.read_buf, avail)
			got := audio.audio_device_read(&v.mic, v.read_buf[:])
			append(&v.capture, ..v.read_buf[:got])
		}
	}
	if extra := len(v.capture) - CAPTURE_MAX_FRAMES * spf; extra > 0 {
		remove_range(&v.capture, 0, extra)
	}
	v.talking = (talk || v.test_tone || v.open_mic) && my_id != 0 && v.sender_ready && v.has_mic
	for len(v.capture) >= spf {
		frame := v.capture[:spf]
		v.diag.captured += 1
		sum: f32
		for s in frame do sum += s * s
		v.mic_level = math.sqrt(sum / f32(spf))
		v.level = v.mic_level
		// 真实麦克风总有底噪；按住说话时持续为 0 说明设备被静音、被隐私设置拦截或选错了设备。
		if v.talking && v.mic_level == 0 && !v.test_tone {
			v.silent_time += v.config.seconds_per_frame
		} else if v.mic_level > 0 {
			v.silent_time = 0
		}
		if v.monitor && len(v.receivers) == 0 {
			// 自监听：单声道帧复制到左右声道直接入队（有人说话时由正常混音负责，避免两路写同一条流）。
			resize(&v.mix, spf * 2)
			for s, i in frame {
				v.mix[i * 2], v.mix[i * 2 + 1] = s, s
			}
			sdl3.PutAudioStreamData(v.speaker.stream, raw_data(v.mix), i32(len(v.mix) * size_of(f32)))
		}
		if v.talking {
			voicelib.voice_sender_send(&v.sender, frame)
			v.tail = VOICE_TAIL_FRAMES
		} else if v.tail > 0 && my_id != 0 && v.sender_ready {
			voicelib.voice_sender_send(&v.sender, nil)
			v.tail -= 1
		}
		remove_range(&v.capture, 0, spf)
	}
	if !v.talking do v.level *= 0.8
	v.notice_time = max(0, v.notice_time - dt)

	// 说话人离开后释放接收器。
	gone := make([dynamic]objects.Network_Id, context.temp_allocator)
	for id in v.receivers {
		if _, ok := objects.get(&a.client_reg, id); !ok do append(&gone, id)
	}
	for id in gone {
		voicelib.voice_receiver_dispose(v.receivers[id])
		free(v.receivers[id])
		delete_key(&v.receivers, id)
		delete_key(&v.diag.talkers, id)
	}
	voice_playback(a)
	diag_tick(a, dt)
}

// 回放流排队量低于提前量时，从每个说话人拉同样多的样本，按距离衰减、按方位做等功率声像后混合。
voice_playback :: proc(a: ^App) {
	v := &a.voice
	if len(v.receivers) == 0 do return
	queued := int(sdl3.GetAudioStreamQueued(v.speaker.stream)) / (2 * size_of(f32))
	need := int(PLAYBACK_LEAD * f32(v.config.sample_rate)) - queued
	if need <= 0 do return
	resize(&v.mono, need)
	resize(&v.mix, need * 2)
	for &s in v.mix do s = 0
	eye, yaw, _, _ := camera_pose(a)
	right := [2]f32{math.cos(yaw), -math.sin(yaw)}
	for id, r in v.receivers {
		voicelib.voice_receiver_pull(r, v.mono[:])
		diag_decoded(v, id, v.mono[:])
		gain, pan := f32(1), f32(0)
		if remote, ok := a.view.remotes[id]; ok {
			d := remote.pos + {0, EYE_HEIGHT, 0} - eye
			dist := linalg.length(d)
			gain = clamp(1.25 - dist / 35, 0.3, 1)
			if flat := linalg.length(d.xz); flat > 0.01 {
				pan = clamp(linalg.dot(d.xz / flat, right), -1, 1) * 0.8
			}
		}
		theta := (pan + 1) * math.PI / 4
		gl, gr := gain * math.cos(theta) * 1.4, gain * math.sin(theta) * 1.4
		for s, i in v.mono {
			v.mix[i * 2] += s * gl
			v.mix[i * 2 + 1] += s * gr
		}
	}
	for &s in v.mix {
		s = clamp(s, -1, 1)
		v.peak = max(v.peak, abs(s))
	}
	sdl3.PutAudioStreamData(v.speaker.stream, raw_data(v.mix), i32(len(v.mix) * size_of(f32)))
}

// Voice_Sender 的出口：静音帧 data 为空。走不可靠通道，丢了由接收端补偿。
voice_relay :: proc(index: int, timestamp: f64, data: []u8, user: rawptr) {
	a := cast(^App)user
	id, _ := local_player(a)
	if id == 0 do return
	packet := Voice_Packet{index, timestamp, data}
	if rpc.send_with(&a.runtime.client.rpc, RPC_VOICE, id, .Observers, write_voice, &packet, channel = .Unreliable) {
		a.voice.sent += 1
	}
}

write_voice :: proc(w: ^core.Writer, user: rawptr) {
	p := cast(^Voice_Packet)user
	core.write_uint32(w, u32(p.index), .Uncompressed)
	core.write_raw_double(w, p.timestamp)
	core.write_u8_array_with_count(w, p.data, .Loose)
}

// 服务器只负责转发（handler 在路由时也会被调用一次，直接返回）；客户端按说话人对象入缓冲。
on_voice :: proc(ctx: ^rpc.Context, payload: []u8) {
	if ctx.manager.authority || ctx.object == nil do return
	a := cast(^App)ctx.manager.userdata
	v := &a.voice
	if !v.ready do return
	r := rpc.reader(payload)
	index := int(core.read_uint32(&r, .Uncompressed))
	timestamp := core.read_raw_double(&r, 0)
	data := core.read_u8_array_with_count(&r, .Loose)
	defer delete(data)
	if r.err != .None do return
	receiver, ok := v.receivers[ctx.object.id]
	if !ok {
		receiver = new(voicelib.Voice_Receiver)
		if !voicelib.voice_receiver_init(receiver, &v.config, &v.opus) {
			free(receiver)
			return
		}
		v.receivers[ctx.object.id] = receiver
	}
	voicelib.voice_receiver_receive(receiver, index, timestamp, data)
	v.received += 1
	diag_packet(v, ctx.object.id, len(data) == 0)
}

//@region 设备选择
// kit/audio 目前只打开系统默认设备；指定设备时按同样的 F32 / 48 kHz 流格式自己打开，
// 仍填进 Audio_Device，读取、关闭照旧走 kit/audio。id 为 0 时用默认设备。
voice_open :: proc(dev: ^audio.Audio_Device, id: sdl3.AudioDeviceID, recording: bool) -> bool {
	channels := recording ? 1 : 2
	if id == 0 {
		return recording ? audio.audio_device_open_recording(dev, channels) : audio.audio_device_open(dev, channels)
	}
	desired := sdl3.AudioSpec{format = .F32, channels = i32(channels), freq = audio.AUDIO_DEVICE_SAMPLE_RATE}
	stream := sdl3.OpenAudioDeviceStream(id, &desired, nil, nil)
	if stream == nil do return false
	app_spec, device_spec: sdl3.AudioSpec
	format_ok := recording ? sdl3.GetAudioStreamFormat(stream, nil, &app_spec) : sdl3.GetAudioStreamFormat(stream, &app_spec, nil)
	if !format_ok || !sdl3.GetAudioDeviceFormat(sdl3.GetAudioStreamDevice(stream), &device_spec, nil) ||
	   !sdl3.ResumeAudioStreamDevice(stream) {
		sdl3.DestroyAudioStream(stream)
		return false
	}
	dev^ = {stream = stream, spec = device_spec, input_spec = app_spec, is_recording = recording}
	return true
}

voice_list_devices :: proc(v: ^Voice) {
	count: i32
	if ids := sdl3.GetAudioRecordingDevices(&count); ids != nil {
		for i in 0 ..< int(count) {
			append(&v.rec_ids, ids[i])
			append(&v.rec_names, strings.clone(string(sdl3.GetAudioDeviceName(ids[i]))))
		}
		sdl3.free(ids)
	}
	if ids := sdl3.GetAudioPlaybackDevices(&count); ids != nil {
		for i in 0 ..< int(count) {
			append(&v.play_ids, ids[i])
			append(&v.play_names, strings.clone(string(sdl3.GetAudioDeviceName(ids[i]))))
		}
		sdl3.free(ids)
	}
}

voice_device_name :: proc(names: [dynamic]string, choice: int) -> string {
	if choice < 0 || choice >= len(names) do return "system default"
	return ascii_device_name(names[choice])
}

// HUD 字体只有 ASCII：Windows 设备名形如“麦克风 (USB MIC Device)”，含非 ASCII 时取括号里的部分。
ascii_device_name :: proc(name: string) -> string {
	for c in name {
		if c < 128 do continue
		open := strings.index_byte(name, '(')
		close := strings.last_index_byte(name, ')')
		if open >= 0 && close > open + 1 do return name[open + 1:close]
		break
	}
	return name
}

// 名称片段（不区分大小写）找设备下标；空串或找不到返回 -1（系统默认）。
voice_find_device :: proc(names: [dynamic]string, key: string) -> int {
	if key == "" do return -1
	lower := strings.to_lower(key, context.temp_allocator)
	for name, i in names {
		if strings.contains(strings.to_lower(name, context.temp_allocator), lower) do return i
	}
	return -1
}

voice_toggle_monitor :: proc(v: ^Voice) {
	if !v.ready do return
	v.monitor = !v.monitor
	v.notice, v.notice_time = v.monitor ? "hearing your own mic (L to stop)" : "mic monitor off", 2.5
}

// M：默认 → 每个录音设备 → 默认。打不开的设备跳过。
voice_cycle_mic :: proc(v: ^Voice) {
	if !v.ready || v.test_tone do return
	for _ in 0 ..= len(v.rec_ids) {
		v.mic_choice = v.mic_choice + 1 >= len(v.rec_ids) ? -1 : v.mic_choice + 1
		audio.audio_device_close(&v.mic)
		clear(&v.capture)
		v.silent_time, v.mic_level = 0, 0
		id := v.mic_choice < 0 ? 0 : v.rec_ids[v.mic_choice]
		if v.has_mic = voice_open(&v.mic, id, true); v.has_mic do break
	}
	v.status = v.has_mic ? "" : "no microphone - listening only"
	v.notice, v.notice_time = voice_device_name(v.rec_names, v.mic_choice), 2.5
}

// O：默认 → 每个播放设备 → 默认。
voice_cycle_output :: proc(v: ^Voice) {
	if !v.ready do return
	for _ in 0 ..= len(v.play_ids) {
		v.out_choice = v.out_choice + 1 >= len(v.play_ids) ? -1 : v.out_choice + 1
		audio.audio_device_close(&v.speaker)
		id := v.out_choice < 0 ? 0 : v.play_ids[v.out_choice]
		if voice_open(&v.speaker, id, false) do break
	}
	v.notice, v.notice_time = voice_device_name(v.play_names, v.out_choice), 2.5
	voice_beep(v)
}

// 短促的提示音，听得到就说明当前输出设备是对的（O 切换后、诊断面板按 T）。
voice_beep :: proc(v: ^Voice) {
	if !v.ready || v.speaker.stream == nil do return
	beep: [48000 / 8 * 2]f32
	for i in 0 ..< len(beep) / 2 {
		t := f32(i) / 48000
		s := 0.12 * math.sin(math.TAU * 660 * t) * min(1, (0.125 - t) * 40)
		beep[i * 2], beep[i * 2 + 1] = s, s
	}
	sdl3.PutAudioStreamData(v.speaker.stream, &beep[0], i32(size_of(beep)))
	v.diag.beeps += 1
}
//@endregion
