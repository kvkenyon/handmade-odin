package game

import p "../platform"


/* Tile Map */

ROWS :: 9
COLS :: 20
TILE_WIDTH :: 64
TILE_HEIGHT :: 80

World :: struct {
	world_count_y: i32,
	world_count_x: i32,
	tile_count_y:  i32,
	tile_count_x:  i32,
	tile_height:   i32,
	tile_width:    i32,
	tile_maps:     [^]Tile_Map,
}

Tile_Map :: struct {
	tiles: [^]u32,
}

Position :: struct {
	// NOTE(kevin): Tile map indeces
	world_x:  i32,
	world_y:  i32,
	// NOTE(Kevin): Pixel position
	screen_x: f32,
	screen_y: f32,
}

Player :: struct {
	width:    i32,
	height:   i32,
	position: Position,
}

Game_State :: struct {
	world:  World,
	player: Player,
}

player_position_left :: proc(player: ^Player) -> Position {
	left: Position = player.position
	left.screen_x -= (0.5 * f32(player.width))
	return left
}

player_position_right :: proc(player: ^Player) -> Position {
	right: Position = player.position
	right.screen_x += (0.5 * f32(player.width))
	return right
}

get_tile_map :: proc(pos: ^Position, world: ^World) -> ^Tile_Map {
	return &world.tile_maps[pos.world_x + pos.world_y * world.world_count_x]
}

get_tile_coordinates :: #force_inline proc(pos: ^Position, world: ^World) -> (i32, i32) {
	tile_x := i32(pos.screen_x / f32(world.tile_width))
	tile_y := i32(pos.screen_y / f32(world.tile_height))
	return tile_x, tile_y
}

is_position_empty :: proc(pos: ^Position, world: ^World) -> bool {
	tile_x, tile_y := get_tile_coordinates(pos, world)
	tile_map := get_tile_map(pos, world)
	return(
		tile_x >= 0 &&
		tile_x < i32(world.tile_count_x) &&
		tile_y >= 0 &&
		tile_y < i32(world.tile_count_y) &&
		tile_map.tiles[tile_x + tile_y * world.tile_count_x] == 0 \
	)
}

is_world_position_empty :: proc(
	player: ^Player,
	position: ^Position,
	world: ^World,
) -> (
	bool,
	Position,
) {

	player_left := player_position_left(player)
	player_right := player_position_right(player)

	if is_position_empty(position, world) &&
	   is_position_empty(&player_left, world) &&
	   is_position_empty(&player_right, world) {
		return true, position^
	}

	tile_x, tile_y := get_tile_coordinates(position, world)

	new_pos: Position = position^

	tile_map_width := world.tile_width * world.tile_count_x
	tile_map_height := world.tile_height * world.tile_count_y

	if tile_x < 0 {
		// to the left
		tile_x = i32(world.tile_count_x) + tile_x
		if position.world_x == 0 {
			return false, new_pos
		}
		new_pos.world_x = position.world_x - 1
		new_pos.screen_x = f32(tile_map_width) + position.screen_x
	} else if tile_x > world.tile_count_x - 1 {
		// to the right
		tile_x = tile_x % world.tile_count_x
		if position.world_x == world.tile_count_x - 1 {
			return false, new_pos
		}
		new_pos.world_x = position.world_x + 1
		new_pos.screen_x = position.screen_x - f32(tile_map_width)
	} else if tile_x == 0 {
		// to the left
		tile_x = world.tile_count_x - 1
		if position.world_x == 0 {
			return false, new_pos
		}
		new_pos.world_x -= 1
		new_pos.screen_x = f32(tile_map_width) + position.screen_x
	} else if tile_x == world.tile_count_x - 1 {
		// to the right
		tile_x = 0
		if position.world_x == world.tile_count_x - 1 {
			return false, new_pos
		}
		new_pos.world_x = position.world_x + 1
		new_pos.screen_x = position.screen_x - f32(tile_map_width)
		if new_pos.screen_x < 0 do new_pos.screen_x = 0
	}

	if tile_y < 0 {
		// to the top
		tile_y = world.tile_count_y + tile_y
		if position.world_y == 0 {
			return false, new_pos
		}
		new_pos.world_y = position.world_y - 1
		new_pos.screen_y = f32(tile_map_height) + position.screen_y
	} else if tile_y >= world.tile_count_y {
		// to the bottom
		tile_y = tile_y % world.tile_count_y
		if position.world_y == 1 {
			return false, new_pos
		}
		new_pos.world_y = position.world_y + 1
		new_pos.screen_y = position.screen_y - f32(tile_map_height)
	}


	if is_position_empty(&new_pos, world) {
		return true, new_pos
	}

	return false, new_pos
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

game_output_sound :: proc(game_state: ^Game_State, sound_buffer: ^p.Game_Sound_Buffer) {
	// TODO(kevin): output sound
}

init_world :: proc() -> World {
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
		tiles = &tiles_00[0][0],
	}

	tile_map_01 := Tile_Map {
		tiles = &tiles_01[0][0],
	}

	tile_map_10 := Tile_Map {
		tiles = &tiles_10[0][0],
	}

	tile_map_11 := Tile_Map {
		tiles = &tiles_11[0][0],
	}

	tile_maps: [2][2]Tile_Map = {{tile_map_00, tile_map_01}, {tile_map_10, tile_map_11}}

	world := World {
		world_count_x = 2,
		world_count_y = 2,
		tile_count_x  = COLS,
		tile_count_y  = ROWS,
		tile_width    = TILE_WIDTH,
		tile_height   = TILE_HEIGHT,
		tile_maps     = &tile_maps[0][0],
	}

	return world
}

@(export)
update_and_render :: proc(
	game_memory: ^p.Game_Memory,
	game_sound: ^p.Game_Sound_Buffer,
	game_offscreen_buffer: ^p.Game_Offscreen_Buffer,
	game_input: ^p.Game_Input,
) {
	assert(size_of(Game_State) <= game_memory.permanent_storage_size)
	game_state := cast(^Game_State)game_memory.permanent_storage

	if !game_memory.is_initialized {
		game_memory.is_initialized = true
		player_width := .75 * f32(TILE_WIDTH)
		player_height := .5 * f32(TILE_HEIGHT)
		player := Player {
			width = i32(player_width),
			height = i32(player_height),
			position = Position{screen_x = 100, screen_y = 160, world_x = 0, world_y = 0},
		}
		game_state.player = player
		game_state.world = init_world()
	}

	world := game_state.world

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
				assert(d_player_x == 1.0)
			}

			d_player_x *= 128.0
			d_player_y *= 128.0

			delta_x := game_input.t_delta * d_player_x // pixels/frame
			delta_y := game_input.t_delta * d_player_y

			pos := game_state.player.position
			pos.screen_x += delta_x
			pos.screen_y += delta_y

			is_free, new_pos := is_world_position_empty(&game_state.player, &pos, &world)

			if is_free {
				game_state.player.position = new_pos
			}
		}
	}

	if game_sound != nil {
		game_output_sound(game_state, game_sound)
	}

	game_mouse_input(&game_input.mouse, game_offscreen_buffer)

	tile_map := get_tile_map(&game_state.player.position, &world)
	for row in 0 ..< world.tile_count_y {
		for col in 0 ..< world.tile_count_x {
			gray: f32 = 0.5
			if tile_map.tiles[col + row * world.tile_count_x] == 1 {
				gray = 1.0
			}
			min_x := f32(col * world.tile_width)
			min_y := f32(row * world.tile_height)
			max_x := min_x + f32(TILE_WIDTH)
			max_y := min_y + f32(TILE_HEIGHT)
			draw_rectangle(game_offscreen_buffer, min_x, max_x, min_y, max_y, gray, gray, gray)
		}
	}

	player_left := game_state.player.position.screen_x - (.5 * f32(game_state.player.width))
	player_top := game_state.player.position.screen_y - f32(game_state.player.height)

	draw_rectangle(
		game_offscreen_buffer,
		player_left,
		player_left + f32(game_state.player.width),
		player_top,
		player_top + f32(game_state.player.height),
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
