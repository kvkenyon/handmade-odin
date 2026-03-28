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

render_gradient :: proc(buffer: ^Game_Offscreen_Buffer, x_offset: i32, y_offset: i32) {
	bitmap_memory32 := cast([^]u32)buffer.memory
	for y in 0 ..< buffer.height {
		row_idx := y * buffer.width
		offset := row_idx + buffer.width
		row := bitmap_memory32[row_idx:offset]
		for x in 0 ..< buffer.width {
			blue := cast(u32)(u8(x_offset + x))
			green := cast(u32)(u8(y_offset + y)) << 8
			row[x] = blue | green
		}
	}
}


update_and_render :: proc(
	game_offscreen_buffer: ^Game_Offscreen_Buffer,
	x_offset: i32,
	y_offset: i32,
) {
	render_gradient(game_offscreen_buffer, x_offset, y_offset)
}
