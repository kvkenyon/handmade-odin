package platform

import win "core:sys/windows"

HANDMADE_INTERNAL :: #config(HANDMADE_INTERNAL, false)

Debug_Read_Result :: struct {
	contents_size: u32,
	contents:      rawptr,
}

Game_Offscreen_Buffer :: struct {
	width:           i32,
	height:          i32,
	memory:          rawptr,
	bytes_per_pixel: i32,
}

Game_Sound_Buffer :: struct {
	sample_count:       int,
	samples:            [^]i16,
	samples_per_second: int,
}

Game_Button_State :: struct {
	half_transition_count: int,
	ended_down:            bool,
}

Game_Controller_Input :: struct {
	is_connected:    bool,
	is_analog:       bool,
	stick_average_x: f32,
	stick_average_y: f32,
	using _:         struct #raw_union {
		using _: struct {
			action_up:      Game_Button_State,
			action_down:    Game_Button_State,
			action_left:    Game_Button_State,
			action_right:   Game_Button_State,
			move_up:        Game_Button_State,
			move_down:      Game_Button_State,
			move_left:      Game_Button_State,
			move_right:     Game_Button_State,
			left_shoulder:  Game_Button_State,
			right_shoulder: Game_Button_State,
			start:          Game_Button_State,
			back:           Game_Button_State,
		},
		buttons: [12]Game_Button_State,
	},
}

Game_Input :: struct {
	controllers: [5]Game_Controller_Input,
}

Game_State :: struct {
	x_offset: int,
	y_offset: int,
	tone_hz:  f32,
	phase:    f32,
	player_x: int,
	player_y: int,
}

Game_Memory :: struct {
	is_initialized:         bool,
	permanent_storage_size: u64,
	permanent_storage:      rawptr,
	transient_storage_size: u64,
	transient_storage:      rawptr,
}

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
					read_bytes: win.DWORD
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
		memory_size: win.DWORD,
		memory: rawptr,
	) -> bool {
		result := false
		handle := win.CreateFileW(filename, win.GENERIC_WRITE, 0, nil, win.CREATE_ALWAYS, 0, nil)

		if handle != win.INVALID_HANDLE {
			bytes_written: win.DWORD
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
