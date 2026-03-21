package main

import os "core:os"
import win "core:sys/windows"

CLASS_NAME :: "HandmadeHeroWindowClass"

// TODO(Kevin): This is a global for now
RUNNING: bool = false

BYTES_PER_PIXEL: win.LONG : 4

LONG :: win.LONG
INT :: win.INT

bitmap_info: win.BITMAPINFO
bitmap_memory: [^]u8
bitmap_width: LONG
bitmap_height: LONG

render_gradient :: proc "std" (x_offset: INT, y_offset: INT) {
	stride := BYTES_PER_PIXEL * bitmap_width
	for y in 0 ..< bitmap_height {
		row_idx := y * stride
		offset := row_idx + stride
		row := bitmap_memory[row_idx:offset]
		idx := 0
		for x in 0 ..< bitmap_width {
			// Blue
			row[idx] = cast(u8)x_offset + cast(u8)x
			idx += 1
			// Green
			row[idx] = cast(u8)y_offset + cast(u8)y
			idx += 1
			// Red
			row[idx] = 0
			idx += 1
			// Pad
			row[idx] = 0
			idx += 1
		}
	}
}

win32_resize_dib_section :: proc "stdcall" (width: LONG, height: LONG) {
	if bitmap_memory != nil {
		win.VirtualFree(&bitmap_memory, 0, win.MEM_RELEASE)
	}

	bitmap_width = width
	bitmap_height = height

	bitmap_info.bmiHeader.biSize = size_of(win.BITMAPINFOHEADER)
	bitmap_info.bmiHeader.biWidth = width
	bitmap_info.bmiHeader.biHeight = height
	bitmap_info.bmiHeader.biPlanes = 1
	bitmap_info.bmiHeader.biBitCount = 32
	bitmap_info.bmiHeader.biCompression = win.BI_RGB

	bitmap_memory_size := (width * height) * BYTES_PER_PIXEL

	bitmap_memory = cast([^]u8)win.VirtualAlloc(
		nil,
		cast(win.SIZE_T)bitmap_memory_size,
		win.MEM_COMMIT,
		win.PAGE_READWRITE,
	)

	render_gradient(0, 0)

}

win32_update_window :: proc "stdcall" (
	hdc: win.HDC,
	rect: ^win.RECT,
	x: INT,
	y: INT,
	window_width: INT,
	window_height: INT,
) {
	win.StretchDIBits(
		hdc,
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

main :: proc() {
	RUNNING = true
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

	hwnd := win.CreateWindowExW(
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

	assert(hwnd != nil, "Window creation Failed")

	win.ShowWindow(hwnd, win.SW_SHOWDEFAULT)
	win.UpdateWindow(hwnd)

	msg: win.MSG

	for RUNNING {
		res := win.GetMessageW(&msg, nil, 0, 0)

		if res < 0 {
			break
		}
		win.TranslateMessage(&msg)
		win.DispatchMessageW(&msg)
	}

	os.exit(cast(int)msg.wParam)
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

