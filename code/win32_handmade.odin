#+build windows
package game

import "base:intrinsics"
import "base:runtime"
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

HANDMADE_INTERNAL :: #config(HANDMADE_INTERNAL, false)

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

// DEBUG File I/O

when HANDMADE_INTERNAL {
	debug_platform_read_entire_file :: proc(filename: cstring16) -> Debug_Read_Result {
		result := Debug_Read_Result{}
		handle := win.CreateFileW(
			filename,
			win.GENERIC_READ,
			win.FILE_SHARE_READ,
			nil,
			win.OPEN_EXISTING,
			0,
			nil,
		)

		if handle != win.INVALID_HANDLE {
			file_size: win.LARGE_INTEGER
			if (win.GetFileSizeEx(handle, &file_size)) {
				result.contents = win.VirtualAlloc(
					nil,
					cast(uint)file_size,
					win.MEM_RESERVE | win.MEM_COMMIT,
					win.PAGE_READWRITE,
				)
				if result.contents != nil {
					read_bytes: DWORD
					if (win.ReadFile(
							   handle,
							   result.contents,
							   cast(u32)file_size,
							   &read_bytes,
							   nil,
						   ) &&
						   read_bytes == cast(u32)file_size) {
						result.contents_size = cast(u32)file_size
					} else {
						// TODO(kevin): logging
					}

				} else {
					// TODO(kevin): logging
				}

			} else {
				// TODO(kevin): logging
			}
			win.CloseHandle(handle)
		} else {
			// TODO(Kevin): logging
		}

		return result
	}

	debug_platform_write_entire_file :: proc(
		filename: cstring16,
		memory_size: DWORD,
		memory: rawptr,
	) -> bool {
		result := false
		handle := win.CreateFileW(filename, win.GENERIC_WRITE, 0, nil, win.CREATE_ALWAYS, 0, nil)

		if handle != win.INVALID_HANDLE {
			bytes_written: DWORD
			if win.WriteFile(handle, memory, memory_size, &bytes_written, nil) {
				result = bytes_written == memory_size
			} else {
				// TODO(kevin): logging
			}
			win.CloseHandle(handle)
		} else {
			// TODO(kevin): logging
		}

		return result
	}

	debug_platform_free_file_memory :: proc(memory: rawptr) {
		if memory != nil {
			win.VirtualFree(memory, 0, win.MEM_RELEASE)
		}
	}
}

// XAudio2

NUM_BUFFER :: 3
CHANNELS :: 2

Win32_Sound_Output :: struct {
	samples_per_second: DWORD,
	bytes_per_sample:   INT,
	channels:           WORD,
}

Win32_Audio_Resources :: struct {
	xaudio2:         ^xa2.IXAudio2,
	mastering_voice: ^xa2.IXAudio2MasteringVoice,
	source_voice:    ^xa2.IXAudio2SourceVoice,
	sound_buffer:    rawptr,
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

win32_clear_sound_buffer :: proc(buffer: [^]u16, buffer_size: int) {
	for i in 0 ..< buffer_size {
		buffer[i] = 0
	}
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

	size_in_bytes :=
		soundout.samples_per_second *
		cast(DWORD)soundout.bytes_per_sample *
		cast(DWORD)soundout.channels *
		NUM_BUFFER

	sound_buffer := cast([^]byte)win.VirtualAlloc(
		nil,
		cast(win.SIZE_T)size_in_bytes,
		win.MEM_COMMIT,
		win.PAGE_READWRITE,
	)

	win32_clear_sound_buffer(
		cast([^]u16)sound_buffer,
		cast(int)soundout.samples_per_second * CHANNELS * NUM_BUFFER,
	)

	hresult = p_xaudio2_source_voice.Start(p_xaudio2_source_voice, {}, 0)
	if win.FAILED(hresult) {win.OutputDebugStringA("Start failed\n"); return audio_resources}

	return Win32_Audio_Resources {
		xaudio2 = xaudio2,
		mastering_voice = p_xaudio2_mastering_voice,
		source_voice = p_xaudio2_source_voice,
		sound_buffer = sound_buffer,
	}
}

win32_destroy_audio_resources :: proc(audio_resources: ^Win32_Audio_Resources) {
	audio_resources.source_voice.DestroyVoice(audio_resources.source_voice)
	audio_resources.mastering_voice.DestroyVoice(audio_resources.mastering_voice)
	audio_resources.xaudio2.Release(audio_resources.xaudio2)
	win.VirtualFree(&audio_resources.sound_buffer, 0, win.MEM_RELEASE)
}

win32_process_xinput_digital_button :: proc(
	old_button_state: ^Game_Button_State,
	new_button_state: ^Game_Button_State,
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

win32_process_keyboard_message :: proc(button_state: ^Game_Button_State, is_down: bool) {
	button_state.half_transition_count += 1
	button_state.ended_down = is_down
}

win32_handle_gamepad :: proc(old_input: ^Game_Input, new_input: ^Game_Input) {
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

win32_process_pending_messages :: proc(new_controller: ^Game_Controller_Input) {
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

win32_get_wall_clock :: proc() -> LARGE_INTEGER {
	result: LARGE_INTEGER
	win.QueryPerformanceCounter(&result)
	return result
}

win32_get_seconds_elapsed :: proc(start: LARGE_INTEGER, end: LARGE_INTEGER) -> f32 {
	diff := cast(f32)(end - start)
	return diff / cast(f32)perf_counter_frequency
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
	when HANDMADE_INTERNAL {
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

	memory := Game_Memory {
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

	current_sound_buffer := 0

	soundout := Win32_Sound_Output {
		samples_per_second = 44_100,
		bytes_per_sample   = size_of(i16),
		channels           = CHANNELS,
	}

	size_in_bytes :=
		soundout.samples_per_second *
		cast(DWORD)soundout.bytes_per_sample *
		cast(DWORD)soundout.channels

	audio_resources := win32_init_xaudio2(soundout)

	msg: win.MSG


	last_cycle_count: i64 = intrinsics.read_cycle_counter()

	dm: win.DEVMODEW
	dm.dmSize = size_of(win.DEVMODEW)
	win.EnumDisplaySettingsW(nil, win.ENUM_CURRENT_SETTINGS, &dm)
	monitor_refresh_hz := dm.dmDisplayFrequency
	game_update_hz := monitor_refresh_hz / 2
	target_seconds_per_frame := 1.0 / cast(f32)game_update_hz

	RUNNING = true
	new_input := Game_Input{}
	old_input := Game_Input{}

	last_counter := win32_get_wall_clock()
	for RUNNING {
		old_keyboard_controller := old_input.controllers[0]
		new_input.controllers[0] = Game_Controller_Input{}
		new_keyboard_controller := &new_input.controllers[0]
		for i in 0 ..< len(old_keyboard_controller.buttons) {
			new_keyboard_controller.buttons[i] = old_keyboard_controller.buttons[i]
		}

		win32_process_pending_messages(new_keyboard_controller)
		win32_handle_gamepad(&old_input, &new_input)

		state: xa2.VOICE_STATE
		audio_resources.source_voice.GetState(audio_resources.source_voice, &state)

		// TODO(kevin): The audio timing is severly off. We are submitting buffers
		// too far into the future for the current frame. We need synchronization.
		game_sound_buffer: Game_Sound_Buffer
		if state.BuffersQueued < NUM_BUFFER {
			sub_buffer := cast([^]i16)audio_resources.sound_buffer
			sub_buffer = sub_buffer[current_sound_buffer *
			cast(int)soundout.samples_per_second *
			CHANNELS:]

			game_sound_buffer = Game_Sound_Buffer {
				sample_count       = cast(int)soundout.samples_per_second,
				samples            = sub_buffer,
				samples_per_second = cast(int)soundout.samples_per_second,
			}

			xaudio2_buffer: xa2.BUFFER
			xaudio2_buffer.AudioBytes = cast(u32)size_in_bytes
			xaudio2_buffer.pAudioData = cast([^]u8)sub_buffer

			hresult := audio_resources.source_voice.SubmitSourceBuffer(
				audio_resources.source_voice,
				&xaudio2_buffer,
			)
			if win.FAILED(hresult) {win.OutputDebugStringA("SubmitSourceBuffer failed\n")}
			audio_resources.source_voice.GetState(audio_resources.source_voice, &state)
			current_sound_buffer = (current_sound_buffer + 1) % NUM_BUFFER
		}

		game_offscreen_buffer := Game_Offscreen_Buffer {
			width           = bitmap_buffer.width,
			height          = bitmap_buffer.height,
			memory          = bitmap_buffer.memory,
			bytes_per_pixel = bitmap_buffer.bytes_per_pixel,
		}

		update_and_render(&memory, &game_sound_buffer, &game_offscreen_buffer, &new_input)

		device_context := win.GetDC(window)
		defer win.ReleaseDC(window, device_context)
		window_width, window_height := win32_get_window_dimensions(window)
		win32_copy_buffer_to_window(
			device_context,
			&bitmap_buffer,
			0,
			0,
			window_width,
			window_height,
		)

		temp_input := new_input
		new_input = old_input
		old_input = temp_input

		end_cycle_count: i64 = intrinsics.read_cycle_counter()
		cycles_elapsed := end_cycle_count - last_cycle_count
		mega_cycle_count := cast(f32)cycles_elapsed / (1000.0 * 1000.0)

		work_seconds_elapsed := win32_get_seconds_elapsed(last_counter, win32_get_wall_clock())
		seconds_elapsed_for_frame := work_seconds_elapsed
		if seconds_elapsed_for_frame < target_seconds_per_frame {
			for work_seconds_elapsed < target_seconds_per_frame {
				if sleep_is_granular {
					sleep_ms := (target_seconds_per_frame - work_seconds_elapsed) * 1000
					win.Sleep(cast(u32)sleep_ms)
				}
				work_seconds_elapsed = win32_get_seconds_elapsed(
					last_counter,
					win32_get_wall_clock(),
				)
			}
		}

		ms_per_frame := work_seconds_elapsed * 1000.0
		frames_per_sec := 1000.0 / ms_per_frame
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


		last_counter = win32_get_wall_clock()
		last_cycle_count = end_cycle_count
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
