#+build windows
package main

import p "../platform"
import "base:intrinsics"
import "base:runtime"
import "core:c/libc"
import "core:dynlib"
import "core:fmt"
import os "core:os"
import "core:strings"
import win "core:sys/windows"
import xa2 "vendor:windows/XAudio2"

foreign import avrt "system:Avrt.lib"

@(default_calling_convention = "stdcall")
foreign avrt {
	AvSetMmThreadCharacteristicsW :: proc(TaskName: win.LPCWSTR, TaskIndex: win.LPDWORD) -> win.HANDLE ---
	AvRevertMmThreadCharacteristics :: proc(AvrtHandle: win.HANDLE) -> win.BOOL ---
}


LONG :: win.LONG
INT :: win.INT
WORD :: win.WORD
DWORD :: win.DWORD
SHORT :: win.SHORT
LARGE_INTEGER :: win.LARGE_INTEGER
WIN32_UINT32 :: win.UINT32
DOUBLE :: f64

CLASS_NAME :: "HandmadeHeroWindowClass"

// TODO(Kevin): This is a global for now
RUNNING: bool = false
perf_counter_frequency: LARGE_INTEGER

Kilobytes :: #force_inline proc(value: u64) -> u64 {return value * 1024}
Megabytes :: #force_inline proc(value: u64) -> u64 {return Kilobytes(value) * 1024}
Gigabytes :: #force_inline proc(value: u64) -> u64 {return Megabytes(value) * 1024}
Terabytes :: #force_inline proc(value: u64) -> u64 {return Gigabytes(value) * 1024}


// XAudio2
NUM_BUFFER :: 3
CHANNELS :: 2

Win32_Sound_Output :: struct {
	samples_per_second:       DWORD,
	bytes_per_sample:         INT,
	channels:                 WORD,
	target_seconds_per_frame: f32,
	frame_latency:            WORD,
}

Win32_Audio_Resources :: struct {
	xaudio2:         ^xa2.IXAudio2,
	mastering_voice: ^xa2.IXAudio2MasteringVoice,
	source_voice:    ^xa2.IXAudio2SourceVoice,
	sound_buffer:    [NUM_BUFFER][^]i16,
	size_in_bytes:   u32,
	sample_count:    u32,
}

// Video
Win32_Offscreen_Buffer :: struct {
	info:            win.BITMAPINFO,
	memory:          rawptr,
	width:           LONG,
	height:          LONG,
	bytes_per_pixel: INT,
}

bitmap_buffer := Win32_Offscreen_Buffer{}

win32_get_window_dimensions :: proc "stdcall" (window: win.HWND) -> (width: INT, height: INT) {
	rect: win.RECT
	win.GetClientRect(window, &rect)
	height = rect.bottom - rect.top
	width = rect.right - rect.left
	return
}

win32_resize_dib_section :: proc "stdcall" (
	buffer: ^Win32_Offscreen_Buffer,
	width: LONG,
	height: LONG,
) {
	if buffer.memory != nil {
		win.VirtualFree(buffer.memory, 0, win.MEM_RELEASE)
	}

	buffer.width = width
	buffer.height = height
	buffer.bytes_per_pixel = 4

	buffer.info.bmiHeader.biSize = size_of(buffer.info.bmiHeader)
	buffer.info.bmiHeader.biWidth = width
	// If biHeight is negative, the bitmap is a top-down DIB width
	// the origin at the upper left corner.
	buffer.info.bmiHeader.biHeight = -height
	buffer.info.bmiHeader.biPlanes = 1
	buffer.info.bmiHeader.biBitCount = 32
	buffer.info.bmiHeader.biCompression = win.BI_RGB

	bitmap_memory_size := (width * height) * buffer.bytes_per_pixel
	buffer.memory = win.VirtualAlloc(
		nil,
		cast(win.SIZE_T)bitmap_memory_size,
		win.MEM_COMMIT,
		win.PAGE_READWRITE,
	)
}

win32_copy_buffer_to_window :: proc "stdcall" (
	device_context: win.HDC,
	buffer: ^Win32_Offscreen_Buffer,
	x: INT,
	y: INT,
	window_width: INT,
	window_height: INT,
) {
	win.StretchDIBits(
		device_context,
		x,
		y,
		window_width,
		window_height,
		x,
		y,
		buffer.width,
		buffer.height,
		buffer.memory,
		&buffer.info,
		win.DIB_RGB_COLORS,
		win.SRCCOPY,
	)
}


win32_init_xaudio2 :: proc(soundout: Win32_Sound_Output) -> Win32_Audio_Resources {
	audio_resources := Win32_Audio_Resources{}

	xaudio2: ^xa2.IXAudio2
	hresult := xa2.Create(&xaudio2, {}, xa2.USE_DEFAULT_PROCESSOR)

	if win.FAILED(
		hresult,
	) {win.OutputDebugStringA("Failed to init XAudio2"); return audio_resources}

	p_xaudio2_mastering_voice: ^xa2.IXAudio2MasteringVoice

	hresult = xaudio2.CreateMasteringVoice(xaudio2, &p_xaudio2_mastering_voice)

	if win.FAILED(
		hresult,
	) {win.OutputDebugStringA("Failed to init IXAudio2MasteringVoice"); return audio_resources}

	wave_format: win.WAVEFORMATEX
	wave_format.wFormatTag = win.WAVE_FORMAT_PCM
	wave_format.nChannels = soundout.channels
	wave_format.nSamplesPerSec = soundout.samples_per_second
	wave_format.nBlockAlign = wave_format.nChannels * cast(WORD)soundout.bytes_per_sample
	wave_format.nAvgBytesPerSec = wave_format.nSamplesPerSec * DWORD(wave_format.nBlockAlign)
	wave_format.wBitsPerSample = cast(WORD)soundout.bytes_per_sample * 8
	wave_format.cbSize = 0

	p_xaudio2_source_voice: ^xa2.IXAudio2SourceVoice

	hresult = xaudio2.CreateSourceVoice(
		xaudio2,
		&p_xaudio2_source_voice,
		&wave_format,
		{},
		xa2.DEFAULT_FREQ_RATIO,
	)

	if win.FAILED(
		hresult,
	) {win.OutputDebugStringA("Failed to init IXAudio2SourceVoice"); return audio_resources}

	// 33.33 ms / frame
	// 44,100 samples / s
	// 44.1 samples / ms
	// 33.3 * 44.1 = 1470 samples / frame
	// 1470 samples / frame * 2 (latency) = 3000 samples per frame

	ms_per_frame := 1000 * soundout.target_seconds_per_frame
	samples_per_ms := f32(soundout.samples_per_second) / 1000
	samples_per_frame := samples_per_ms * ms_per_frame * f32(soundout.frame_latency)

	size_in_bytes :=
		u32(samples_per_frame) * u32(soundout.bytes_per_sample) * u32(soundout.channels)

	total_size := size_in_bytes * NUM_BUFFER
	raw := win.VirtualAlloc(
		nil,
		cast(win.SIZE_T)total_size,
		win.MEM_COMMIT | win.MEM_RESERVE,
		win.PAGE_READWRITE,
	)

	sound_buffer: [NUM_BUFFER][^]i16
	for i in 0 ..< NUM_BUFFER {
		offset := cast(uintptr)(u32(i) * size_in_bytes)
		sound_buffer[i] = cast([^]i16)(cast(uintptr)raw + offset)
	}


	return Win32_Audio_Resources {
		xaudio2 = xaudio2,
		mastering_voice = p_xaudio2_mastering_voice,
		source_voice = p_xaudio2_source_voice,
		sound_buffer = sound_buffer,
		size_in_bytes = size_in_bytes,
		sample_count = u32(samples_per_frame),
	}
}

win32_submit_sound_buffer :: proc(
	audio: ^Win32_Audio_Resources,
	game_sound_buffer: ^p.Game_Sound_Buffer,
) {
	xaudio2_buffer: xa2.BUFFER
	xaudio2_buffer.AudioBytes = audio.size_in_bytes
	xaudio2_buffer.Flags = {xa2.FLAG.END_OF_STREAM}
	xaudio2_buffer.pAudioData = cast([^]u8)game_sound_buffer.samples

	hresult := audio.source_voice->SubmitSourceBuffer(&xaudio2_buffer)
	if win.FAILED(hresult) {win.OutputDebugStringA("SubmitSourceBuffer failed\n")}
}

win32_destroy_audio_resources :: proc(audio_resources: ^Win32_Audio_Resources) {
	audio_resources.source_voice.DestroyVoice(audio_resources.source_voice)
	audio_resources.mastering_voice.DestroyVoice(audio_resources.mastering_voice)
	audio_resources.xaudio2.Release(audio_resources.xaudio2)
	win.VirtualFree(&audio_resources.sound_buffer, 0, win.MEM_RELEASE)
}

win32_process_xinput_digital_button :: proc(
	old_button_state: ^p.Game_Button_State,
	new_button_state: ^p.Game_Button_State,
	is_down: bool,
) {
	new_button_state.half_transition_count = old_button_state.ended_down != is_down ? 1 : 0
	new_button_state.ended_down = is_down
}

win32_process_xinput_stick :: proc(stick_value: win.SHORT, deadzone_value: win.SHORT) -> f32 {
	result: f32 = 0.0
	if stick_value < -deadzone_value {
		result = cast(f32)stick_value / -32_768.

	} else if stick_value > deadzone_value {
		result = cast(f32)stick_value / 32_767.
	}
	return result
}

win32_process_keyboard_message :: proc(button_state: ^p.Game_Button_State, is_down: bool) {
	button_state.half_transition_count += 1
	button_state.ended_down = is_down
}

win32_handle_gamepad :: proc(old_input: ^p.Game_Input, new_input: ^p.Game_Input) {
	for idx: DWORD = 0; idx < win.XUSER_MAX_COUNT; idx += 1 {
		state: win.XINPUT_STATE
		result := win.XInputGetState(cast(win.XUSER)idx, &state)
		old_controller := &old_input.controllers[idx + 1]
		new_controller := &new_input.controllers[idx + 1]
		if cast(DWORD)result == win.ERROR_SUCCESS {
			pad := state.Gamepad

			new_controller.is_connected = true
			new_controller.is_analog = true

			threshold: f32 = 0.5

			move_up := .DPAD_UP in pad.wButtons
			move_down := .DPAD_DOWN in pad.wButtons
			move_left := .DPAD_LEFT in pad.wButtons
			move_right := .DPAD_RIGHT in pad.wButtons

			if move_up {
				new_controller.stick_average_y = 1.0
			}
			if move_right {
				new_controller.stick_average_x = 1.0
			}
			if move_down {
				new_controller.stick_average_y = -1.0
			}
			if move_left {
				new_controller.stick_average_x = -1.0
			}

			win32_process_xinput_digital_button(
				&old_controller.move_up,
				&new_controller.move_up,
				new_controller.stick_average_y > threshold,
			)
			win32_process_xinput_digital_button(
				&old_controller.move_down,
				&new_controller.move_down,
				new_controller.stick_average_y < -threshold,
			)
			win32_process_xinput_digital_button(
				&old_controller.move_left,
				&new_controller.move_left,
				new_controller.stick_average_x < -threshold,
			)
			win32_process_xinput_digital_button(
				&old_controller.move_right,
				&new_controller.move_right,
				new_controller.stick_average_x > threshold,
			)
			start := .START in pad.wButtons
			win32_process_xinput_digital_button(
				&old_controller.start,
				&new_controller.start,
				start,
			)
			back := .BACK in pad.wButtons
			win32_process_xinput_digital_button(&old_controller.back, &new_controller.back, back)
			lshoulder := .LEFT_SHOULDER in pad.wButtons
			win32_process_xinput_digital_button(
				&old_controller.left_shoulder,
				&new_controller.left_shoulder,
				lshoulder,
			)
			rshoulder := .RIGHT_SHOULDER in pad.wButtons
			win32_process_xinput_digital_button(
				&old_controller.right_shoulder,
				&new_controller.right_shoulder,
				rshoulder,
			)
			a_button := .A in pad.wButtons
			win32_process_xinput_digital_button(
				&old_controller.action_down,
				&new_controller.action_down,
				a_button,
			)
			b_button := .B in pad.wButtons
			win32_process_xinput_digital_button(
				&old_controller.action_right,
				&new_controller.action_right,
				b_button,
			)
			x_button := .X in pad.wButtons
			win32_process_xinput_digital_button(
				&old_controller.action_left,
				&new_controller.action_left,
				x_button,
			)
			y_button := .Y in pad.wButtons
			win32_process_xinput_digital_button(
				&old_controller.action_up,
				&new_controller.action_up,
				y_button,
			)

			new_controller.stick_average_x = win32_process_xinput_stick(
				pad.sThumbLX,
				win.XINPUT_GAMEPAD_LEFT_THUMB_DEADZONE,
			)
			new_controller.stick_average_y = win32_process_xinput_stick(
				pad.sThumbLY,
				win.XINPUT_GAMEPAD_LEFT_THUMB_DEADZONE,
			)
		} else {
			new_controller.is_connected = false
		}
	}
}

win32_process_pending_messages :: proc(new_controller: ^p.Game_Controller_Input) {
	msg: win.MSG
	for win.PeekMessageW(&msg, nil, 0, 0, win.PM_REMOVE) {
		if msg.message == win.WM_QUIT do RUNNING = false
		switch msg.message {
		case win.WM_KEYDOWN, win.WM_KEYUP, win.WM_SYSKEYUP, win.WM_SYSKEYDOWN:
			vk_code := win.LOWORD(msg.wParam)
			key_flags := win.HIWORD(msg.lParam)
			alt_key_down := (key_flags & win.KF_ALTDOWN) == win.KF_ALTDOWN
			was_down := (msg.lParam & (1 << 30)) != 0
			is_down := (msg.lParam & (1 << 31)) == 0
			if was_down != is_down {
				switch (vk_code) {
				case win.VK_LEFT:
					win32_process_keyboard_message(&new_controller.action_left, is_down)
				case win.VK_RIGHT:
					win32_process_keyboard_message(&new_controller.action_right, is_down)
				case win.VK_UP:
					win32_process_keyboard_message(&new_controller.action_up, is_down)
				case win.VK_DOWN:
					win32_process_keyboard_message(&new_controller.action_down, is_down)
				case win.VK_F4:
					if alt_key_down do RUNNING = false
				case win.VK_SPACE:
				case win.VK_ESCAPE:
				case 'W':
					win32_process_keyboard_message(&new_controller.move_up, is_down)
				case 'A':
					win32_process_keyboard_message(&new_controller.move_left, is_down)
				case 'S':
					win32_process_keyboard_message(&new_controller.move_down, is_down)
				case 'D':
					win32_process_keyboard_message(&new_controller.move_right, is_down)
				case 'Q':
					win32_process_keyboard_message(&new_controller.left_shoulder, is_down)
				case 'E':
					win32_process_keyboard_message(&new_controller.right_shoulder, is_down)
				case:
					break

				}
			}
		case:
			win.TranslateMessage(&msg)
			win.DispatchMessageW(&msg)
		}
	}
}

win32_main_window_callback :: proc "stdcall" (
	window: win.HWND,
	msg: win.UINT,
	wparam: win.WPARAM,
	lparam: win.LPARAM,
) -> win.LRESULT {
	result := 0
	switch (msg) {
	case win.WM_DESTROY:
		win.OutputDebugStringA("WM_DESTROY\n")
		RUNNING = false
	case win.WM_CLOSE:
		win.OutputDebugStringA("WM_CLOSE\n")
		RUNNING = false
	case win.WM_SIZE:
		win.OutputDebugStringA("WM_SIZE\n")
	case win.WM_PAINT:
		p: win.PAINTSTRUCT
		hdc := win.BeginPaint(window, &p)
		window_width, window_height := win32_get_window_dimensions(window)
		win32_copy_buffer_to_window(hdc, &bitmap_buffer, 0, 0, window_width, window_height)
		win.EndPaint(window, &p)
	case win.WM_ACTIVATEAPP:
		win.OutputDebugStringA("WM_ACTIVATEAPP\n")
	case:
		result = win.DefWindowProcW(window, msg, wparam, lparam)
	}
	return result
}

win32_get_wall_clock :: #force_inline proc() -> LARGE_INTEGER {
	result: LARGE_INTEGER
	win.QueryPerformanceCounter(&result)
	return result
}

win32_get_seconds_elapsed :: #force_inline proc(start: LARGE_INTEGER, end: LARGE_INTEGER) -> f32 {
	diff := cast(f32)(end - start)
	return diff / cast(f32)perf_counter_frequency
}

Game_API :: struct {
	lib:               dynlib.Library,
	update_and_render: proc(
		game_memory: ^p.Game_Memory,
		game_sound: ^p.Game_Sound_Buffer,
		game_offscreen_buffer: ^p.Game_Offscreen_Buffer,
		game_input: ^p.Game_Input,
	),
	force_reload:      proc() -> bool,
	force_restart:     proc() -> bool,
	modification_time: win.FILETIME,
	api_version:       int,
}


copy_dll :: proc(to: string) -> bool {
	exit := libc.system(fmt.ctprintf("copy game.dll {0}", to))
	if exit != 0 {
		fmt.printfln("Failed to copy game.dll to {0}", to)
		return false
	}
	return true
}

load_game_api :: proc(api_version: int) -> (api: Game_API, ok: bool) {
	mod_time := win32_get_last_write_time("game.dll")
	game_dll_name := fmt.tprintf("game_{0}.dll", api_version)
	copy_dll(game_dll_name)
	_, ok = dynlib.initialize_symbols(&api, game_dll_name, "", "lib")
	if !ok {
		fmt.printfln("Failed initializing symbols: {0}", dynlib.last_error())
		ok = false
		return
	}
	api.api_version = api_version
	api.modification_time = mod_time
	ok = true
	return
}

unload_game_api :: proc(api: ^Game_API) -> bool {
	if api.lib != nil {
		if !dynlib.unload_library(api.lib) {
			fmt.printfln("Failed unloading lib: {0}", dynlib.last_error())
			return false
		}
	}

	if os.remove(fmt.tprintf("game_{0}.dll", api.api_version)) != nil {
		fmt.printfln("Failed to remove game_{0}.dll copy", api.api_version)
		return false
	}
	return true
}

win32_get_last_write_time :: proc(filename: string) -> win.FILETIME {
	LastWriteTime: win.FILETIME

	FindData: win.WIN32_FIND_DATAW
	FindHandle := win.FindFirstFileW(win.utf8_to_wstring(filename), &FindData)
	if (FindHandle != win.INVALID_HANDLE_VALUE) {
		LastWriteTime = FindData.ftLastWriteTime
		win.FindClose(FindHandle)
	}

	return LastWriteTime
}


main :: proc() {
	instance := win.HINSTANCE(win.GetModuleHandleW(nil))
	assert(instance != nil, "Failed to fetch hInstance.")

	task_idx: u32 = 0
	mmrt_handle := AvSetMmThreadCharacteristicsW("Games", &task_idx)

	sleep_is_granular := win.timeBeginPeriod(1) == win.TIMERR_NOERROR

	win.QueryPerformanceFrequency(&perf_counter_frequency)

	lp_cmd_line := win.GetCommandLineW()

	cls := win.WNDCLASSW {
		style         = win.CS_OWNDC | win.CS_HREDRAW | win.CS_VREDRAW,
		lpszClassName = CLASS_NAME,
		lpfnWndProc   = win32_main_window_callback,
		hInstance     = instance,
	}
	class := win.RegisterClassW(&cls)
	assert(class != 0, "Class creation failed")

	window := win.CreateWindowExW(
		0,
		CLASS_NAME,
		win.L("Handmade Hero"),
		win.WS_OVERLAPPEDWINDOW | win.WS_VISIBLE,
		win.CW_USEDEFAULT,
		win.CW_USEDEFAULT,
		win.CW_USEDEFAULT,
		win.CW_USEDEFAULT,
		nil,
		nil,
		instance,
		nil,
	)

	assert(window != nil, "Window creation Failed")

	base_address: win.LPVOID = nil
	when p.HANDMADE_INTERNAL {
		base_address = cast(rawptr)cast(uintptr)Terabytes(2)
	}

	permanent_storage_size := Megabytes(64)
	transient_storage_size := Gigabytes(1)
	total_size := permanent_storage_size + transient_storage_size


	base := cast(uintptr)win.VirtualAlloc(
		base_address,
		cast(win.SIZE_T)total_size,
		win.MEM_COMMIT | win.MEM_RESERVE,
		win.PAGE_READWRITE,
	)

	permanent_storage := cast(rawptr)base
	transient_storage := cast(rawptr)(base + cast(uintptr)permanent_storage_size)

	assert(permanent_storage != nil, "Permanent storage failed to allocate.")
	assert(transient_storage != nil, "Transient storage failed to allocate.")

	memory := p.Game_Memory {
		permanent_storage_size = permanent_storage_size,
		permanent_storage      = permanent_storage,
		transient_storage_size = transient_storage_size,
		transient_storage      = transient_storage,
		is_initialized         = false,
	}

	// Graphics
	win32_resize_dib_section(&bitmap_buffer, 1280, 720)

	// Sound
	hr := win.CoInitializeEx(nil, .MULTITHREADED)
	assert(win.SUCCEEDED(hr), "CoInitializeEx failed")


	msg: win.MSG

	device_context := win.GetDC(window)

	last_cycle_count: i64 = intrinsics.read_cycle_counter()

	dm: win.DEVMODEW
	dm.dmSize = size_of(win.DEVMODEW)
	win.EnumDisplaySettingsW(nil, win.ENUM_CURRENT_SETTINGS, &dm)
	monitor_refresh_hz := dm.dmDisplayFrequency
	game_update_hz := monitor_refresh_hz / 2
	target_seconds_per_frame := 1.0 / cast(f32)game_update_hz

	soundout := Win32_Sound_Output {
		samples_per_second       = 44_100,
		bytes_per_sample         = size_of(i16),
		channels                 = CHANNELS,
		frame_latency            = 1,
		target_seconds_per_frame = target_seconds_per_frame,
	}


	current_sound_buffer := 0
	audio_resources := win32_init_xaudio2(soundout)

	game_api_version := 0
	game_api, game_api_ok := load_game_api(game_api_version)

	if !game_api_ok {
		fmt.println("Failed to load Game API")
		return
	}

	game_api_version += 1

	RUNNING = true
	new_input := p.Game_Input{}
	old_input := p.Game_Input{}

	last_counter := win32_get_wall_clock()
	for RUNNING {
		reload := false
		last_file_write_time := win32_get_last_write_time("game.dll")

		if win.CompareFileTime(&last_file_write_time, &game_api.modification_time) != 0 {
			reload = true
		}

		if reload {
			new_game_api, new_game_api_ok := load_game_api(game_api_version)
			if new_game_api_ok {
				game_api = new_game_api
				game_api_version += 1
			}
		}

		old_keyboard_controller := old_input.controllers[0]
		new_input.controllers[0] = p.Game_Controller_Input{}
		new_keyboard_controller := &new_input.controllers[0]
		for i in 0 ..< len(old_keyboard_controller.buttons) {
			new_keyboard_controller.buttons[i] = old_keyboard_controller.buttons[i]
		}
		new_keyboard_controller.is_connected = true

		win32_process_pending_messages(new_keyboard_controller)
		win32_handle_gamepad(&old_input, &new_input)

		game_offscreen_buffer := p.Game_Offscreen_Buffer {
			width           = bitmap_buffer.width,
			height          = bitmap_buffer.height,
			memory          = bitmap_buffer.memory,
			bytes_per_pixel = bitmap_buffer.bytes_per_pixel,
		}

		state: xa2.VOICE_STATE
		audio_resources.source_voice->GetState(&state)
		if state.BuffersQueued < NUM_BUFFER {
			game_sound_buffer := p.Game_Sound_Buffer {
				sample_count       = cast(int)audio_resources.sample_count,
				samples            = audio_resources.sound_buffer[current_sound_buffer % NUM_BUFFER],
				samples_per_second = cast(int)soundout.samples_per_second,
			}
			current_sound_buffer += 1
			game_api.update_and_render(
				&memory,
				&game_sound_buffer,
				&game_offscreen_buffer,
				&new_input,
			)
			win32_submit_sound_buffer(&audio_resources, &game_sound_buffer)
		} else {
			game_sound_buffer := p.Game_Sound_Buffer{}
			game_api.update_and_render(
				&memory,
				&game_sound_buffer,
				&game_offscreen_buffer,
				&new_input,
			)
		}


		// TODO(kevin): Need to clean this up a bit. If the buffer starves we need to
		// restart.
		if current_sound_buffer == 1 {
			audio_resources.source_voice->Start()
		}

		temp_input := new_input
		new_input = old_input
		old_input = temp_input

		work_counter := win32_get_wall_clock()
		work_seconds_elapsed := win32_get_seconds_elapsed(last_counter, work_counter)

		seconds_elapsed_for_frame := work_seconds_elapsed
		if seconds_elapsed_for_frame < target_seconds_per_frame {
			sleep_ms := cast(DWORD)(1000.0 *
				(target_seconds_per_frame - seconds_elapsed_for_frame))
			sleep_ms -= 1
			if sleep_is_granular && sleep_ms > 0 {
				win.Sleep(sleep_ms)
			}
			test_counter := win32_get_wall_clock()
			test_seconds_elapsed_for_frame := win32_get_seconds_elapsed(last_counter, test_counter)
			for seconds_elapsed_for_frame < target_seconds_per_frame {
				seconds_elapsed_for_frame = win32_get_seconds_elapsed(
					last_counter,
					win32_get_wall_clock(),
				)
			}
		} else {
			win.OutputDebugStringA("Missed frame.\n")
		}

		// Timing
		end_counter := win32_get_wall_clock()
		ms_per_frame := win32_get_seconds_elapsed(last_counter, end_counter) * 1000
		last_counter = end_counter
		frames_per_sec := 1000.0 / ms_per_frame

		// Profile
		end_cycle_count: i64 = intrinsics.read_cycle_counter()
		cycles_elapsed := end_cycle_count - last_cycle_count
		mega_cycle_count := cast(f32)cycles_elapsed / (1000.0 * 1000.0)
		last_cycle_count = end_cycle_count

		window_width, window_height := win32_get_window_dimensions(window)
		win32_copy_buffer_to_window(
			device_context,
			&bitmap_buffer,
			0,
			0,
			window_width,
			window_height,
		)

		Buff: [256]byte
		dbg_str := strings.clone_to_cstring(
			fmt.bprintfln(
				Buff[:],
				"%.02f f/s | %.02f ms/f | %.02f mc | %.02f GHz",
				frames_per_sec,
				ms_per_frame,
				mega_cycle_count,
				(frames_per_sec * mega_cycle_count) / 1000.0,
			),
		)
		win.OutputDebugStringA(dbg_str)
	}

	if mmrt_handle != nil {
		AvRevertMmThreadCharacteristics(mmrt_handle)
	}

	win.timeEndPeriod(1)
	win32_destroy_audio_resources(&audio_resources)
	win.CoUninitialize()
	// TODO(kevin): msg is uninitialized
	os.exit(cast(int)msg.wParam)
}
