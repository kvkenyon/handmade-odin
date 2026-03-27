package main

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:math"
import os "core:os"
import "core:strings"
import win "core:sys/windows"
import "game"
import xa2 "vendor:windows/XAudio2"

LONG :: win.LONG
INT :: win.INT
WORD :: win.WORD
DWORD :: win.DWORD
LARGE_INTEGER :: win.LARGE_INTEGER
WIN32_UINT32 :: win.UINT32
DOUBLE :: f64

CLASS_NAME :: "HandmadeHeroWindowClass"

// XAudio2
PI: DOUBLE : 3.14159265358979323846
xaudio2: ^xa2.IXAudio2
sound_buffer: [^]byte

Win32_Sound_Output :: struct {
	samples_per_second: DWORD,
	tone_hz:            DOUBLE,
	tone_volume:        DOUBLE,
	bytes_per_sample:   INT,
	bits_per_sample:    WORD,
	size_in_cycles:     INT,
	channels:           WORD,
}

// Input
has_gamepad := true
x_offset: INT = 0
y_offset: INT = 0

// TODO(Kevin): This is a global for now
RUNNING: bool = false

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

win32_init_xaudio2 :: proc(soundout: Win32_Sound_Output) {
	hresult := xa2.Create(&xaudio2, {xa2.FLAGS.DEBUG_ENGINE}, xa2.USE_DEFAULT_PROCESSOR)
	if win.FAILED(hresult) {win.OutputDebugStringA("Failed to init XAudio2"); return}

	p_xaudio2_mastering_voice: ^xa2.IXAudio2MasteringVoice

	hresult = xaudio2.CreateMasteringVoice(xaudio2, &p_xaudio2_mastering_voice)
	if win.FAILED(
		hresult,
	) {win.OutputDebugStringA("Failed to init IXAudio2MasteringVoice"); return}

	wave_format: win.WAVEFORMATEX
	wave_format.wFormatTag = win.WAVE_FORMAT_PCM
	wave_format.nChannels = soundout.channels
	wave_format.nSamplesPerSec = soundout.samples_per_second
	wave_format.nBlockAlign = wave_format.nChannels * soundout.bits_per_sample / 8
	wave_format.nAvgBytesPerSec = wave_format.nSamplesPerSec * DWORD(wave_format.nBlockAlign)
	wave_format.wBitsPerSample = soundout.bits_per_sample
	wave_format.cbSize = 0

	p_xaudio2_source_voice: ^xa2.IXAudio2SourceVoice

	hresult = xaudio2.CreateSourceVoice(xaudio2, &p_xaudio2_source_voice, &wave_format)
	if win.FAILED(hresult) {win.OutputDebugStringA("Failed to init IXAudio2SourceVoice"); return}

	// 44_100 Samples Per Second
	// 220.0 Hz (full sin cycles per second)
	// ~200 samples per cycle
	samples_per_cycle := INT(f64(soundout.samples_per_second) / soundout.tone_hz)
	// Pre-compute 10 (size_in_cycles) cycles of Sin.
	size_in_samples := soundout.size_in_cycles * samples_per_cycle * cast(INT)soundout.channels
	size_in_bytes := size_in_samples * soundout.bytes_per_sample

	// TODO(kevin): Eventually we should factor this buffer soundout
	// so we can send aribitrary waves to it. Just using the Sin as a test timezone
	// for now.
	sound_buffer = cast([^]byte)win.VirtualAlloc(
		nil,
		cast(win.SIZE_T)size_in_bytes,
		win.MEM_COMMIT,
		win.PAGE_READWRITE,
	)

	phase: DOUBLE = 0.0
	buffer_index: u32 = 0
	for buffer_index < cast(u32)size_in_bytes {
		phase += (2.0 * PI) / cast(DOUBLE)samples_per_cycle
		sample := i16(math.sin(phase) * 32767.0 * soundout.tone_volume)

		// Channel 1
		sound_buffer[buffer_index] = byte(sample & 0xFF)
		buffer_index += 1
		sound_buffer[buffer_index] = byte((sample >> 8) & 0xFF)
		buffer_index += 1

		// Channel 2
		sound_buffer[buffer_index] = byte(sample & 0xFF)
		buffer_index += 1
		sound_buffer[buffer_index] = byte((sample >> 8) & 0xFF)
		buffer_index += 1

	}

	xaudio2_buffer: xa2.BUFFER
	xaudio2_buffer.Flags = {}
	xaudio2_buffer.AudioBytes = cast(u32)size_in_bytes
	xaudio2_buffer.pAudioData = sound_buffer
	xaudio2_buffer.LoopCount = xa2.LOOP_INFINITE

	hresult = p_xaudio2_source_voice.SubmitSourceBuffer(
		p_xaudio2_source_voice,
		&xaudio2_buffer,
		nil,
	)
	if win.FAILED(hresult) {win.OutputDebugStringA("SubmitSourceBuffer failed\n"); return}

	hresult = p_xaudio2_source_voice.Start(p_xaudio2_source_voice, {}, xa2.COMMIT_NOW)
	if win.FAILED(hresult) {win.OutputDebugStringA("Start failed\n"); return}
}

win32_handle_gamepad :: proc(x_offset: ^i32, y_offset: ^i32) {
	for idx: DWORD = 0; idx < win.XUSER_MAX_COUNT; idx += 1 {
		state: win.XINPUT_STATE
		result := win.XInputGetState(cast(win.XUSER)idx, &state)
		if cast(DWORD)result == win.ERROR_SUCCESS {
			// TODO(kevin): Assuming only 1 gamepad. Otherwise we could have errors with
			// this flag turning off.
			has_gamepad = true
			win.OutputDebugStringA("Controller found.\n")
			pad := state.Gamepad
			up := .DPAD_UP in pad.wButtons
			down := .DPAD_DOWN in pad.wButtons
			left := .DPAD_LEFT in pad.wButtons
			right := .DPAD_RIGHT in pad.wButtons
			start := .START in pad.wButtons
			back := .BACK in pad.wButtons
			lshoulder := .LEFT_SHOULDER in pad.wButtons
			rshoulder := .RIGHT_SHOULDER in pad.wButtons
			a_button := .A in pad.wButtons
			b_button := .B in pad.wButtons
			x_button := .X in pad.wButtons
			y_button := .Y in pad.wButtons
			stick_x := pad.sThumbLX
			stick_y := pad.sThumbLY

			x_offset^ += i32(stick_x / 4096)
			y_offset^ += i32(stick_y / 4096)
			break
		} else {
			// TODO(Kevin): Keyboard instead?
			// Flip a flag that makes use use keyboard input instead.
			has_gamepad = false
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
			if !has_gamepad do y_offset -= 1
		case 'A':
			if !has_gamepad do x_offset -= 1
		case 'S':
			if !has_gamepad do y_offset += 1
		case 'D':
			if !has_gamepad do x_offset += 1
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

	lpCmdLine := win.GetCommandLineW()

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

	hr := win.CoInitializeEx(nil, .MULTITHREADED)
	assert(win.SUCCEEDED(hr), "CoInitializeEx failed")

	soundout := Win32_Sound_Output {
		tone_hz            = 220.0,
		tone_volume        = 0.5,
		channels           = 2,
		size_in_cycles     = 10,
		samples_per_second = 44_100,
		bytes_per_sample   = 2,
		bits_per_sample    = 16,
	}

	win32_init_xaudio2(soundout)
	win32_resize_dib_section(&bitmap_buffer, 1280, 720)

	msg: win.MSG

	last_counter: LARGE_INTEGER
	win.QueryPerformanceCounter(&last_counter)

	last_cycle_count: i64 = intrinsics.read_cycle_counter()

	RUNNING = true
	for RUNNING {

		for win.PeekMessageW(&msg, nil, 0, 0, win.PM_REMOVE) {
			if msg.message == win.WM_QUIT do RUNNING = false
			win.TranslateMessage(&msg)
			win.DispatchMessageW(&msg)
		}

		win32_handle_gamepad(&x_offset, &y_offset)

		game_offscreen_buffer := game.Game_Offscreen_Buffer {
			width           = bitmap_buffer.width,
			height          = bitmap_buffer.height,
			memory          = bitmap_buffer.memory,
			bytes_per_pixel = bitmap_buffer.bytes_per_pixel,
		}

		game.update_and_render(&game_offscreen_buffer, x_offset, y_offset)

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

	// Release XAudio2 resources
	win.VirtualFree(&sound_buffer, 0, win.MEM_RELEASE)
	win.CoUninitialize()
	xaudio2.Release(xaudio2)

	os.exit(cast(int)msg.wParam)
}
