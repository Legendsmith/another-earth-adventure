class_name ShipInternals
extends Node
## The inside of a ship: its armor surface, its decks and the modules on them, and the damage done to them.
##
## The hull is a cylindrical tube, cut into decks stacked from the top down. Hits strike the armor surface
## (HullArmorSurface, the tube unrolled into armor columns) and dig a crater; points that get through carry on inside.
## A kinetic penetrator flies straight on through the tube and spends a point on everything it hits: every wall cell,
## every floor between decks and every module cell on its path (so it may clip a module or bore down its whole
## length). It holes the hull where it enters, and if it still has points left at the far side it digs its way out.
## An explosive hit bursts just inside the hole it blew, hitting every cell around it. So rounds through cargo holds,
## crew quarters and corridors only leave holes for the crew to patch, and a ship is crippled long before it is
## destroyed: it only breaks up once nearly all of its frame is holed.
##
## Some systems are spread through the ship rather than knocked out at once: fuel tanks are compartmentalised and
## self-sealing, so hits on them only lose a little fuel; thrusters have no module at all, but weaken as the frame they
## are mounted on is holed (see get_thruster_performance); and a system built from several modules (a main drive of
## four engines) loses an equal share of its performance with each module wrecked (see get_component_effectiveness).
##
## Add it as a child of a CombatHull to take over the hull's armor and internal damage (see CombatHull.internals):
## modules then stand for the hull's components of the same name. On its own it works as a standalone model (tests,
## demo scenes). Show it with a ShipInternalsView and an ArmorSurfaceRect; crew live in a ShipCrew.
##
## Cells are addressed as Vector3i(x, y, deck).

signal armor_changed
signal breach_opened(cell: Vector3i, kind: BreachKind)
signal breach_patched(cell: Vector3i)
signal module_damaged(index: int)
signal module_destroyed(index: int)
signal module_repaired(index: int)
## A round's path across one deck, in cells (where it entered the deck to where it left it or stopped).
signal round_tracked(deck: int, from: Vector2, to: Vector2)
## A hit on a fuel tank module lost `fraction` of the ship's fuel capacity before the tank sealed.
signal fuel_leaked(index: int, fraction: float)
signal thrusters_changed(performance: float)
signal main_engine_changed(performance: float)
## A new layout was set (set_layout): everything was rebuilt and all damage cleared.
signal layout_changed

enum Cell { DECK, HULL, WALL, DOOR, ELEVATOR }
## Where a hole is. HULL and DECK breaches are open to space: through the hull wall at the side of a deck, or through
## the hull above the top deck or below the bottom one. WALL breaches are in internal walls, FLOOR breaches in the
## floor between two decks (on the deck below the hole).
enum BreachKind { HULL, WALL, DECK, FLOOR }

const NO_MODULE := -1
const NO_POINT := Vector3(-1.0, -1.0, -1.0)
## Path cost of riding an elevator one deck, in cells walked.
const ELEVATOR_COST := 2.0

@export var layout: ShipLayout
## Share of the frame (hull and wall cells) that must stay intact; when more is holed the ship breaks up.
@export_range(0.0, 1.0, 0.01) var breakup_integrity: float = 0.05
## Spread (radians, standard deviation) of the height rounds hit at: the space view is flat, so it is random.
@export var vertical_spread: float = 0.35
## Share of the fuel capacity a fuel tank loses per point of damage before it self-seals.
@export_range(0.0, 0.2, 0.001) var fuel_loss_per_hit: float = 0.01

@export_group("Thrusters")
## Thrusters keep full performance while the frame integrity is at least this.
@export_range(0.0, 1.0, 0.01) var thruster_full_integrity: float = 0.5
## Thrusters are dead once the frame integrity falls to this.
@export_range(0.0, 1.0, 0.01) var thruster_dead_integrity: float = 0.1
## Shape of the fall-off between the two, as Godot's ease() curve: below 1 the thrust fades slowly at first and drops
## off faster and faster as the frame nears the dead level (0.5 = 1 - (1 - t)^2).
@export_exp_easing var thruster_ease: float = 0.5

var hull: CombatHull
var armor: HullArmorSurface
var length: int
var diameter: int
var radius: float
var decks: int
## Every module of every deck, in deck order.
var modules: Array[ShipModule] = []
## Deck of each module.
var module_decks: PackedInt32Array
## Damage taken by each module.
var module_damage: PackedInt32Array
## Open holes: Vector3i cell -> BreachKind.
var breaches: Dictionary = {}
## Paths over open deck and between decks by elevator: hull, walls and modules are solid, doors are open.
var nav: AStar3D
var rng := RandomNumberGenerator.new()
## Fuel lost to hits on fuel tanks, as a share of the fuel capacity.
var fuel_lost := 0.0
var thruster_performance := 1.0
var main_engine_performance := 1.0

## Cell type of each cell, deck by deck, row-major.
var _cells: PackedByteArray
## Module covering each cell (NO_MODULE for none).
var _module_at: PackedInt32Array
var _frame_cells := 0
## Frame cells ever holed: patching seals a hole but does not restore the frame's strength.
var _damaged_frame: Dictionary = {}
## CombatHull component index of each module (-1 for none).
var _component_index: PackedInt32Array
## Point (x, y, deck) that internal blasts start from (the module that just blew up), or NO_POINT for a random one.
var _blast_origin := NO_POINT
## The ship's undamaged engines: the ship gets its own copies, scaled by the performance of their modules.
var _base_thrusters: EngineDefinition
var _base_main_engine: EngineDefinition


func _ready() -> void:
	rng.randomize()
	if layout == null:
		layout = ShipLayout.create_default()
	hull = get_parent() as CombatHull
	if hull:
		hull.internals = self
	_build()


#region Setup

## Replaces the layout (the layout editor's live preview): rebuilds the decks and armor and clears all damage.
func set_layout(new_layout: ShipLayout) -> void:
	layout = new_layout if new_layout else ShipLayout.create_default()
	_build()
	layout_changed.emit()


func _build() -> void:
	breaches.clear()
	_damaged_frame.clear()
	fuel_lost = 0.0
	length = maxi(layout.length, 3)
	diameter = maxi(layout.diameter, 3)
	radius = diameter / 2.0
	decks = layout.get_deck_count()
	var thickness := layout.armor_thickness
	if hull:
		# The same depth as the hull's armor grid: armor mass spread over its columns.
		thickness = hull.armor.layers_for(hull.armor_mass, maxi(hull.armor_columns, 1)) if hull.armor else 0
	armor = HullArmorSurface.new(length, layout.get_circumference(), thickness)
	var count := length * diameter * decks
	_cells = PackedByteArray()
	_cells.resize(count)
	_cells.fill(Cell.DECK)
	_module_at = PackedInt32Array()
	_module_at.resize(count)
	_module_at.fill(NO_MODULE)
	modules.clear()
	module_decks = PackedInt32Array()
	for deck in decks:
		var plan := layout.get_deck(deck)
		for y in diameter:
			for x in length:
				if x == 0 or y == 0 or x == length - 1 or y == diameter - 1:
					_cells[_index(Vector3i(x, y, deck))] = Cell.HULL
		for rect in plan.walls:
			for cell in _cells_in(rect, deck):
				if get_cell(cell) == Cell.DECK:
					_cells[_index(cell)] = Cell.WALL
		for door in plan.doors:
			var cell := Vector3i(door.x, door.y, deck)
			if _in_bounds(cell) and get_cell(cell) == Cell.WALL:
				_cells[_index(cell)] = Cell.DOOR
		for elevator in plan.elevators:
			var cell := Vector3i(elevator.x, elevator.y, deck)
			if _in_bounds(cell) and get_cell(cell) == Cell.DECK:
				_cells[_index(cell)] = Cell.ELEVATOR
		for module in plan.modules:
			var index := modules.size()
			modules.append(module)
			module_decks.append(deck)
			for cell in _cells_in(module.rect, deck):
				if get_cell(cell) == Cell.DECK:
					_module_at[_index(cell)] = index
	module_damage = PackedInt32Array()
	module_damage.resize(modules.size())
	_component_index = PackedInt32Array()
	_component_index.resize(modules.size())
	for i in modules.size():
		var component_name := modules[i].component_name
		_component_index[i] = hull.find_component(component_name) if hull and component_name else -1
	_frame_cells = 0
	for value in _cells:
		if value == Cell.HULL or value == Cell.WALL:
			_frame_cells += 1
	_build_nav()
	_update_engines()


func _build_nav() -> void:
	nav = AStar3D.new()
	nav.reserve_space(length * diameter * decks)
	for deck in decks:
		for y in diameter:
			for x in length:
				var cell := Vector3i(x, y, deck)
				if is_walkable(cell):
					nav.add_point(_index(cell), Vector3(x + 0.5, y + 0.5, deck * ELEVATOR_COST))
	for deck in decks:
		for y in diameter:
			for x in length:
				var cell := Vector3i(x, y, deck)
				if not is_walkable(cell):
					continue
				# Right, down and the two diagonals below: every pair once. Diagonals only past open corners.
				for offset: Vector3i in [Vector3i(1, 0, 0), Vector3i(0, 1, 0), Vector3i(1, 1, 0), Vector3i(-1, 1, 0)]:
					var other := cell + offset
					if not is_walkable(other):
						continue
					if offset.x != 0 and offset.y != 0 and not (is_walkable(cell + Vector3i(offset.x, 0, 0))
							and is_walkable(cell + Vector3i(0, offset.y, 0))):
						continue
					nav.connect_points(_index(cell), _index(other))
				if get_cell(cell) == Cell.ELEVATOR and get_cell(cell + Vector3i(0, 0, 1)) == Cell.ELEVATOR:
					nav.connect_points(_index(cell), _index(cell + Vector3i(0, 0, 1)))

#endregion


#region Queries

func get_cell(cell: Vector3i) -> Cell:
	return _cells[_index(cell)] as Cell if _in_bounds(cell) else Cell.HULL


func get_module_at(cell: Vector3i) -> int:
	return _module_at[_index(cell)] if _in_bounds(cell) else NO_MODULE


## Open deck, a door or an elevator, with no module on it.
func is_walkable(cell: Vector3i) -> bool:
	var value := get_cell(cell)
	return (value == Cell.DECK or value == Cell.DOOR or value == Cell.ELEVATOR) and get_module_at(cell) == NO_MODULE


func get_module(index: int) -> ShipModule:
	return modules[index]


func get_module_count() -> int:
	return modules.size()


func get_module_deck(index: int) -> int:
	return module_decks[index]


func get_module_hit_points(index: int) -> int:
	return maxi(modules[index].hit_points, 1)


## Fuel tanks are never knocked out.
func is_module_operational(index: int) -> bool:
	return is_fuel_tank(index) or module_damage[index] < get_module_hit_points(index)


func is_fuel_tank(index: int) -> bool:
	return modules[index].type == ShipModule.Type.FUEL_TANK


## 0 (wrecked) .. 1 (undamaged).
func get_module_condition(index: int) -> float:
	if is_fuel_tank(index):
		return 1.0
	return 1.0 - float(module_damage[index]) / get_module_hit_points(index)


## Share of a hull component's performance its modules still give (1 when it has no modules): each module carries an
## equal share, so a main drive of four engine modules runs at 75% with one of them wrecked.
func get_component_effectiveness(component_index: int) -> float:
	var total := 0
	var working := 0
	for i in modules.size():
		if _component_index[i] == component_index:
			total += 1
			if is_module_operational(i):
				working += 1
	return float(working) / total if total > 0 else 1.0


## Walkable cells next to a module, where crew stand to touch it.
func get_access_cells(index: int) -> Array[Vector3i]:
	var access: Array[Vector3i] = []
	var rect := modules[index].rect
	for cell in _cells_in(rect.grow(1), module_decks[index]):
		if is_walkable(cell) and not rect.has_point(Vector2i(cell.x, cell.y)):
			access.append(cell)
	return access


## Every walkable cell of a deck (all decks when `deck` < 0).
func get_walkable_cells(deck: int = -1) -> Array[Vector3i]:
	var result: Array[Vector3i] = []
	for d in decks:
		if deck >= 0 and d != deck:
			continue
		for y in diameter:
			for x in length:
				if is_walkable(Vector3i(x, y, d)):
					result.append(Vector3i(x, y, d))
	return result


## Walkable cells of every room of `zone`.
func get_zone_cells(zone: ShipRoom.Zone) -> Array[Vector3i]:
	var result: Array[Vector3i] = []
	for deck in decks:
		for room in layout.get_deck(deck).rooms:
			if room.zone != zone:
				continue
			for cell in _cells_in(room.rect, deck):
				if is_walkable(cell):
					result.append(cell)
	return result


## Path over open deck between two cells, riding elevators between decks (empty when there is none).
func find_path(from: Vector3i, to: Vector3i) -> Array[Vector3i]:
	var result: Array[Vector3i] = []
	if not is_walkable(from) or not is_walkable(to):
		return result
	for id in nav.get_id_path(_index(from), _index(to)):
		result.append(_cell_of(id))
	return result


func is_breached(cell: Vector3i) -> bool:
	return breaches.has(cell)


static func is_open_to_space(kind: BreachKind) -> bool:
	return kind == BreachKind.HULL or kind == BreachKind.DECK


## Holes open to space (hull and deck breaches).
func get_hull_breach_count() -> int:
	var count := 0
	for kind in breaches.values():
		if is_open_to_space(kind):
			count += 1
	return count


## Share of the frame never holed: hull and wall cells, counting holes through the hull above and below the decks and
## the floors between them as frame too. The ship breaks up below breakup_integrity.
func get_frame_integrity() -> float:
	return 1.0 - minf(float(_damaged_frame.size()) / maxi(_frame_cells, 1), 1.0)


## Thrust of the ship's thrusters, 0..1. They are mounted all over the hull, so no single hit knocks them out: they
## keep full thrust while the frame is at least thruster_full_integrity, then fade along the thruster_ease curve, more
## and more steeply, to nothing at thruster_dead_integrity.
func get_thruster_performance() -> float:
	var t := inverse_lerp(thruster_dead_integrity, thruster_full_integrity, get_frame_integrity())
	return ease(clampf(t, 0.0, 1.0), thruster_ease)


## Thrust of the main drive, 0..1: the share of its engine modules still working.
func get_main_engine_performance() -> float:
	if hull:
		for i in hull.components.size():
			if hull.components[i].kind == ShipComponent.Kind.MAIN_ENGINE:
				return get_component_effectiveness(i)
		return 1.0
	# Standalone: the modules named like the default layout's engines.
	var total := 0
	var working := 0
	for i in modules.size():
		if modules[i].component_name == "Main Engine":
			total += 1
			working += 1 if is_module_operational(i) else 0
	return float(working) / total if total > 0 else 1.0

#endregion


#region Damage

## A hit of `damage` points with `profile`, its round travelling along `direction` (the hull's world space when on a
## CombatHull, else the deck's: +x towards the bow). A zero direction comes from anywhere. Returns the points that got
## through the armor.
func resolve_hit(damage: int, profile: ArmorGrid.DamageProfile = ArmorGrid.DamageProfile.KINETIC,
		direction: Vector2 = Vector2.ZERO) -> int:
	if damage <= 0:
		return 0
	var path := _find_round_path(_to_hull_direction(direction))
	var entry: Vector3 = path[0]
	var exit: Vector3 = path[1]
	var entry_column := _armor_column(entry)
	var points := armor.apply_crater(entry_column.x, entry_column.y, damage, profile)
	if points > 0:
		_breach_hull_at(entry)
		if profile == ArmorGrid.DamageProfile.KINETIC:
			_trace_round(entry, exit, points)
		else:
			var point := _deck_point(entry)
			_blast(Vector3(point.x, point.y, _deck_of(entry)), points)
	armor.update_texture()
	armor_changed.emit()
	_check_breakup()
	return points


## Damage from inside the ship (a magazine cooking off): a blast centred on the module that just blew up, or on a random
## spot of open deck.
func apply_internal_damage(points: int) -> void:
	var origin := _blast_origin
	if origin == NO_POINT:
		origin = Vector3(rng.randi_range(1, length - 2) + 0.5, rng.randi_range(1, diameter - 2) + 0.5,
			rng.randi_range(0, decks - 1))
	_blast(origin, points)
	_check_breakup()


## Adds damage to a module. On a CombatHull it also damages the module's component (and may knock out its system).
func damage_module(index: int, points: int = 1) -> void:
	if points <= 0:
		return
	if is_fuel_tank(index):
		_leak_fuel(index, points)
		return
	if not is_module_operational(index):
		return
	module_damage[index] = mini(module_damage[index] + points, get_module_hit_points(index))
	module_damaged.emit(index)
	if is_module_operational(index):
		return
	module_destroyed.emit(index)
	var rect := modules[index].rect
	var centre := Vector2(rect.position) + Vector2(rect.size) / 2.0
	_blast_origin = Vector3(centre.x, centre.y, module_decks[index])
	_sync_component(index)
	_blast_origin = NO_POINT


## Flies a kinetic penetrator with `points` left from `entry` to `exit` (hull space), spending a point on every wall,
## floor and module cell it hits on the way.
func _trace_round(entry: Vector3, exit: Vector3, points: int) -> void:
	var steps := maxi(ceili(entry.distance_to(exit) * 4.0), 1)
	var last := Vector3i(-1, -1, -1)
	var track_deck := _deck_of(entry)
	var track_from := _deck_point(entry)
	var track_to := track_from
	var stopped := false
	for i in steps + 1:
		var point := entry.lerp(exit, float(i) / steps)
		var flat := _deck_point(point)
		var cell := Vector3i(floori(flat.x), floori(flat.y), _deck_of(point))
		if cell == last:
			track_to = flat
			continue
		if last.z >= 0 and cell.z != last.z:
			# Through the floor between two decks: the hole is in the floor of the upper deck's lower neighbour.
			_round_track(track_deck, track_from, flat)
			track_deck = cell.z
			track_from = flat
			_open_breach(Vector3i(cell.x, cell.y, maxi(cell.z, last.z)), BreachKind.FLOOR)
			points -= 1
		last = cell
		track_to = flat
		if points <= 0:
			stopped = true
			break
		match get_cell(cell):
			Cell.WALL:
				_open_breach(cell, BreachKind.WALL)
				points -= 1
			Cell.HULL:
				pass
			_:
				var module := get_module_at(cell)
				if module != NO_MODULE:
					damage_module(module)
					points -= 1
		if points <= 0:
			# The round stops here.
			stopped = true
			track_to = Vector2(cell.x, cell.y) + Vector2(0.5, 0.5)
			break
	_round_track(track_deck, track_from, track_to)
	if not stopped:
		# Out through the far side: the round digs the armor from the inside.
		var exit_column := _armor_column(exit)
		if armor.dig(exit_column.x, exit_column.y, points) > 0 or armor.is_holed(exit_column.x, exit_column.y):
			_breach_hull_at(exit)


func _round_track(deck: int, from: Vector2, to: Vector2) -> void:
	round_tracked.emit(deck, from, to)


## A blast at `origin` (x, y in cells, z the deck) that hits every wall and module cell within its radius.
func _blast(origin: Vector3, points: int) -> void:
	var deck := int(origin.z)
	var centre := Vector2(origin.x, origin.y)
	var blast_radius := minf(1.5 + points * 0.25, 4.0)
	var hits_per_cell := 1 + floori(points / 8.0)
	var area := Rect2i(Vector2i(centre - Vector2.ONE * blast_radius), Vector2i.ONE * ceili(blast_radius * 2.0 + 1.0))
	for cell in _cells_in(area, deck):
		if (Vector2(cell.x, cell.y) + Vector2(0.5, 0.5)).distance_to(centre) > blast_radius:
			continue
		if get_cell(cell) == Cell.WALL:
			_open_breach(cell, BreachKind.WALL)
		var module := get_module_at(cell)
		if module != NO_MODULE:
			damage_module(module, hits_per_cell)


## Holes the hull where a round crossed the tube's surface at `point`: through the hull wall when it crossed the side
## or an end of the tube, else through the hull above the top deck or below the bottom one.
func _breach_hull_at(point: Vector3) -> void:
	var deck := _deck_of(point)
	var flat := _deck_point(point)
	var cell := Vector3i(floori(flat.x), floori(flat.y), deck)
	if point.x <= 0.01 or point.x >= length - 0.01:
		cell.x = 0 if point.x < length / 2.0 else length - 1
		_open_breach(cell, BreachKind.HULL)
	elif (deck == 0 and point.z > radius * 0.5) or (deck == decks - 1 and point.z < -radius * 0.5):
		_open_breach(cell, BreachKind.DECK)
	else:
		cell.y = 0 if point.y < 0.0 else diameter - 1
		_open_breach(cell, BreachKind.HULL)


func _open_breach(cell: Vector3i, kind: BreachKind) -> void:
	if not _in_bounds(cell):
		return
	_damaged_frame[cell] = true
	if breaches.has(cell):
		return
	breaches[cell] = kind
	breach_opened.emit(cell, kind)


func _check_breakup() -> void:
	_update_engines()
	if hull and not hull.is_destroyed and get_frame_integrity() < breakup_integrity:
		hull.break_up()


func _leak_fuel(index: int, points: int) -> void:
	var fraction := fuel_loss_per_hit * points
	fuel_lost += fraction
	var ship := hull.host as Spaceship if hull else null
	if ship:
		ship.fuel = maxf(ship.fuel - fraction * ship.fuel_capacity, 0.0)
	fuel_leaked.emit(index, fraction)


## Scales the ship's own copies of its engines: thrusters by the frame, the main drive by its working modules.
func _update_engines() -> void:
	var thrusters := get_thruster_performance()
	var main := get_main_engine_performance()
	var ship := hull.host as Spaceship if hull else null
	if ship and ship.thrusters:
		if _base_thrusters == null:
			# Engine definitions are shared resources: scale a copy of this ship's own.
			_base_thrusters = ship.thrusters
			ship.thrusters = _base_thrusters.duplicate()
		ship.thrusters.max_thrust = _base_thrusters.max_thrust * thrusters
		ship.thrusters.turn_torque = _base_thrusters.turn_torque * thrusters
	if ship and ship.main_engine:
		if _base_main_engine == null:
			_base_main_engine = ship.main_engine
			ship.main_engine = _base_main_engine.duplicate()
		ship.main_engine.max_thrust = _base_main_engine.max_thrust * main
	if not is_equal_approx(thrusters, thruster_performance):
		thruster_performance = thrusters
		thrusters_changed.emit(thrusters)
	if not is_equal_approx(main, main_engine_performance):
		main_engine_performance = main
		main_engine_changed.emit(main)

#endregion


#region Repairs

## Crew patch a hole. Returns false when there was none. Patching seals the hole but the armor column stays holed.
func patch_breach(cell: Vector3i) -> bool:
	if not breaches.has(cell):
		return false
	breaches.erase(cell)
	breach_patched.emit(cell)
	return true


## Crew repair `points` of a module's damage. Returns false when it was undamaged.
func repair_module(index: int, points: int = 1) -> bool:
	if module_damage[index] <= 0 or points <= 0:
		return false
	var was_operational := is_module_operational(index)
	module_damage[index] = maxi(module_damage[index] - points, 0)
	if not was_operational:
		_sync_component(index)
		_update_engines()
	module_repaired.emit(index)
	return true


## A hull component stays online while any of its modules works.
func _sync_component(index: int) -> void:
	var component := _component_index[index]
	if hull == null or component < 0:
		return
	var working := get_component_effectiveness(component) > 0.0
	hull.set_component_damage(component, 0 if working else hull.components[component].hit_to_kill)

#endregion


#region Geometry

## Hull space: x along the tube from the stern (0) to the bow (length), y across the decks (-radius..radius), z up
## (-radius..radius, the top deck highest).
func _to_hull_direction(direction: Vector2) -> Vector3:
	if direction.length_squared() < 1e-12:
		var random := Vector3(rng.randfn(), rng.randfn(), rng.randfn())
		return random.normalized() if random.length_squared() > 1e-12 else Vector3.RIGHT
	var local := direction.rotated(-get_hull_facing()).normalized()
	return Vector3(local.x, local.y, rng.randfn(0.0, vertical_spread)).normalized()


## The direction the hull's bow points in world space (radians).
func get_hull_facing() -> float:
	if hull == null:
		return 0.0
	var ship := hull.host as Spaceship
	# Ships keep their facing in local space; their body does not rotate on the orbital map.
	return ship.facing if ship else hull.global_rotation


## Where a round travelling along `direction` enters and leaves the tube: [entry, exit] in hull space. The line passes
## through a random point inside the tube, so every part of the hull facing the round can be struck.
func _find_round_path(direction: Vector3) -> Array[Vector3]:
	var angle := rng.randf() * TAU
	var r := radius * sqrt(rng.randf()) * 0.95
	var through := Vector3(rng.randf() * length, r * cos(angle), r * sin(angle))
	var t_in := -INF
	var t_out := INF
	if absf(direction.x) > 1e-6:
		var t0 := -through.x / direction.x
		var t1 := (length - through.x) / direction.x
		t_in = minf(t0, t1)
		t_out = maxf(t0, t1)
	var a := direction.y * direction.y + direction.z * direction.z
	if a > 1e-9:
		var b := 2.0 * (through.y * direction.y + through.z * direction.z)
		var c := through.y * through.y + through.z * through.z - radius * radius
		var root := sqrt(maxf(b * b - 4.0 * a * c, 0.0))
		t_in = maxf(t_in, (-b - root) / (2.0 * a))
		t_out = minf(t_out, (-b + root) / (2.0 * a))
	return [through + direction * t_in, through + direction * t_out]


## Armor column over a point on the tube's surface.
func _armor_column(point: Vector3) -> Vector2i:
	var around := fposmod(atan2(point.z, point.y), TAU) / TAU
	return Vector2i(clampi(floori(point.x), 0, length - 1), wrapi(floori(around * armor.height), 0, armor.height))


## A hull-space point seen from above, in deck cells.
func _deck_point(point: Vector3) -> Vector2:
	return Vector2(clampf(point.x, 0.0, length - 0.001), clampf(point.y + radius, 0.0, diameter - 0.001))


## The deck a hull-space point is on: the tube's height is split evenly between the decks, top deck first.
func _deck_of(point: Vector3) -> int:
	return clampi(floori((radius - point.z) / (diameter / float(decks))), 0, decks - 1)


func _cells_in(rect: Rect2i, deck: int) -> Array[Vector3i]:
	var result: Array[Vector3i] = []
	var area := rect.intersection(Rect2i(0, 0, length, diameter))
	for y in range(area.position.y, area.end.y):
		for x in range(area.position.x, area.end.x):
			result.append(Vector3i(x, y, deck))
	return result


func _in_bounds(cell: Vector3i) -> bool:
	return cell.x >= 0 and cell.y >= 0 and cell.z >= 0 and cell.x < length and cell.y < diameter and cell.z < decks


func _index(cell: Vector3i) -> int:
	return (cell.z * diameter + cell.y) * length + cell.x


@warning_ignore("integer_division")
func _cell_of(index: int) -> Vector3i:
	return Vector3i(index % length, (index / length) % diameter, index / (length * diameter))

#endregion
