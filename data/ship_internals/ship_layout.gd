class_name ShipLayout
extends Resource
## Deck plans of a ship modelled as a cylindrical tube, `length` cells long and `diameter` cells across.
##
## The tube is cut into `decks` levels stacked from the top down (each a horizontal slice of the tube, seen from above:
## x runs from the stern (0) to the bow, y across the hull). On every deck the outer border is the hull wall. Internal
## walls are rectangles of wall cells, doors are gaps in them, elevators link a cell to the same cell on the decks above
## and below, modules are solid rectangles of systems and rooms are named zones of open deck (cargo, crew quarters,
## mess...). Everything else is open deck the crew walk on.

## Most decks a layout can have (each deck's crew and walls get their own physics layer).
const MAX_DECKS := 8

@export var length: int = 40
@export var diameter: int = 12
## Armor thickness (depth steps) when the internals are not on a CombatHull, which sets it from its own armor.
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
## corridors are empty, so many hits only hole the deck and walls. The main drive is two engine modules, one per deck.
## Thrusters have no module: they are spread through the hull (see ShipInternals.get_thruster_performance).
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
	_add_module(main, "Main Engine", Rect2i(1, 1, 4, 2), Color(0.85, 0.55, 0.3), 12)
	_add_module(main, "Reactor", Rect2i(10, 1, 3, 2), Color(0.4, 0.85, 0.5), 16)
	# The fuel tank fills its store, wall to wall.
	_add_module(main, "Fuel Tank", Rect2i(9, 9, 7, 2), Color(0.75, 0.7, 0.3)).type = ShipModule.Type.FUEL_TANK
	_add_module(main, "Torpedo Magazine", Rect2i(17, 1, 3, 2), Color(0.85, 0.35, 0.35), 8)
	_add_module(main, "Torpedo Tubes", Rect2i(22, 1, 2, 2), Color(0.75, 0.45, 0.4), 8)
	_add_module(main, "Railgun", Rect2i(17, 9, 5, 2), Color(0.5, 0.6, 0.9), 12)
	_add_module(main, "Bridge", Rect2i(37, 1, 2, 2), Color(0.55, 0.8, 0.95), 10)
	_add_module(main, "Sensors", Rect2i(37, 9, 2, 2), Color(0.6, 0.5, 0.9), 6)

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
	_add_module(lower, "Main Engine", Rect2i(1, 1, 4, 2), Color(0.85, 0.55, 0.3), 12)
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


static func _add_module(deck: ShipDeck, module_name: String, rect: Rect2i, color: Color,
		hit_points: int = 10) -> ShipModule:
	var module := ShipModule.new()
	module.name = module_name
	module.component_name = module_name
	module.rect = rect
	module.color = color
	module.hit_points = hit_points
	deck.modules.append(module)
	return module
