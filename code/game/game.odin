package game

import p "../platform"
import "core:math"


PI: f32 : 3.14159265358979323846


game_output_sound :: proc(game_state: ^p.Game_State, sound_buffer: ^p.Game_Sound_Buffer) {
	tone_volume: f32 = 0.5
	samples_per_cycle := cast(f32)sound_buffer.samples_per_second / game_state.tone_hz
	i := 0
	for _ in 0 ..< sound_buffer.sample_count {
		game_state.phase += (2.0 * PI) / samples_per_cycle
		sample := i16(math.sin(game_state.phase) * 32767.0 * tone_volume)

		// Channel 1
		sound_buffer.samples[i] = 0
		i += 1
		// Channel 2
		sound_buffer.samples[i] = 0
		i += 1
	}
}

render_gradient :: proc(buffer: ^p.Game_Offscreen_Buffer, game_state: ^p.Game_State) {
	bitmap_memory32 := cast([^]u32)buffer.memory
	for y in 0 ..< buffer.height {
		row_idx := y * buffer.width
		offset := row_idx + buffer.width
		row := bitmap_memory32[row_idx:offset]
		for x in 0 ..< buffer.width {
			blue := cast(u32)(u8(cast(i32)game_state.x_offset + x))
			green := cast(u32)(u8(cast(i32)game_state.y_offset + y)) << 16
			row[x] = blue | green
		}
	}
}

render_player :: proc(buffer: ^p.Game_Offscreen_Buffer, player_x: int, player_y: int) {
	if player_x < 0 || player_x + 10 >= cast(int)buffer.width do return
	if player_y < 0 || player_y + 10 >= cast(int)buffer.height do return
	top := player_y
	bottom := top + 10
	bitmap_memory32 := cast([^]u32)buffer.memory
	for x := player_x; x < player_x + 10; x += 1 {
		for y := top; y < bottom; y += 1 {
			offset := y * int(buffer.width) + x
			bitmap_memory32[offset] = 0xFFFFFFFF
		}
	}
}

@(export)
update_and_render :: proc(
	game_memory: ^p.Game_Memory,
	game_sound: ^p.Game_Sound_Buffer,
	game_offscreen_buffer: ^p.Game_Offscreen_Buffer,
	game_input: ^p.Game_Input,
) {
	assert(size_of(p.Game_State) <= game_memory.permanent_storage_size)
	game_state := cast(^p.Game_State)game_memory.permanent_storage

	if !game_memory.is_initialized {
		game_state.tone_hz = 220.0
		game_memory.is_initialized = true
		game_state.phase = 0.0
		game_state.player_x = 100
		game_state.player_y = 100

		filename: cstring16 = "win32_handmade.odin"
		when p.HANDMADE_INTERNAL {
			debug_read_result := p.debug_platform_read_entire_file(filename)
			p.debug_platform_write_entire_file(
				"test.txt",
				debug_read_result.contents_size,
				debug_read_result.contents,
			)
			p.debug_platform_free_file_memory(debug_read_result.contents)
		}
	}

	for controller in game_input.controllers {
		if !controller.is_connected do continue

		if (controller.is_analog) {
			// NOTE(kevin): Use analog movement tuning
			game_state.x_offset += cast(int)(4.0 * (controller.stick_average_x))
			game_state.tone_hz = 220.0 + (128.0 * (controller.stick_average_y))
		} else {
			// NOTE(kevin): Use digital movement tuning
			digital_y: f32 = 0.0
			if controller.move_up.ended_down do digital_y = 1.0
			if controller.move_down.ended_down do digital_y = -1.0
			game_state.tone_hz = max(220.0 + (128.0 * digital_y), 20.0)
		}
		if controller.move_up.ended_down {game_state.y_offset += 1; game_state.player_y -= 5}
		if controller.move_down.ended_down {game_state.y_offset -= 1; game_state.player_y += 5}
		if controller.move_left.ended_down {game_state.x_offset -= 1; game_state.player_x -= 5}
		if controller.move_right.ended_down {game_state.x_offset += 1; game_state.player_x += 5}
	}

	if game_sound != nil {
		game_output_sound(game_state, game_sound)
	}
	render_gradient(game_offscreen_buffer, game_state)
	render_player(game_offscreen_buffer, game_state.player_x, game_state.player_y)
	game_mouse_input(&game_input.mouse, game_offscreen_buffer)
}

game_mouse_input :: proc(mouse: ^p.Game_Mouse, game_offscreen_buffer: ^p.Game_Offscreen_Buffer) {
	mouse_buttons := mouse.buttons
	for i in 0 ..< len(mouse_buttons) {
		button := mouse_buttons[i]
		if button.ended_down {
			render_player(game_offscreen_buffer, 50 + i * 10, 50)
		}
	}
	render_player(game_offscreen_buffer, cast(int)mouse.x, cast(int)mouse.y)
}
