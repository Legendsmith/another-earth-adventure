class_name ShipInternalsView
extends Node2D
## Top-down view of a ShipInternals deck plan: hull, walls and doors, the modules (darkening as they are damaged),
## holes for the crew to patch and the tracks of rounds that bored through. It is a plain 2D scene, so it can be
## embedded in a SubViewport inside any other scene.
##
## It also gives crew a world to move in: hull, walls and modules are solid (a StaticBody2D on `wall_layer`), each module
## and each hole has an Area2D that reports bodies on `crew_mask` touching it, and ShipInternals.find_path finds routes
## over open deck (convert with cell_to_local / local_to_cell).

signal module_touched(index: int, body: Node2D)
signal module_untouched(index: int, body: Node2D)
signal breach_touched(cell: Vector2i, body: Node2D)

## Seconds a round's track stays drawn.
const TRACK_FADE := 6.0
const FLOOR_COLOR := Color(0.13, 0.15, 0.18)
const FLOOR_LINE_COLOR := Color(0.18, 0.2, 0.24)
const HULL_COLOR := Color(0.55, 0.58, 0.62)
const WALL_COLOR := Color(0.36, 0.39, 0.44)
const DOOR_COLOR := Color(0.25, 0.45, 0.5)
const SPACE_BREACH_COLOR := Color(1.0, 0.25, 0.2)
const WALL_BREACH_COLOR := Color(1.0, 0.6, 0.2)
const TRACK_COLOR := Color(1.0, 0.85, 0.5)

## The internals shown. Left empty, the view makes its own with the default layout (handy for testing the scene).
@export var internals: ShipInternals
@export var cell_size: float = 16.0
@export_flags_2d_physics var wall_layer: int = 1
## Bodies on these layers trigger module_touched and breach_touched.
@export_flags_2d_physics var crew_mask: int = 1
@export var show_room_names: bool = true

var _walls: StaticBody2D
var _module_areas: Array[Area2D] = []
var _breach_areas: Dictionary = {}
## Recent round tracks: [from (cells), to (cells), age (s)].
var _tracks: Array = []


func _ready() -> void:
	if internals == null:
		var own := ShipInternals.new()
		own.name = "ShipInternals"
		add_child(own)
		internals = own
	bind(internals)


## Shows another ShipInternals (for example the player hull's, once the space scene has one).
func bind(new_internals: ShipInternals) -> void:
	if internals and internals != new_internals:
		_disconnect(internals)
	internals = new_internals
	if internals == null:
		return
	if not internals.is_node_ready():
		await internals.ready
	_connect(internals)
	_tracks.clear()
	_rebuild_bodies()
	queue_redraw()


func get_size() -> Vector2:
	if internals == null:
		return Vector2.ZERO
	return Vector2(internals.length, internals.diameter) * cell_size


## Centre of a deck cell, in this node's coordinates.
func cell_to_local(cell: Vector2i) -> Vector2:
	return (Vector2(cell) + Vector2(0.5, 0.5)) * cell_size


func local_to_cell(point: Vector2) -> Vector2i:
	return Vector2i((point / cell_size).floor())


func _process(delta: float) -> void:
	if _tracks.is_empty():
		return
	for track in _tracks:
		track[2] += delta
	_tracks = _tracks.filter(func(track: Array) -> bool: return track[2] < TRACK_FADE)
	queue_redraw()


#region Signals

func _connect(target: ShipInternals) -> void:
	target.armor_changed.connect(queue_redraw)
	target.breach_opened.connect(_on_breach_opened)
	target.breach_patched.connect(_on_breach_patched)
	target.module_damaged.connect(_on_module_changed)
	target.module_repaired.connect(_on_module_changed)
	target.round_tracked.connect(_on_round_tracked)


func _disconnect(target: ShipInternals) -> void:
	for connection in [[target.armor_changed, queue_redraw], [target.breach_opened, _on_breach_opened],
			[target.breach_patched, _on_breach_patched], [target.module_damaged, _on_module_changed],
			[target.module_repaired, _on_module_changed], [target.round_tracked, _on_round_tracked]]:
		if (connection[0] as Signal).is_connected(connection[1]):
			(connection[0] as Signal).disconnect(connection[1])


func _on_breach_opened(cell: Vector2i, _kind: ShipInternals.BreachKind) -> void:
	_add_breach_area(cell)
	queue_redraw()


func _on_breach_patched(cell: Vector2i) -> void:
	if _breach_areas.has(cell):
		_breach_areas[cell].queue_free()
		_breach_areas.erase(cell)
	queue_redraw()


func _on_module_changed(_index: int) -> void:
	queue_redraw()


func _on_round_tracked(from: Vector2, to: Vector2) -> void:
	_tracks.append([from, to, 0.0])
	queue_redraw()

#endregion


#region Bodies

func _rebuild_bodies() -> void:
	if _walls:
		_walls.queue_free()
	for area in _module_areas:
		area.queue_free()
	_module_areas.clear()
	for area in _breach_areas.values():
		area.queue_free()
	_breach_areas.clear()
	# Solid cells, merged into one box per horizontal run.
	_walls = StaticBody2D.new()
	_walls.name = "Walls"
	_walls.collision_layer = wall_layer
	_walls.collision_mask = 0
	add_child(_walls)
	for y in internals.diameter:
		var start := -1
		for x in internals.length + 1:
			var solid := x < internals.length and not internals.is_walkable(Vector2i(x, y))
			if solid and start < 0:
				start = x
			elif not solid and start >= 0:
				_add_box(_walls, Rect2(Vector2(start, y) * cell_size, Vector2(x - start, 1) * cell_size))
				start = -1
	for i in internals.layout.modules.size():
		var rect := internals.layout.modules[i].rect
		var area := _make_area("Module%d" % i,
			Rect2(Vector2(rect.position) * cell_size, Vector2(rect.size) * cell_size).grow(cell_size * 0.25))
		area.body_entered.connect(func(body: Node2D) -> void: module_touched.emit(i, body))
		area.body_exited.connect(func(body: Node2D) -> void: module_untouched.emit(i, body))
		_module_areas.append(area)
	for cell in internals.breaches:
		_add_breach_area(cell)


func _add_breach_area(cell: Vector2i) -> void:
	if _breach_areas.has(cell):
		return
	var area := _make_area("Breach_%d_%d" % [cell.x, cell.y],
		Rect2(Vector2(cell) * cell_size, Vector2.ONE * cell_size).grow(cell_size * 0.25))
	area.body_entered.connect(func(body: Node2D) -> void: breach_touched.emit(cell, body))
	_breach_areas[cell] = area


func _make_area(area_name: String, rect: Rect2) -> Area2D:
	var area := Area2D.new()
	area.name = area_name
	area.collision_layer = 0
	area.collision_mask = crew_mask
	area.monitorable = false
	_add_box(area, rect)
	add_child(area)
	return area


func _add_box(body: CollisionObject2D, rect: Rect2) -> void:
	var shape := CollisionShape2D.new()
	var box := RectangleShape2D.new()
	box.size = rect.size
	shape.shape = box
	shape.position = rect.get_center()
	body.add_child(shape)

#endregion


#region Drawing

func _draw() -> void:
	if internals == null or not internals.is_node_ready():
		return
	var font := ThemeDB.fallback_font
	for y in internals.diameter:
		for x in internals.length:
			var cell := Vector2i(x, y)
			var rect := Rect2(Vector2(cell) * cell_size, Vector2.ONE * cell_size)
			match internals.get_cell(cell):
				ShipInternals.Cell.HULL:
					draw_rect(rect, HULL_COLOR)
				ShipInternals.Cell.WALL:
					draw_rect(rect, WALL_COLOR)
				ShipInternals.Cell.DOOR:
					draw_rect(rect, FLOOR_COLOR)
					draw_rect(rect.grow(-cell_size * 0.3), DOOR_COLOR)
				_:
					draw_rect(rect, FLOOR_COLOR)
					draw_rect(rect, FLOOR_LINE_COLOR, false, 1.0)
	if show_room_names:
		for room in internals.layout.rooms:
			# On the room's row nearest the middle of the hull, clear of the systems against the hull walls.
			var row := room.rect.end.y - 1 if room.rect.get_center().y < internals.diameter / 2.0 else room.rect.position.y
			var at := Vector2(room.rect.position.x, row) * cell_size + Vector2(3.0, cell_size * 0.7)
			draw_string(font, at, room.name, HORIZONTAL_ALIGNMENT_LEFT, room.rect.size.x * cell_size - 6.0,
				int(cell_size * 0.6), Color(0.6, 0.65, 0.7, 0.7))
	for i in internals.layout.modules.size():
		_draw_module(i, font)
	for cell in internals.breaches:
		_draw_breach(cell, internals.breaches[cell])
	for track in _tracks:
		var alpha: float = 1.0 - track[2] / TRACK_FADE
		draw_line(track[0] * cell_size, track[1] * cell_size, Color(TRACK_COLOR, alpha), 2.0)


func _draw_module(index: int, font: Font) -> void:
	var module := internals.layout.modules[index]
	var rect := Rect2(Vector2(module.rect.position) * cell_size, Vector2(module.rect.size) * cell_size).grow(-1.0)
	var condition := internals.get_module_condition(index)
	var color := module.color.darkened(0.6 * (1.0 - condition))
	if not internals.is_module_operational(index):
		color = Color(0.3, 0.12, 0.1)
	draw_rect(rect, color)
	draw_rect(rect, color.lightened(0.3), false, 1.0)
	if not internals.is_module_operational(index):
		draw_line(rect.position, rect.end, SPACE_BREACH_COLOR, 2.0)
		draw_line(Vector2(rect.end.x, rect.position.y), Vector2(rect.position.x, rect.end.y), SPACE_BREACH_COLOR, 2.0)
	draw_string(font, rect.position + Vector2(2.0, cell_size * 0.6), module.name, HORIZONTAL_ALIGNMENT_LEFT,
		rect.size.x - 4.0, int(cell_size * 0.5), Color(0.05, 0.05, 0.08))


func _draw_breach(cell: Vector2i, kind: ShipInternals.BreachKind) -> void:
	var centre := cell_to_local(cell)
	var color := WALL_BREACH_COLOR if kind == ShipInternals.BreachKind.WALL else SPACE_BREACH_COLOR
	# Holes open to space are black inside; holes in walls show the deck through them.
	draw_circle(centre, cell_size * 0.38, Color.BLACK if kind != ShipInternals.BreachKind.WALL else FLOOR_COLOR)
	draw_arc(centre, cell_size * 0.38, 0.0, TAU, 12, color, 2.0)

#endregion
