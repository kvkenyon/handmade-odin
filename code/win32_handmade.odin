package main

import "base:runtime"
import os "core:os"
import win "core:sys/windows"


LONG :: win.LONG
INT :: win.INT

CLASS_NAME :: "HandmadeHeroWindowClass"

// TODO(Kevin): This is a global for now
RUNNING: bool = false

Win32OffscreenBuffer :: struct {
	info:            win.BITMAPINFO,
	memory:          rawptr,
	width:           LONG,
	height:          LONG,
	bytes_per_pixel: INT,
}


bitmap_buffer := Win32OffscreenBuffer{}

win32_get_window_dimensions :: proc "stdcall" (window: win.HWND) -> (width: INT, height: INT) {
	rect: win.RECT
	win.GetClientRect(window, &rect)
	height = rect.bottom - rect.top
	width = rect.right - rect.left
	return
}

render_gradient :: proc "std" (buffer: ^Win32OffscreenBuffer, x_offset: INT, y_offset: INT) {
	bitmap_memory32 := cast([^]u32)buffer.memory
	for y in 0 ..< buffer.height {
		row_idx := y * buffer.width
		offset := row_idx + buffer.width
		row := bitmap_memory32[row_idx:offset]
		for x in 0 ..< buffer.width {
			// 0x00RRGGBB
			blue := cast(u32)(x_offset + x)
			green := cast(u32)(y_offset + y) << 8
			row[x] = blue | green
		}
	}
}

win32_resize_dib_section :: proc "stdcall" (
	buffer: ^Win32OffscreenBuffer,
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
	// If biHeight is negative, the bitmap is a top-down DIB with the origin at the upper left corner.
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
	buffer: ^Win32OffscreenBuffer,
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

main :: proc() {
	instance := win.HINSTANCE(win.GetModuleHandleW(nil))
	assert(instance != nil, "Failed to fetch hInstance.")

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

	win32_resize_dib_section(&bitmap_buffer, 1280, 720)

	msg: win.MSG

	x_offset: INT = 0
	y_offset: INT = 0
	RUNNING = true
	for RUNNING {
		for win.PeekMessageW(&msg, nil, 0, 0, win.PM_REMOVE) {
			if msg.message == win.WM_QUIT do RUNNING = false
			win.TranslateMessage(&msg)
			win.DispatchMessageW(&msg)
		}

		render_gradient(&bitmap_buffer, x_offset, y_offset)

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
		x_offset += 1
		y_offset += 1
	}

	os.exit(cast(int)msg.wParam)
}
