class_name ShipLayout
extends Resource
## Deck plans of a ship modelled as a cylindrical tube, `length` cells long and `diameter` cells across.
##
## The tube is cut into `decks` levels stacked from the top down (each a horizontal slice of the tube, seen from above:
## x runs from the stern (0) to the bow, y across the hull). On every deck the outer border is the hull wall. Internal
## walls are rectangles of wall cells, doors are gaps in them, elevators link a cell to the same cell on the decks above
## and below, modules are placed on solid rectangles (ModulePlacement) and rooms are named zones of open deck (cargo,
## crew quarters, mess...). Everything else is open deck the crew walk on. A ModularHull builds itself from its layout.

## Most decks a layout can have (each deck's crew and walls get their own physics layer).
const MAX_DECKS := 8

@export var length: int = 40
@export var diameter: int = 12
## Armor thickness (depth steps) for a ModularHull with no armor of its own (which otherwise sets it from its armor).
@export var armor_thickness: int = 6
@export var decks: Array[ShipDeck] = []


## Cells around the hull's circumference: the height of the armor surface image.
func get_circumference() -> int:
	return maxi(roundi(PI * diameter), 1)


func get_deck_count() -> int:
	return clampi(decks.size(), 1, MAX_DECKS)


## The deck at `index`, created empty if the layout has none yet.
func get_deck(index: int) -> ShipDeck:
	if decks.is_empty():
		decks.append(ShipDeck.new())
	return decks[clampi(index, 0, decks.size() - 1)]


## A basic gunship on two decks. Each deck has a corridor down the middle of the tube, bulkheads every eight cells with
## doors on the corridor, and rooms on both sides, linked by elevators at both ends of the corridor. Systems sit against
## the hull walls with a row of open deck between them and the corridor; cargo holds, crew quarters, the mess and the
## corridors are empty, so many hits only hole the deck and walls. The main drive is two fusion engines, one per deck,
## each with half the thrust of a full fusion drive. Thrusters have no place: they are spread through the hull (see
## ModularHull.get_thruster_performance). Every module is placed on its base size.
static func create_default() -> ShipLayout:
	var layout := ShipLayout.new()
	layout.length = 40
	layout.diameter = 12

	var main := _add_deck(layout, "Main deck")
	_add_room(main, "Engineering", Rect2i(1, 1, 7, 3))
	_add_room(main, "Aft Cargo Hold", Rect2i(1, 8, 7, 3), ShipRoom.Zone.CARGO)
	_add_room(main, "Reactor Room", Rect2i(9, 1, 7, 3))
	_add_room(main, "Fuel Store", Rect2i(9, 8, 7, 3))
	_add_room(main, "Magazine", Rect2i(17, 1, 7, 3))
	_add_room(main, "Gun Deck", Rect2i(17, 8, 7, 3))
	_add_room(main, "Crew Quarters", Rect2i(25, 1, 7, 3), ShipRoom.Zone.CREW_QUARTERS)
	_add_room(main, "Mess", Rect2i(25, 8, 7, 3), ShipRoom.Zone.MESS)
	_add_room(main, "Bridge", Rect2i(33, 1, 6, 3))
	_add_room(main, "Sensor Bay", Rect2i(33, 8, 6, 3))
	_add_room(main, "Corridor", Rect2i(1, 5, 38, 2), ShipRoom.Zone.CORRIDOR)
	_add_module(main, _half_fusion_drive(), Rect2i(1, 1, 4, 2), 12)
	var reactor := _module("Reactor", ShipModule.Kind.REACTOR, Color(0.4, 0.85, 0.5))
	reactor.power_output = 40.0
	_add_module(main, reactor, Rect2i(10, 1, 3, 2), 16)
	# The fuel tank fills its store, wall to wall.
	_add_module(main, _module("Fuel Tank", ShipModule.Kind.FUEL_TANK, Color(0.75, 0.7, 0.3)), Rect2i(9, 9, 7, 2), 1)
	_add_module(main, _module("Torpedo Magazine", ShipModule.Kind.MAGAZINE, Color(0.85, 0.35, 0.35)),
		Rect2i(17, 1, 3, 2), 8)
	var tubes := TorpedoLauncher.new()
	tubes.color = Color(0.75, 0.45, 0.4)
	_add_module(main, tubes, Rect2i(22, 1, 2, 2), 8)
	var railgun := Railgun.new()
	railgun.color = Color(0.5, 0.6, 0.9)
	_add_module(main, railgun, Rect2i(17, 9, 5, 2), 12)
	_add_module(main, _module("Bridge", ShipModule.Kind.BRIDGE, Color(0.55, 0.8, 0.95)), Rect2i(37, 1, 2, 2), 10)
	_add_module(main, _module("Sensors", ShipModule.Kind.SENSORS, Color(0.6, 0.5, 0.9)), Rect2i(37, 9, 2, 2), 6)

	var lower := _add_deck(layout, "Lower deck")
	_add_room(lower, "Lower Engineering", Rect2i(1, 1, 7, 3))
	_add_room(lower, "Aft Hold", Rect2i(1, 8, 7, 3), ShipRoom.Zone.CARGO)
	_add_room(lower, "Cargo Hold", Rect2i(9, 1, 7, 3), ShipRoom.Zone.CARGO)
	_add_room(lower, "Cargo Hold", Rect2i(9, 8, 7, 3), ShipRoom.Zone.CARGO)
	_add_room(lower, "Bunks", Rect2i(17, 1, 7, 3), ShipRoom.Zone.CREW_QUARTERS)
	_add_room(lower, "Bunks", Rect2i(17, 8, 7, 3), ShipRoom.Zone.CREW_QUARTERS)
	_add_room(lower, "Stores", Rect2i(25, 1, 7, 3), ShipRoom.Zone.CARGO)
	_add_room(lower, "Galley", Rect2i(25, 8, 7, 3), ShipRoom.Zone.MESS)
	_add_room(lower, "Workshop", Rect2i(33, 1, 6, 3))
	_add_room(lower, "Forward Hold", Rect2i(33, 8, 6, 3), ShipRoom.Zone.CARGO)
	_add_room(lower, "Corridor", Rect2i(1, 5, 38, 2), ShipRoom.Zone.CORRIDOR)
	_add_module(lower, _half_fusion_drive(), Rect2i(1, 1, 4, 2), 12)
	return layout


static func _add_deck(layout: ShipLayout, deck_name: String) -> ShipDeck:
	var deck := ShipDeck.new()
	deck.name = deck_name
	# Walls between the rooms and the corridor (rows 4 and 7).
	deck.walls.append(Rect2i(1, 4, 38, 1))
	deck.walls.append(Rect2i(1, 7, 38, 1))
	for x in [8, 16, 24, 32]:
		deck.walls.append(Rect2i(x, 1, 1, 10))
		# Corridor doors through the bulkhead.
		deck.doors.append(Vector2i(x, 5))
		deck.doors.append(Vector2i(x, 6))
	# One door from the corridor into each room.
	for x in [6, 14, 21, 28, 35]:
		deck.doors.append(Vector2i(x, 4))
		deck.doors.append(Vector2i(x, 7))
	# Elevators at both ends of the corridor.
	deck.elevators.append(Vector2i(3, 5))
	deck.elevators.append(Vector2i(36, 6))
	layout.decks.append(deck)
	return deck


static func _add_room(deck: ShipDeck, room_name: String, rect: Rect2i,
		zone: ShipRoom.Zone = ShipRoom.Zone.GENERAL) -> void:
	var room := ShipRoom.new()
	room.name = room_name
	room.zone = zone
	room.rect = rect
	deck.rooms.append(room)


## Places `module` on `rect`, sized to it (so it gets no size bonus), with `hits_to_kill`.
static func _add_module(deck: ShipDeck, module: ShipModule, rect: Rect2i, hits_to_kill: int) -> ShipModule:
	module.size = rect.get_area()
	module.hits_to_kill = hits_to_kill
	var placement := ModulePlacement.new()
	placement.module = module
	placement.rect = rect
	deck.modules.append(placement)
	return module


static func _module(module_name: String, kind: ShipModule.Kind, color: Color) -> ShipModule:
	var module := ShipModule.new()
	module.name = module_name
	module.kind = kind
	module.color = color
	return module


## Half a fusion drive: the default layout's main drive is two of them.
static func _half_fusion_drive() -> EngineModule:
	var engine := load("res://data/engines/fusion_drive.tres").duplicate() as EngineModule
	engine.max_thrust /= 2.0
	engine.mass /= 2.0
	engine.power_generation /= 2.0
	engine.active_sensor_signature /= 2.0
	engine.max_sensor_signature /= 2.0
	engine.color = Color(0.85, 0.55, 0.3)
	return engine
