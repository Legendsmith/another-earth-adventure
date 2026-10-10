class_name ShipInternalsView
extends Node2D
## Top-down view of one deck of a ShipInternals (`deck`): hull, walls, doors and elevators, the modules (darkening as
## they are damaged), holes for the crew to patch and the tracks of rounds that bored through. It is a plain 2D scene,
## so it can be embedded in a SubViewport inside any other scene.
##
## It also gives crew a world to move in, for every deck at once. All decks share these coordinates, and each deck has
## its own physics layers, one for its walls (get_deck_layer) and one for its crew (get_crew_layer), so crew only meet
## the walls (and, if they collide with each other, the crew) of their own deck: hull, walls and modules are solid (a
## StaticBody2D per deck), each module and each hole has an Area2D that reports crew touching it,
## and ShipInternals.find_path finds routes over open deck and by elevator between decks (convert with cell_to_local
## and local_to_cell). Crew (ShipCrew) are drawn only on the deck shown.

signal module_touched(index: int, body: Node2D)
signal module_untouched(index: int, body: Node2D)
signal breach_touched(cell: Vector3i, body: Node2D)
signal deck_shown(deck: int)

## Seconds a round's track stays drawn.
const TRACK_FADE := 6.0
const FLOOR_COLOR := Color(0.13, 0.15, 0.18)
const FLOOR_LINE_COLOR := Color(0.18, 0.2, 0.24)
const HULL_COLOR := Color(0.55, 0.58, 0.62)
const WALL_COLOR := Color(0.36, 0.39, 0.44)
const DOOR_COLOR := Color(0.25, 0.45, 0.5)
const ELEVATOR_COLOR := Color(0.55, 0.45, 0.85)
const SPACE_BREACH_COLOR := Color(1.0, 0.25, 0.2)
const WALL_BREACH_COLOR := Color(1.0, 0.6, 0.2)
const TRACK_COLOR := Color(1.0, 0.85, 0.5)

## The internals shown. Left empty, the view makes its own with the default layout (handy for testing the scene).
@export var internals: ShipInternals
@export var cell_size: float = 16.0
## The deck shown.
@export var deck: int = 0:
	set = show_deck
## Physics layer (1-based) of the top deck's walls; each deck below takes the next layer, and the crew of each deck
## take the layers after those (first_deck_layer + ShipLayout.MAX_DECKS onwards). The default uses layers 9 to 24.
@export_range(1, 32) var first_deck_layer: int = 9
@export var show_room_names: bool = true

var _walls: Array[StaticBody2D] = []
var _module_areas: Array[Area2D] = []
var _breach_areas: Dictionary = {}
## Draws the modules, holes and tracks (see _draw_overlay).
var _overlay: Node2D
## Recent round tracks: [from (cells), to (cells), age (s)].
var _tracks: Array = []


func _ready() -> void:
	_overlay = Node2D.new()
	_overlay.name = "Overlay"
	_overlay.draw.connect(_draw_overlay)
	add_child(_overlay)
	move_child(_overlay, 0)
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
	show_deck(deck)


## Shows another deck.
func show_deck(new_deck: int) -> void:
	deck = new_deck
	if internals and internals.is_node_ready():
		deck = clampi(new_deck, 0, internals.decks - 1)
	queue_redraw()
	if _overlay:
		_overlay.queue_redraw()
	deck_shown.emit(deck)


## Physics layer bit of a deck's walls and modules: crew on the deck collide with it.
func get_deck_layer(on_deck: int) -> int:
	return 1 << clampi(first_deck_layer - 1 + on_deck, 0, 31)


## Physics layer bit of the crew on a deck: the deck's module and hole areas watch it.
func get_crew_layer(on_deck: int) -> int:
	return 1 << clampi(first_deck_layer - 1 + ShipLayout.MAX_DECKS + on_deck, 0, 31)


func get_size() -> Vector2:
	if internals == null:
		return Vector2.ZERO
	return Vector2(internals.length, internals.diameter) * cell_size


## Centre of a cell (any deck), in this node's coordinates.
func cell_to_local(cell: Vector3i) -> Vector2:
	return (Vector2(cell.x, cell.y) + Vector2(0.5, 0.5)) * cell_size


## The cell under a point on `on_deck` (the deck shown when < 0).
func local_to_cell(point: Vector2, on_deck: int = -1) -> Vector3i:
	var flat := Vector2i((point / cell_size).floor())
	return Vector3i(flat.x, flat.y, deck if on_deck < 0 else on_deck)


func _process(delta: float) -> void:
	if _tracks.is_empty():
		return
	for track in _tracks:
		track[3] += delta
	_tracks = _tracks.filter(func(track: Array) -> bool: return track[3] < TRACK_FADE)
	_overlay.queue_redraw()


#region Signals

func _connect(target: ShipInternals) -> void:
	target.breach_opened.connect(_on_breach_opened)
	target.breach_patched.connect(_on_breach_patched)
	target.module_damaged.connect(_on_module_changed)
	target.module_repaired.connect(_on_module_changed)
	target.round_tracked.connect(_on_round_tracked)
	target.layout_changed.connect(_on_layout_changed)


func _disconnect(target: ShipInternals) -> void:
	for connection in [[target.breach_opened, _on_breach_opened],
			[target.breach_patched, _on_breach_patched], [target.module_damaged, _on_module_changed],
			[target.module_repaired, _on_module_changed], [target.round_tracked, _on_round_tracked],
			[target.layout_changed, _on_layout_changed]]:
		if (connection[0] as Signal).is_connected(connection[1]):
			(connection[0] as Signal).disconnect(connection[1])


func _on_breach_opened(cell: Vector3i, _kind: ShipInternals.BreachKind) -> void:
	_add_breach_area(cell)
	_overlay.queue_redraw()


func _on_breach_patched(cell: Vector3i) -> void:
	if _breach_areas.has(cell):
		_breach_areas[cell].queue_free()
		_breach_areas.erase(cell)
	_overlay.queue_redraw()


func _on_module_changed(_index: int) -> void:
	_overlay.queue_redraw()


func _on_layout_changed() -> void:
	_tracks.clear()
	_rebuild_bodies()
	show_deck(deck)


func _on_round_tracked(on_deck: int, from: Vector2, to: Vector2) -> void:
	_tracks.append([on_deck, from, to, 0.0])
	_overlay.queue_redraw()

#endregion


#region Bodies

func _rebuild_bodies() -> void:
	for body in _walls:
		body.queue_free()
	_walls.clear()
	for area in _module_areas:
		area.queue_free()
	_module_areas.clear()
	for area in _breach_areas.values():
		area.queue_free()
	_breach_areas.clear()
	for on_deck in internals.decks:
		# Solid cells, merged into one box per horizontal run.
		var walls := StaticBody2D.new()
		walls.name = "Walls%d" % on_deck
		walls.collision_layer = get_deck_layer(on_deck)
		walls.collision_mask = 0
		add_child(walls)
		_walls.append(walls)
		for y in internals.diameter:
			var start := -1
			for x in internals.length + 1:
				var solid := x < internals.length and not internals.is_walkable(Vector3i(x, y, on_deck))
				if solid and start < 0:
					start = x
				elif not solid and start >= 0:
					_add_box(walls, Rect2(Vector2(start, y) * cell_size, Vector2(x - start, 1) * cell_size))
					start = -1
	for i in internals.get_module_count():
		var rect := internals.get_module(i).rect
		var area := _make_area("Module%d" % i, internals.get_module_deck(i),
			Rect2(Vector2(rect.position) * cell_size, Vector2(rect.size) * cell_size).grow(cell_size * 0.25))
		area.body_entered.connect(func(body: Node2D) -> void: module_touched.emit(i, body))
		area.body_exited.connect(func(body: Node2D) -> void: module_untouched.emit(i, body))
		_module_areas.append(area)
	for cell in internals.breaches:
		_add_breach_area(cell)


func _add_breach_area(cell: Vector3i) -> void:
	if _breach_areas.has(cell):
		return
	var area := _make_area("Breach_%d_%d_%d" % [cell.x, cell.y, cell.z], cell.z,
		Rect2(Vector2(cell.x, cell.y) * cell_size, Vector2.ONE * cell_size).grow(cell_size * 0.25))
	area.body_entered.connect(func(body: Node2D) -> void: breach_touched.emit(cell, body))
	_breach_areas[cell] = area


func _make_area(area_name: String, on_deck: int, rect: Rect2) -> Area2D:
	var area := Area2D.new()
	area.name = area_name
	area.collision_layer = 0
	area.collision_mask = get_crew_layer(on_deck)
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
			var cell := Vector3i(x, y, deck)
			var rect := Rect2(Vector2(x, y) * cell_size, Vector2.ONE * cell_size)
			match internals.get_cell(cell):
				ShipInternals.Cell.HULL:
					draw_rect(rect, HULL_COLOR)
				ShipInternals.Cell.WALL:
					draw_rect(rect, WALL_COLOR)
				ShipInternals.Cell.DOOR:
					draw_rect(rect, FLOOR_COLOR)
					draw_rect(rect.grow(-cell_size * 0.3), DOOR_COLOR)
				ShipInternals.Cell.ELEVATOR:
					draw_rect(rect, FLOOR_COLOR)
					draw_rect(rect.grow(-cell_size * 0.1), ELEVATOR_COLOR, false, 2.0)
					var up := internals.get_cell(cell - Vector3i(0, 0, 1)) == ShipInternals.Cell.ELEVATOR
					var down := internals.get_cell(cell + Vector3i(0, 0, 1)) == ShipInternals.Cell.ELEVATOR
					var c := rect.get_center()
					var h := cell_size * 0.25
					if up:
						draw_colored_polygon(PackedVector2Array([c + Vector2(0, -h * 1.4), c + Vector2(h, -h * 0.2),
							c + Vector2(-h, -h * 0.2)]), ELEVATOR_COLOR)
					if down:
						draw_colored_polygon(PackedVector2Array([c + Vector2(0, h * 1.4), c + Vector2(h, h * 0.2),
							c + Vector2(-h, h * 0.2)]), ELEVATOR_COLOR)
				_:
					draw_rect(rect, FLOOR_COLOR)
					draw_rect(rect, FLOOR_LINE_COLOR, false, 1.0)
	var rooms := internals.layout.get_deck(deck).rooms
	for room in rooms:
		var tint: Color = ShipRoom.ZONE_COLORS[room.zone]
		if tint.a > 0.0:
			draw_rect(Rect2(Vector2(room.rect.position) * cell_size, Vector2(room.rect.size) * cell_size), tint)
	if show_room_names:
		for room in rooms:
			# On the room's row nearest the middle of the hull, clear of the systems against the hull walls.
			var row := room.rect.end.y - 1 if room.rect.get_center().y < internals.diameter / 2.0 else room.rect.position.y
			var at := Vector2(room.rect.position.x, row) * cell_size + Vector2(3.0, cell_size * 0.7)
			draw_string(font, at, room.name, HORIZONTAL_ALIGNMENT_LEFT, room.rect.size.x * cell_size - 6.0,
				int(cell_size * 0.6), Color(0.6, 0.65, 0.7, 0.7))


## The changing part, on a child drawn over the deck and under the crew: modules, holes and round tracks. It redraws
## on its own as they change, while the deck itself only redraws for a new deck or layout.
func _draw_overlay() -> void:
	if internals == null or not internals.is_node_ready():
		return
	var font := ThemeDB.fallback_font
	for i in internals.get_module_count():
		if internals.get_module_deck(i) == deck:
			_draw_module(i, font)
	for cell: Vector3i in internals.breaches:
		if cell.z == deck:
			_draw_breach(cell, internals.breaches[cell])
	for track in _tracks:
		if track[0] == deck:
			var alpha: float = 1.0 - track[3] / TRACK_FADE
			_overlay.draw_line(track[1] * cell_size, track[2] * cell_size, Color(TRACK_COLOR, alpha), 2.0)


func _draw_module(index: int, font: Font) -> void:
	var module := internals.get_module(index)
	var rect := Rect2(Vector2(module.rect.position) * cell_size, Vector2(module.rect.size) * cell_size).grow(-1.0)
	var condition := internals.get_module_condition(index)
	var color := module.color.darkened(0.6 * (1.0 - condition))
	if not internals.is_module_operational(index):
		color = Color(0.3, 0.12, 0.1)
	_overlay.draw_rect(rect, color)
	_overlay.draw_rect(rect, color.lightened(0.3), false, 1.0)
	if internals.is_fuel_tank(index):
		# Self-sealing compartments.
		var x := rect.position.x + cell_size
		while x < rect.end.x - 1.0:
			_overlay.draw_line(Vector2(x, rect.position.y), Vector2(x, rect.end.y), color.darkened(0.35), 1.0)
			x += cell_size
	if not internals.is_module_operational(index):
		_overlay.draw_line(rect.position, rect.end, SPACE_BREACH_COLOR, 2.0)
		_overlay.draw_line(Vector2(rect.end.x, rect.position.y), Vector2(rect.position.x, rect.end.y),
			SPACE_BREACH_COLOR, 2.0)
	_overlay.draw_string(font, rect.position + Vector2(2.0, cell_size * 0.6), module.name, HORIZONTAL_ALIGNMENT_LEFT,
		rect.size.x - 4.0, int(cell_size * 0.5), Color(0.05, 0.05, 0.08))


func _draw_breach(cell: Vector3i, kind: ShipInternals.BreachKind) -> void:
	var centre := cell_to_local(cell)
	var to_space := ShipInternals.is_open_to_space(kind)
	var color := SPACE_BREACH_COLOR if to_space else WALL_BREACH_COLOR
	# Holes open to space are black inside; holes in walls and floors show the deck through them.
	_overlay.draw_circle(centre, cell_size * 0.38, Color.BLACK if to_space else FLOOR_COLOR)
	_overlay.draw_arc(centre, cell_size * 0.38, 0.0, TAU, 12, color, 2.0)

#endregion
