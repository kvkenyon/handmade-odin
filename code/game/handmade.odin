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
	start_x, end_x, min_x, max_x, start_y, end_y, min_y, max_y: f32,
	states:                                                     struct {
		up:             Game_Button_State,
		down:           Game_Button_State,
		left:           Game_Button_State,
		right:          Game_Button_State,
		left_shoulder:  Game_Button_State,
		right_shoulder: Game_Button_State,
	},
}

Game_Input :: struct {
	is_analog:   bool,
	controllers: [4]Game_Controller_Input,
}

Game_State :: struct {
	x_offset: int,
	y_offset: int,
	tone_hz:  f32,
}

Game_Memory :: struct {
	permanent_storage_size: u64,
	permanent_storage:      rawptr,
	transient_storage_size: u64,
	transient_storage:      rawptr,
	is_initialized:         bool,
}

game_output_sound :: proc(sound_buffer: ^Game_Sound_Buffer) {
	@(static) phase: f32 = 0.0
	tone_volume: f32 = 0.5
	tone_hz: f32 = 220.0
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
	game_offscreen_buffer: ^Game_Offscreen_Buffer,
	game_input: ^Game_Input,
) {
	assert(size_of(Game_State) <= game_memory.permanent_storage_size)
	game_state := cast(^Game_State)game_memory.permanent_storage

	if !game_memory.is_initialized {
		game_state.tone_hz = 220.0
		game_memory.is_initialized = true
	}

	if (game_input.is_analog) {
		// NOTE(kevin): Use analog movement tuning
		game_state.x_offset += cast(int)(4.0 * (game_input.controllers[0].end_x))
		game_state.tone_hz = 256.0 + (128.0 * (game_input.controllers[0].end_y))
	} else {
		// NOTE(kevin): Use digital movement tuning
	}

	if game_input.controllers[0].states.up.ended_down do game_state.y_offset -= 1
	if game_input.controllers[0].states.down.ended_down do game_state.y_offset += 1
	if game_input.controllers[0].states.left.ended_down do game_state.x_offset -= 1
	if game_input.controllers[0].states.right.ended_down do game_state.x_offset += 1

	render_gradient(game_offscreen_buffer, game_state)
}
