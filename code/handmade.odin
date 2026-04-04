package game

import "core:math"

PI: f32 : 3.14159265358979323846

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
}

Game_Memory :: struct {
	is_initialized:         bool,
	permanent_storage_size: u64,
	permanent_storage:      rawptr,
	transient_storage_size: u64,
	transient_storage:      rawptr,
}

game_output_sound :: proc(sound_buffer: ^Game_Sound_Buffer, tone_hz: f32) {
	@(static) phase: f32 = 0.0
	tone_volume: f32 = 0.5
	samples_per_cycle := cast(f32)sound_buffer.samples_per_second / tone_hz
	i := 0
	for _ in 0 ..< sound_buffer.sample_count {
		phase += (2.0 * PI) / samples_per_cycle
		sample := i16(math.sin(phase) * 32767.0 * tone_volume)

		// Channel 1
		sound_buffer.samples[i] = sample
		i += 1
		// Channel 2
		sound_buffer.samples[i] = sample
		i += 1
	}
}

render_gradient :: proc(buffer: ^Game_Offscreen_Buffer, game_state: ^Game_State) {
	bitmap_memory32 := cast([^]u32)buffer.memory
	for y in 0 ..< buffer.height {
		row_idx := y * buffer.width
		offset := row_idx + buffer.width
		row := bitmap_memory32[row_idx:offset]
		for x in 0 ..< buffer.width {
			blue := cast(u32)(u8(cast(i32)game_state.x_offset + x))
			green := cast(u32)(u8(cast(i32)game_state.y_offset + y)) << 8
			row[x] = blue | green
		}
	}
}

update_and_render :: proc(
	game_memory: ^Game_Memory,
	game_sound: ^Game_Sound_Buffer,
	game_offscreen_buffer: ^Game_Offscreen_Buffer,
	game_input: ^Game_Input,
) {
	assert(size_of(Game_State) <= game_memory.permanent_storage_size)
	game_state := cast(^Game_State)game_memory.permanent_storage

	if !game_memory.is_initialized {
		game_state.tone_hz = 220.0
		game_memory.is_initialized = true

		filename: cstring16 = "win32_handmade.odin"
		when HANDMADE_INTERNAL {
			debug_read_result := debug_platform_read_entire_file(filename)
			debug_platform_write_entire_file(
				"test.txt",
				debug_read_result.contents_size,
				debug_read_result.contents,
			)
			debug_platform_free_file_memory(debug_read_result.contents)
		}
	}

	for controller in game_input.controllers {
		if (controller.is_analog) {
			// NOTE(kevin): Use analog movement tuning
			game_state.x_offset += cast(int)(4.0 * (controller.stick_average_x))
			game_state.tone_hz = 256.0 + (128.0 * (controller.stick_average_y))
		} else {
			// NOTE(kevin): Use digital movement tuning
		}
		if controller.move_up.ended_down do game_state.y_offset -= 1
		if controller.move_down.ended_down do game_state.y_offset += 1
		if controller.move_left.ended_down do game_state.x_offset -= 1
		if controller.move_right.ended_down do game_state.x_offset += 1
	}
	if game_sound != nil {
		game_output_sound(game_sound, game_state.tone_hz)
	}
	render_gradient(game_offscreen_buffer, game_state)
}
