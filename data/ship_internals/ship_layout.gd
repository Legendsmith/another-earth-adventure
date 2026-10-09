class_name ShipLayout
extends Resource
## Deck plan of a ship modelled as a cylindrical tube, `length` cells long and `diameter` cells across.
##
## The plan is the tube cut open along its deck and seen from above: x runs from the stern (0) to the bow, y across
## the hull. The outer border is the hull wall. Internal walls are rectangles of wall cells, doors are gaps in them,
## modules are solid rectangles of systems and rooms are named zones of open deck (cargo, crew quarters, mess...).
## Everything else is open deck the crew walk on.

@export var length: int = 40
@export var diameter: int = 12
## Armor thickness (depth steps) when the internals are not on a CombatHull, which sets it from its own armor.
@export var armor_thickness: int = 6
@export var walls: Array[Rect2i] = []
@export var doors: Array[Vector2i] = []
@export var modules: Array[ShipModule] = []
@export var rooms: Array[ShipRoom] = []


## Cells around the hull's circumference: the height of the armor surface image.
func get_circumference() -> int:
	return maxi(roundi(PI * diameter), 1)


## A basic gunship layout: a corridor down the middle of the tube, bulkheads every eight cells with doors on the
## corridor, and rooms on both sides. Systems sit against the hull walls with a row of open deck between them and the
## corridor; the cargo hold, crew quarters, mess and corridor are empty, so many hits only hole the deck and walls.
## Thrusters have no module: they are spread through the hull (see ShipInternals.get_thruster_performance).
static func create_default() -> ShipLayout:
	var layout := ShipLayout.new()
	layout.length = 40
	layout.diameter = 12
	# Walls between the rooms and the corridor (rows 4 and 7).
	layout.walls.append(Rect2i(1, 4, 38, 1))
	layout.walls.append(Rect2i(1, 7, 38, 1))
	for x in [8, 16, 24, 32]:
		layout.walls.append(Rect2i(x, 1, 1, 10))
		# Corridor doors through the bulkhead.
		layout.doors.append(Vector2i(x, 5))
		layout.doors.append(Vector2i(x, 6))
	# One door from the corridor into each room.
	for x in [6, 14, 21, 28, 35]:
		layout.doors.append(Vector2i(x, 4))
		layout.doors.append(Vector2i(x, 7))
	_add_room(layout, "Engineering", Rect2i(1, 1, 7, 3))
	_add_room(layout, "Aft Cargo Hold", Rect2i(1, 8, 7, 3), ShipRoom.Zone.CARGO)
	_add_room(layout, "Reactor Room", Rect2i(9, 1, 7, 3))
	_add_room(layout, "Fuel Store", Rect2i(9, 8, 7, 3))
	_add_room(layout, "Magazine", Rect2i(17, 1, 7, 3))
	_add_room(layout, "Gun Deck", Rect2i(17, 8, 7, 3))
	_add_room(layout, "Crew Quarters", Rect2i(25, 1, 7, 3), ShipRoom.Zone.CREW_QUARTERS)
	_add_room(layout, "Mess", Rect2i(25, 8, 7, 3), ShipRoom.Zone.MESS)
	_add_room(layout, "Bridge", Rect2i(33, 1, 6, 3))
	_add_room(layout, "Sensor Bay", Rect2i(33, 8, 6, 3))
	_add_room(layout, "Corridor", Rect2i(1, 5, 38, 2), ShipRoom.Zone.CORRIDOR)
	_add_module(layout, "Main Engine", Rect2i(1, 1, 4, 2), Color(0.85, 0.55, 0.3), 2)
	_add_module(layout, "Reactor", Rect2i(10, 1, 3, 2), Color(0.4, 0.85, 0.5), 2)
	# The fuel tank fills its store, wall to wall.
	_add_module(layout, "Fuel Tank", Rect2i(9, 9, 7, 2), Color(0.75, 0.7, 0.3)).type = ShipModule.Type.FUEL_TANK
	_add_module(layout, "Torpedo Magazine", Rect2i(17, 1, 3, 2), Color(0.85, 0.35, 0.35))
	_add_module(layout, "Torpedo Tubes", Rect2i(22, 1, 2, 2), Color(0.75, 0.45, 0.4))
	_add_module(layout, "Railgun", Rect2i(17, 9, 5, 2), Color(0.5, 0.6, 0.9), 2)
	_add_module(layout, "Bridge", Rect2i(37, 1, 2, 2), Color(0.55, 0.8, 0.95))
	_add_module(layout, "Sensors", Rect2i(37, 9, 2, 2), Color(0.6, 0.5, 0.9))
	return layout


static func _add_room(layout: ShipLayout, room_name: String, rect: Rect2i,
		zone: ShipRoom.Zone = ShipRoom.Zone.GENERAL) -> void:
	var room := ShipRoom.new()
	room.name = room_name
	room.zone = zone
	room.rect = rect
	layout.rooms.append(room)


static func _add_module(layout: ShipLayout, module_name: String, rect: Rect2i, color: Color,
		hit_points: int = 1) -> ShipModule:
	var module := ShipModule.new()
	module.name = module_name
	module.component_name = module_name
	module.rect = rect
	module.color = color
	module.hit_points = hit_points
	layout.modules.append(module)
	return module


## Wall cells as a set (Vector2i -> true), from the wall rectangles.
func get_wall_cells() -> Dictionary:
	var result := {}
	for rect in walls:
		for y in range(rect.position.y, rect.end.y):
			for x in range(rect.position.x, rect.end.x):
				result[Vector2i(x, y)] = true
	return result


## Replaces the walls with `cells` (a set of Vector2i), stored as one rectangle per horizontal run.
func set_wall_cells(cells: Dictionary) -> void:
	walls.clear()
	var sorted: Array = cells.keys()
	sorted.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return a.y < b.y or (a.y == b.y and a.x < b.x))
	for cell: Vector2i in sorted:
		if not walls.is_empty():
			var last := walls[-1]
			if last.position.y == cell.y and last.end.x == cell.x:
				walls[-1] = Rect2i(last.position, last.size + Vector2i(1, 0))
				continue
		walls.append(Rect2i(cell, Vector2i.ONE))
