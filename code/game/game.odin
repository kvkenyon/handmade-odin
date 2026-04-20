package game

import p "../platform"

/* Tile Map */

ROWS :: 9
COLS :: 20
TILE_WIDTH :: 64
TILE_HEIGHT :: 80

World :: struct {
	count_y:   u32,
	count_x:   u32,
	tile_maps: [^]Tile_Map,
}

Tile_Map :: struct {
	count_y: u32,
	count_x: u32,
	height:  u32,
	width:   u32,
	tiles:   [^]u32,
}

get_tile_coordinates :: #force_inline proc(x: f32, y: f32, tile_map: ^Tile_Map) -> (i32, i32) {
	tile_x := i32(x / f32(tile_map.width))
	tile_y := i32(y / f32(tile_map.height))
	return tile_x, tile_y
}


point_in_tile_map_is_open :: proc(x: f32, y: f32, tile_map: ^Tile_Map) -> bool {
	tile_x, tile_y := get_tile_coordinates(x, y, tile_map)
	return tile_map.tiles[u32(tile_x) + u32(tile_y) * tile_map.count_x] == 0
}

point_in_tile_map :: proc(x: f32, y: f32, tile_map: ^Tile_Map) -> bool {
	tile_x, tile_y := get_tile_coordinates(x, y, tile_map)
	return(
		tile_x >= 0 &&
		tile_x < i32(tile_map.count_x) &&
		tile_y >= 0 &&
		tile_y < i32(tile_map.count_y) \
	)
}

point_is_open_in_world :: proc(
	x: f32,
	y: f32,
	world_x: u32,
	world_y: u32,
	world: ^World,
) -> (
	bool,
	u32,
	u32,
	f32,
	f32,
) {

	tile_map := world.tile_maps[world_x + world_y * 2]

	if point_in_tile_map(x, y, &tile_map) {
		return point_in_tile_map_is_open(x, y, &tile_map), world_x, world_y, x, y
	}

	tile_x, tile_y := get_tile_coordinates(x, y, &tile_map)

	new_x := x
	new_y := y
	d_world_x: u32 = 0
	d_world_y: u32 = 0

	tile_map_width := f32(tile_map.count_x * tile_map.width)
	tile_map_height := f32(tile_map.count_y * tile_map.height)

	if tile_x < 0 {
		// to the left
		tile_x = i32(tile_map.count_x) + tile_x
		d_world_x -= 1
		if world_x == 0 {
			return false, world_x, world_y, x, y
		}
		new_x = tile_map_width + x
	} else if tile_x >= i32(tile_map.count_x) {
		// to the right
		tile_x = tile_x % i32(tile_map.count_x)
		d_world_x += 1
		if world_x == COLS - 1 {
			return false, world_x, world_y, x, y
		}
		new_x := x - tile_map_width
	}

	if tile_y < 0 {
		// to the top
		tile_y = i32(tile_map.count_y) + tile_y
		d_world_y -= 1
		if world_y == 0 {
			return false, world_x, world_y, x, y
		}
		new_y = tile_map_height + y
	} else if tile_y >= i32(tile_map.count_y) {
		// to the bottom
		tile_y = tile_y % i32(tile_map.count_y)
		d_world_y += 1
		if world_y == 1 {
			return false, world_x, world_y, x, y
		}
		new_y = y - tile_map_height
	}

	new_world_x := world_x + d_world_x
	new_world_y := world_y + d_world_y

	tile_map = world.tile_maps[new_world_x + new_world_y * 2]

	if tile_map.tiles[tile_x + tile_y * COLS] == 0 &&
	   0 <= tile_x &&
	   tile_x < i32(tile_map.count_x) &&
	   0 <= tile_y &&
	   tile_y < i32(tile_map.count_y) {
		return true, new_world_x, new_world_y, new_x, new_y
	}


	return false, world_x, world_y, x, y
}


/* Helpers */

round_f32_to_i32 :: #force_inline proc(value: f32) -> i32 {
	return i32(value + 0.5)
}

round_f32_to_u32 :: #force_inline proc(value: f32) -> u32 {
	return u32(value + 0.5)
}

/* Drawing */

draw_rectangle :: proc(
	buffer: ^p.Game_Offscreen_Buffer,
	real_min_x: f32,
	real_max_x: f32,
	real_min_y: f32,
	real_max_y: f32,
	r: f32,
	g: f32,
	b: f32,
) {
	min_x := round_f32_to_i32(real_min_x)
	min_y := round_f32_to_i32(real_min_y)
	max_x := round_f32_to_i32(real_max_x)
	max_y := round_f32_to_i32(real_max_y)
	if min_x < 0 {
		min_x = 0
	}
	if min_y < 0 {
		min_y = 0
	}
	if max_x > buffer.width {
		max_x = buffer.width
	}
	if max_y > buffer.height {
		max_y = buffer.height
	}
	color :=
		round_f32_to_u32(r * 255.0) << 16 |
		round_f32_to_u32(g * 255.0) << 8 |
		round_f32_to_u32(b * 255.0) << 0
	bitmap_memory32 := cast([^]u32)buffer.memory
	for y := min_y; y < max_y; y += 1 {
		offset := y * buffer.width
		for x := min_x; x < max_x; x += 1 {
			bitmap_memory32[offset + x] = color
		}
	}
}

/* Game Update */

game_output_sound :: proc(game_state: ^p.Game_State, sound_buffer: ^p.Game_Sound_Buffer) {
	// TODO(kevin): output sound
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

	player_width := .75 * f32(TILE_WIDTH)
	player_height := .5 * f32(TILE_HEIGHT)

	tiles_00: [ROWS][COLS]u32 = {
		{1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1},
		{1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1},
		{1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1},
		{1, 0, 1, 0, 0, 1, 1, 1, 0, 0, 1, 1, 1, 0, 0, 0, 0, 1, 1, 1},
		{1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1},
		{1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
		{1, 0, 0, 0, 0, 1, 0, 0, 0, 1, 1, 1, 0, 0, 0, 0, 0, 1, 1, 1},
		{1, 1, 1, 1, 1, 1, 0, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 1, 1, 1},
		{1, 1, 1, 1, 1, 1, 0, 1, 1, 1, 1, 1, 1, 1, 0, 0, 1, 1, 1, 1},
	}
	tiles_01: [ROWS][COLS]u32 = {
		{1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 1, 1, 1, 1},
		{1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1},
		{1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1},
		{1, 0, 1, 0, 0, 1, 1, 1, 0, 0, 1, 1, 1, 0, 0, 0, 0, 1, 1, 1},
		{1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1},
		{0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1},
		{1, 0, 0, 0, 0, 1, 1, 0, 0, 1, 1, 1, 0, 0, 0, 0, 0, 1, 1, 1},
		{1, 1, 1, 1, 1, 1, 1, 0, 1, 1, 1, 1, 1, 0, 0, 0, 0, 1, 1, 1},
		{1, 1, 1, 1, 1, 1, 1, 0, 1, 1, 1, 1, 1, 1, 0, 0, 1, 1, 1, 1},
	}
	tiles_10: [ROWS][COLS]u32 = {
		{1, 1, 1, 1, 1, 1, 0, 1, 1, 1, 1, 1, 1, 1, 0, 0, 1, 1, 1, 1},
		{1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1},
		{1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1},
		{1, 0, 1, 0, 0, 1, 1, 1, 0, 0, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0},
		{1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1},
		{1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1},
		{1, 0, 0, 0, 0, 1, 1, 1, 0, 1, 1, 1, 0, 0, 0, 0, 0, 1, 1, 1},
		{1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 1, 1, 1},
		{1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 1, 1, 1, 1},
	}
	tiles_11: [ROWS][COLS]u32 = {
		{1, 1, 1, 1, 1, 1, 1, 0, 1, 1, 1, 1, 1, 1, 1, 0, 1, 1, 1, 1},
		{1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1},
		{1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1},
		{0, 0, 1, 0, 0, 1, 1, 1, 0, 0, 1, 1, 1, 0, 0, 0, 0, 1, 1, 1},
		{1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1},
		{1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1},
		{1, 0, 0, 0, 0, 1, 1, 1, 0, 1, 1, 1, 0, 0, 0, 0, 0, 1, 1, 1},
		{1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 1, 1, 1},
		{1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 1, 1, 1, 1},
	}

	tile_map_00 := Tile_Map {
		count_x = COLS,
		count_y = ROWS,
		width   = TILE_WIDTH,
		height  = TILE_HEIGHT,
		tiles   = &tiles_00[0][0],
	}

	tile_map_01 := tile_map_00
	tile_map_01.tiles = &tiles_01[0][0]

	tile_map_10 := tile_map_00
	tile_map_10.tiles = &tiles_10[0][0]

	tile_map_11 := tile_map_00
	tile_map_11.tiles = &tiles_11[0][0]

	tile_maps: [2][2]Tile_Map = {{tile_map_00, tile_map_01}, {tile_map_10, tile_map_11}}

	world := World {
		count_x   = 2,
		count_y   = 2,
		tile_maps = &tile_maps[0][0],
	}

	if !game_memory.is_initialized {
		game_memory.is_initialized = true
		game_state.player_x = 100.
		game_state.player_y = 160.
		game_state.player_world_x = 0
		game_state.player_world_y = 0
	}

	curr_tile_map := world.tile_maps[game_state.player_world_x + game_state.player_world_y * 2]

	for controller in game_input.controllers {
		if !controller.is_connected do continue

		if (controller.is_analog) {
			// NOTE(kevin): Use analog movement tuning
		} else {
			// NOTE(kevin): Use digital movement tuning
			d_player_x: f32 = 0.0 // pixels/sec
			d_player_y: f32 = 0.0 // pixels/sec

			if controller.move_down.ended_down {
				d_player_y = 1.0
			}
			if controller.move_up.ended_down {
				d_player_y = -1.0
			}
			if controller.move_left.ended_down {
				d_player_x = -1.0
			}
			if controller.move_right.ended_down {
				d_player_x = 1.0
			}

			d_player_x *= 128.0
			d_player_y *= 128.0

			delta_x := game_input.t_delta * d_player_x // pixels/frame
			delta_y := game_input.t_delta * d_player_y

			world_x := game_state.player_world_x
			world_y := game_state.player_world_y

			is_free, new_world_x, new_world_y, new_player_x, new_player_y :=
				point_is_open_in_world(
					game_state.player_x + delta_x,
					game_state.player_y + delta_y,
					world_x,
					world_y,
					&world,
				)

			if is_free {
				curr_tile_map = world.tile_maps[new_world_x + new_world_y * 2]
				if point_in_tile_map_is_open(
					   new_player_x - (player_width / 2),
					   new_player_y,
					   &curr_tile_map,
				   ) &&
				   point_in_tile_map_is_open(
					   new_player_x + (player_width / 2),
					   new_player_y,
					   &curr_tile_map,
				   ) {
					game_state.player_x = new_player_x
					game_state.player_y = new_player_y
					game_state.player_world_x = new_world_x
					game_state.player_world_y = new_world_y
				}
			}
		}
	}

	if game_sound != nil {
		game_output_sound(game_state, game_sound)
	}

	game_mouse_input(&game_input.mouse, game_offscreen_buffer)

	world_x := game_state.player_world_x
	world_y := game_state.player_world_y

	tile_map := world.tile_maps[world_x + world_y * 2]
	for row in 0 ..< tile_map.count_y {
		for col in 0 ..< tile_map.count_x {
			gray: f32 = 0.5
			if tile_map.tiles[col + row * tile_map.count_x] == 1 {
				gray = 1.0
			}
			min_x := f32(col * tile_map.width)
			min_y := f32(row * tile_map.height)
			max_x := min_x + f32(TILE_WIDTH)
			max_y := min_y + f32(TILE_HEIGHT)
			draw_rectangle(game_offscreen_buffer, min_x, max_x, min_y, max_y, gray, gray, gray)
		}
	}


	player_left := game_state.player_x - (.5 * player_width)
	player_top := game_state.player_y - player_height

	draw_rectangle(
		game_offscreen_buffer,
		player_left,
		player_left + player_width,
		player_top,
		player_top + player_height,
		1.0,
		1.0,
		0.0,
	)
}

game_mouse_input :: proc(mouse: ^p.Game_Mouse, game_offscreen_buffer: ^p.Game_Offscreen_Buffer) {
	mouse_buttons := mouse.buttons
	for i in 0 ..< len(mouse_buttons) {
		button := mouse_buttons[i]
		if button.ended_down {
			// TODO(kevin): handle mouse click
		}
	}
}
