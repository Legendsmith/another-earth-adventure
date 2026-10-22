class_name DungeonGenerator
extends RefCounted
## Lays out an expedition dungeon on a grid of 64 px cells: rooms joined by corridors, the entrance (where loot is
## recovered) in the first room, and deeper rooms holding more loot, prisoners and enemies (Expedition Gameplay).
## Depth is the number of rooms between a room and the entrance.

enum Cell { WALL, FLOOR, ICE, LAVA }
enum RoomTag { NONE, ENTRANCE, LOOT, PRISON, TERMINAL, LAIR, SHIP }

const CELL_SIZE := 64


class Room:
	extends RefCounted
	var index: int = 0
	var rect: Rect2i
	var depth: int = 0
	var tag: RoomTag = RoomTag.NONE
	var links: Array[int] = []
	## A player-side character has been inside.
	var explored: bool = false

	func center() -> Vector2i:
		return rect.position + rect.size / 2

	func world_center() -> Vector2:
		return (Vector2(center()) + Vector2(0.5, 0.5)) * CELL_SIZE

	func world_rect() -> Rect2:
		return Rect2(Vector2(rect.position) * CELL_SIZE, Vector2(rect.size) * CELL_SIZE)

	func random_cell(rng: RandomNumberGenerator, margin: int = 1) -> Vector2i:
		return Vector2i(rng.randi_range(rect.position.x + margin, rect.end.x - 1 - margin),
			rng.randi_range(rect.position.y + margin, rect.end.y - 1 - margin))


var size := Vector2i(72, 56)
var cells: PackedByteArray
var rooms: Array[Room] = []
var rng := RandomNumberGenerator.new()


func generate(generator_seed: int, room_count: int = 12, map_size: Vector2i = Vector2i(72, 56),
		ice_walls: bool = false, lava: bool = false) -> void:
	rng.seed = generator_seed
	size = map_size
	cells = PackedByteArray()
	cells.resize(size.x * size.y)
	cells.fill(Cell.WALL)
	rooms.clear()
	_place_rooms(room_count)
	_connect_rooms()
	_compute_depth()
	_tag_rooms()
	if ice_walls:
		_add_ice_walls()
	if lava:
		_add_lava()


## A ship interior for boarding actions: a chain of compartments along a central corridor.
func generate_ship(generator_seed: int, compartments: int = 8) -> void:
	rng.seed = generator_seed
	size = Vector2i(compartments * 9 + 6, 30)
	cells = PackedByteArray()
	cells.resize(size.x * size.y)
	cells.fill(Cell.WALL)
	rooms.clear()
	for i: int in compartments:
		var top := i % 2 == 0
		var rect := Rect2i(3 + i * 9, 4 if top else 17, 7, 9)
		_add_room(rect)
	var corridor := Rect2i(3, 13, size.x - 6, 4)
	_carve(corridor)
	for room: Room in rooms:
		var x := room.center().x
		if room.rect.position.y < 13:
			_carve(Rect2i(x - 1, room.rect.end.y, 3, 13 - room.rect.end.y))
		else:
			_carve(Rect2i(x - 1, 17, 3, room.rect.position.y - 17))
		if room.index > 0:
			room.links.append(room.index - 1)
			rooms[room.index - 1].links.append(room.index)
	_compute_depth()
	for room: Room in rooms:
		room.tag = RoomTag.SHIP
	rooms[0].tag = RoomTag.ENTRANCE


func _add_room(rect: Rect2i) -> Room:
	var room := Room.new()
	room.index = rooms.size()
	room.rect = rect
	rooms.append(room)
	_carve(rect)
	return room


func _place_rooms(room_count: int) -> void:
	var attempts := 0
	# The entrance sits near the left edge so the dungeon reads left to right on the minimap.
	_add_room(Rect2i(2, size.y / 2 - 4, 8, 8))
	while rooms.size() < room_count and attempts < 2000:
		attempts += 1
		var w := rng.randi_range(7, 13)
		var h := rng.randi_range(6, 11)
		var rect := Rect2i(rng.randi_range(2, size.x - w - 2), rng.randi_range(2, size.y - h - 2), w, h)
		var grown := rect.grow(3)
		var overlaps := false
		for room: Room in rooms:
			if room.rect.intersects(grown):
				overlaps = true
				break
		if not overlaps:
			_add_room(rect)


func _connect_rooms() -> void:
	# Minimum spanning tree over room centres, plus a few extra links so there are loops to flank around.
	var connected := {0: true}
	while connected.size() < rooms.size():
		var best := INF
		var pair := Vector2i(-1, -1)
		for a: int in connected:
			for b: int in rooms.size():
				if connected.has(b):
					continue
				var d := Vector2(rooms[a].center()).distance_squared_to(Vector2(rooms[b].center()))
				if d < best:
					best = d
					pair = Vector2i(a, b)
		connected[pair.y] = true
		_link(pair.x, pair.y)
	for i: int in maxi(1, rooms.size() / 4):
		var a := rng.randi_range(1, rooms.size() - 1)
		var b := rng.randi_range(1, rooms.size() - 1)
		if a != b and not rooms[a].links.has(b):
			_link(a, b)


func _link(a: int, b: int) -> void:
	rooms[a].links.append(b)
	rooms[b].links.append(a)
	var from := rooms[a].center()
	var to := rooms[b].center()
	var width := rng.randi_range(2, 3)
	if rng.randf() < 0.5:
		_carve(Rect2i(mini(from.x, to.x), from.y - width / 2, absi(to.x - from.x) + width, width))
		_carve(Rect2i(to.x - width / 2, mini(from.y, to.y), width, absi(to.y - from.y) + width))
	else:
		_carve(Rect2i(from.x - width / 2, mini(from.y, to.y), width, absi(to.y - from.y) + width))
		_carve(Rect2i(mini(from.x, to.x), to.y - width / 2, absi(to.x - from.x) + width, width))


func _compute_depth() -> void:
	for room: Room in rooms:
		room.depth = -1
	rooms[0].depth = 0
	var queue: Array[int] = [0]
	while not queue.is_empty():
		var current: int = queue.pop_front()
		for next: int in rooms[current].links:
			if rooms[next].depth < 0:
				rooms[next].depth = rooms[current].depth + 1
				queue.append(next)


func _tag_rooms() -> void:
	rooms[0].tag = RoomTag.ENTRANCE
	var by_depth: Array[Room] = rooms.duplicate()
	by_depth.sort_custom(func(a: Room, b: Room) -> bool: return a.depth > b.depth)
	# Prisoners are held in the lower levels: the deepest room.
	if by_depth.size() > 1:
		by_depth[0].tag = RoomTag.PRISON
	if by_depth.size() > 2:
		by_depth[1].tag = RoomTag.LAIR
	var tagged_terminal := false
	for room: Room in by_depth:
		if room.tag != RoomTag.NONE:
			continue
		if not tagged_terminal and room.depth >= 2:
			room.tag = RoomTag.TERMINAL
			tagged_terminal = true
		elif rng.randf() < 0.55:
			room.tag = RoomTag.LOOT


func _add_ice_walls() -> void:
	# Ice plugs across some corridors next to rooms.
	for room: Room in rooms:
		if room.index == 0 or rng.randf() > 0.4:
			continue
		var r := room.rect
		for x: int in range(r.position.x, r.end.x):
			for y: int in [r.position.y - 1, r.end.y]:
				if get_cell(Vector2i(x, y)) == Cell.FLOOR:
					set_cell(Vector2i(x, y), Cell.ICE)
		for y: int in range(r.position.y, r.end.y):
			for x: int in [r.position.x - 1, r.end.x]:
				if get_cell(Vector2i(x, y)) == Cell.FLOOR:
					set_cell(Vector2i(x, y), Cell.ICE)


func _add_lava() -> void:
	for room: Room in rooms:
		if room.index == 0 or rng.randf() > 0.5:
			continue
		var pool := Rect2i(room.random_cell(rng, 2), Vector2i(rng.randi_range(1, 3), rng.randi_range(1, 2)))
		for x: int in range(pool.position.x, pool.end.x):
			for y: int in range(pool.position.y, pool.end.y):
				var cell := Vector2i(x, y)
				if room.rect.grow(-1).has_point(cell):
					set_cell(cell, Cell.LAVA)


func _carve(rect: Rect2i) -> void:
	for x: int in range(maxi(1, rect.position.x), mini(size.x - 1, rect.end.x)):
		for y: int in range(maxi(1, rect.position.y), mini(size.y - 1, rect.end.y)):
			cells[y * size.x + x] = Cell.FLOOR


func get_cell(cell: Vector2i) -> int:
	if cell.x < 0 or cell.y < 0 or cell.x >= size.x or cell.y >= size.y:
		return Cell.WALL
	return cells[cell.y * size.x + cell.x]


func set_cell(cell: Vector2i, value: int) -> void:
	if cell.x < 0 or cell.y < 0 or cell.x >= size.x or cell.y >= size.y:
		return
	cells[cell.y * size.x + cell.x] = value


func is_walkable(cell: Vector2i) -> bool:
	var value := get_cell(cell)
	return value == Cell.FLOOR or value == Cell.LAVA


func blocks_sight(cell: Vector2i) -> bool:
	var value := get_cell(cell)
	return value == Cell.WALL or value == Cell.ICE


static func world_to_cell(point: Vector2) -> Vector2i:
	return Vector2i(floori(point.x / CELL_SIZE), floori(point.y / CELL_SIZE))


static func cell_to_world(cell: Vector2i) -> Vector2:
	return (Vector2(cell) + Vector2(0.5, 0.5)) * CELL_SIZE


## Grid line of sight between two world points (walls and ice block it).
func has_line_of_sight(from: Vector2, to: Vector2) -> bool:
	var a := from / CELL_SIZE
	var b := to / CELL_SIZE
	var steps := int(ceilf(a.distance_to(b) * 2.0))
	for i: int in range(1, steps):
		var p := a.lerp(b, float(i) / steps)
		if blocks_sight(Vector2i(floori(p.x), floori(p.y))):
			return false
	return true


func room_at(point: Vector2) -> Room:
	var cell := world_to_cell(point)
	for room: Room in rooms:
		if room.rect.has_point(cell):
			return room
	return null
