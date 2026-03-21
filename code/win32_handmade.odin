package main

import "base:runtime"
import "core:fmt"
import os "core:os"
import win "core:sys/windows"

CLASS_NAME :: "HandmadeHeroWindowClass"

// TODO(Kevin): This is a global for now
RUNNING: bool = false

BYTES_PER_PIXEL: win.LONG : 4

LONG :: win.LONG
INT :: win.INT

bitmap_info: win.BITMAPINFO
bitmap_memory: rawptr
bitmap_width: LONG
bitmap_height: LONG

render_gradient :: proc "std" (x_offset: INT, y_offset: INT) {
	bitmap_memory32 := cast([^]u32)bitmap_memory
	for y in 0 ..< bitmap_height {
		row_idx := y * bitmap_width
		offset := row_idx + bitmap_width
		row := bitmap_memory32[row_idx:offset]
		for x in 0 ..< bitmap_width {
			// 0x00RRGGBB
			blue := cast(u32)(x_offset + x)
			green := cast(u32)(y_offset + y) << 8
			row[x] = blue | green
		}
	}
}

win32_resize_dib_section :: proc "stdcall" (width: LONG, height: LONG) {
	if bitmap_memory != nil {
		win.VirtualFree(bitmap_memory, 0, win.MEM_RELEASE)
	}

	bitmap_width = width
	bitmap_height = height

	bitmap_info.bmiHeader.biSize = size_of(bitmap_info.bmiHeader)
	bitmap_info.bmiHeader.biWidth = width
	// If biHeight is negative, the bitmap is a top-down DIB with the origin at the upper left corner.
	bitmap_info.bmiHeader.biHeight = -height
	bitmap_info.bmiHeader.biPlanes = 1
	bitmap_info.bmiHeader.biBitCount = 32
	bitmap_info.bmiHeader.biCompression = win.BI_RGB

	bitmap_memory_size := (width * height) * BYTES_PER_PIXEL

	bitmap_memory = win.VirtualAlloc(
		nil,
		cast(win.SIZE_T)bitmap_memory_size,
		win.MEM_COMMIT,
		win.PAGE_READWRITE,
	)
}

win32_update_window :: proc "stdcall" (
	device_context: win.HDC,
	client_rect: ^win.RECT,
	x: INT,
	y: INT,
	window_width: INT,
	window_height: INT,
) {
	win.StretchDIBits(
		device_context,
		x,
		y,
		bitmap_width,
		bitmap_height,
		x,
		y,
		window_width,
		window_height,
		bitmap_memory,
		&bitmap_info,
		win.DIB_RGB_COLORS,
		win.SRCCOPY,
	)
}


win32_main_window_callback :: proc "stdcall" (
	hwnd: win.HWND,
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
		rect: win.RECT
		win.GetClientRect(hwnd, &rect)
		height := rect.bottom - rect.top
		width := rect.right - rect.left
		win32_resize_dib_section(width, height)
		win.OutputDebugStringA("WM_SIZE\n")
	case win.WM_PAINT:
		p: win.PAINTSTRUCT
		hdc := win.BeginPaint(hwnd, &p)
		rect := p.rcPaint
		X := rect.left
		Y := rect.top
		height := rect.bottom - rect.top
		width := rect.right - rect.left
		win32_update_window(hdc, &rect, X, Y, width, height)
		win.EndPaint(hwnd, &p)
	case win.WM_ACTIVATEAPP:
		win.OutputDebugStringA("WM_ACTIVATEAPP\n")
	case:
		result = win.DefWindowProcW(hwnd, msg, wparam, lparam)
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

		render_gradient(x_offset, y_offset)

		device_context := win.GetDC(window)
		defer win.ReleaseDC(window, device_context)
		client_rect: win.RECT
		win.GetClientRect(window, &client_rect)
		X := client_rect.left
		Y := client_rect.top
		height := client_rect.bottom - client_rect.top
		width := client_rect.right - client_rect.left
		win32_update_window(device_context, &client_rect, X, Y, width, height)
		x_offset += 1
	}

	os.exit(cast(int)msg.wParam)
}

