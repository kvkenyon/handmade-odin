package game

Game_Offscreen_Buffer :: struct {
	width:           i32,
	height:          i32,
	memory:          rawptr,
	bytes_per_pixel: i32,
}

render_gradient :: proc "stdcall" (buffer: ^Game_Offscreen_Buffer, x_offset: i32, y_offset: i32) {
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
