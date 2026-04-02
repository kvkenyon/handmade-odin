#+build windows
package game

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:mem"
import os "core:os"
import "core:strings"
import win "core:sys/windows"
import xa2 "vendor:windows/XAudio2"

HANDMADE_INTERNAL :: #config(HANDMADE_INTERNAL, false)

LONG :: win.LONG
INT :: win.INT
WORD :: win.WORD
DWORD :: win.DWORD
LARGE_INTEGER :: win.LARGE_INTEGER
WIN32_UINT32 :: win.UINT32
DOUBLE :: f64

CLASS_NAME :: "HandmadeHeroWindowClass"

// TODO(Kevin): This is a global for now
RUNNING: bool = false

Kilobytes :: #force_inline proc(value: u64) -> u64 {return value * 1024}
Megabytes :: #force_inline proc(value: u64) -> u64 {return Kilobytes(value) * 1024}
Gigabytes :: #force_inline proc(value: u64) -> u64 {return Megabytes(value) * 1024}
Terabytes :: #force_inline proc(value: u64) -> u64 {return Gigabytes(value) * 1024}

// File I/O

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
				if (win.ReadFile(handle, result.contents, cast(u32)file_size, &read_bytes, nil) &&
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
	hresult := xa2.Create(&xaudio2, {xa2.FLAGS.DEBUG_ENGINE}, xa2.USE_DEFAULT_PROCESSOR)

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

win32_handle_gamepad :: proc(old_input: ^Game_Input, new_input: ^Game_Input) {
	for idx: DWORD = 0; idx < win.XUSER_MAX_COUNT; idx += 1 {
		state: win.XINPUT_STATE
		result := win.XInputGetState(cast(win.XUSER)idx, &state)
		old_controller := &old_input.controllers[idx]
		new_controller := &new_input.controllers[idx]
		if cast(DWORD)result == win.ERROR_SUCCESS {
			// TODO(kevin): Assuming only 1 gamepad. Otherwise we could have errors with
			// this flag turning off.
			win.OutputDebugStringA("Controller found.\n")
			pad := state.Gamepad

			new_input.is_analog = true
			up := .DPAD_UP in pad.wButtons
			down := .DPAD_DOWN in pad.wButtons
			left := .DPAD_LEFT in pad.wButtons
			right := .DPAD_RIGHT in pad.wButtons
			start := .START in pad.wButtons
			back := .BACK in pad.wButtons

			lshoulder := .LEFT_SHOULDER in pad.wButtons
			win32_process_xinput_digital_button(
				&old_controller.states.left_shoulder,
				&new_controller.states.left_shoulder,
				lshoulder,
			)
			rshoulder := .RIGHT_SHOULDER in pad.wButtons
			win32_process_xinput_digital_button(
				&old_controller.states.right_shoulder,
				&new_controller.states.right_shoulder,
				rshoulder,
			)
			a_button := .A in pad.wButtons
			win32_process_xinput_digital_button(
				&old_controller.states.down,
				&new_controller.states.down,
				a_button,
			)
			b_button := .B in pad.wButtons
			win32_process_xinput_digital_button(
				&old_controller.states.right,
				&new_controller.states.right,
				b_button,
			)
			x_button := .X in pad.wButtons
			win32_process_xinput_digital_button(
				&old_controller.states.left,
				&new_controller.states.left,
				x_button,
			)
			y_button := .Y in pad.wButtons
			win32_process_xinput_digital_button(
				&old_controller.states.up,
				&new_controller.states.up,
				y_button,
			)

			stick_x := pad.sThumbLX
			stick_y := pad.sThumbLY

			max_i16: f32 = 32_767.
			min_i16: f32 = -32_768.

			x := cast(f32)stick_x
			y := cast(f32)stick_y

			x = x < 0 ? x / min_i16 : x / max_i16
			y = y < 0 ? -y / min_i16 : y / max_i16

			new_controller.start_x = old_controller.end_x
			new_controller.end_x = x
			new_controller.start_y = old_controller.end_y
			new_controller.end_y = y
			new_controller.min_x = x
			new_controller.min_y = y

			break
		} else {
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
	case win.WM_SYSKEYUP:
		fallthrough
	case win.WM_SYSKEYDOWN:
		fallthrough
	case win.WM_KEYUP:
		fallthrough
	case win.WM_KEYDOWN:
		vk_code := win.LOWORD(wparam)
		key_flags := win.HIWORD(lparam)
		was_key_down := (key_flags & win.KF_REPEAT) == win.KF_REPEAT
		is_key_released := (key_flags & win.KF_UP) == win.KF_UP
		alt_key_down := (key_flags & win.KF_ALTDOWN) == win.KF_ALTDOWN
		repeat_count := win.LOWORD(lparam)
		switch (vk_code) {
		case win.VK_LEFT:
		case win.VK_RIGHT:
		case win.VK_UP:
		case win.VK_DOWN:
		case win.VK_F4:
			if alt_key_down do RUNNING = false
		case win.VK_SPACE:
		case win.VK_ESCAPE:
		case 'W':
		case 'A':
		case 'S':
		case 'D':
		case 'Q':
		case 'E':
		case:
			break
		}
	case:
		result = win.DefWindowProcW(window, msg, wparam, lparam)
	}

	return result
}

main :: proc() {
	instance := win.HINSTANCE(win.GetModuleHandleW(nil))
	assert(instance != nil, "Failed to fetch hInstance.")

	perf_counter_frequency: LARGE_INTEGER
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
	transient_storage_size := Gigabytes(4)
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

	// NOTE(kevin): We can remove this, using it to confirm that we get the memory
	// Windows doesn't seem to give you the memory until you write to the buffer.
	mem.set(permanent_storage, 0, cast(int)permanent_storage_size)
	mem.set(transient_storage, 0, cast(int)transient_storage_size)

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

	last_counter: LARGE_INTEGER
	win.QueryPerformanceCounter(&last_counter)

	last_cycle_count: i64 = intrinsics.read_cycle_counter()

	RUNNING = true
	new_input := Game_Input{}
	old_input := Game_Input{}
	for RUNNING {
		for win.PeekMessageW(&msg, nil, 0, 0, win.PM_REMOVE) {
			if msg.message == win.WM_QUIT do RUNNING = false
			win.TranslateMessage(&msg)
			win.DispatchMessageW(&msg)
		}

		win32_handle_gamepad(&old_input, &new_input)

		state: xa2.VOICE_STATE
		audio_resources.source_voice.GetState(audio_resources.source_voice, &state)

		for state.BuffersQueued < NUM_BUFFER {
			sub_buffer := cast([^]i16)audio_resources.sound_buffer
			sub_buffer = sub_buffer[current_sound_buffer *
			cast(int)soundout.samples_per_second *
			CHANNELS:]

			game_sound_buffer := Game_Sound_Buffer {
				sample_count       = cast(int)soundout.samples_per_second,
				samples            = sub_buffer,
				samples_per_second = cast(int)soundout.samples_per_second,
			}

			game_output_sound(&game_sound_buffer)
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

		update_and_render(&memory, &game_offscreen_buffer, &new_input)

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
		new_input := old_input
		old_input := temp_input

		end_counter: LARGE_INTEGER
		win.QueryPerformanceCounter(&end_counter)
		end_cycle_count: i64 = intrinsics.read_cycle_counter()

		counter_elapsed := (end_counter - last_counter) * 1000
		cycles_elapsed := end_cycle_count - last_cycle_count

		ms_per_frame := cast(f32)counter_elapsed / cast(f32)perf_counter_frequency
		frames_per_sec := 1000.0 / ms_per_frame
		mega_cycle_count := cast(f32)cycles_elapsed / (1000.0 * 1000.0)


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

		last_cycle_count = end_cycle_count
		last_counter = end_counter

	}

	win32_destroy_audio_resources(&audio_resources)
	win.CoUninitialize()

	os.exit(cast(int)msg.wParam)
}
