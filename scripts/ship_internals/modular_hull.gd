class_name ModularHull
extends ShipHull
## A hull with a walkable interior: its armor surface, its decks and the modules placed on them, and the damage done to
## them.
##
## The hull is a cylindrical tube, cut into decks stacked from the top down. Its modules are the ones placed on the
## decks of its `layout` (ModulePlacement), plus the hull's `modules` array for systems that need no place (thrusters).
## A placement covers at least its module's size in cells; covering more gives the module its size bonus.
##
## Hits strike the armor surface (HullArmorSurface, the tube unrolled into armor columns) and dig a crater; points that
## get through carry on inside. A kinetic penetrator flies straight on through the tube: it spends a point on every
## wall cell and every floor between decks it crosses, and on each module it passes through it spends, all at once,
## the whole cells of its path inside the module (a round that clips a corner does nothing to it; one that bores down its
## length hits it hard). That damage knocks the module out with a chance of damage / hits to kill. It holes the hull
## where it enters, and if it still has points left at the far side it digs its way out. An explosive hit bursts just
## inside the hole it blew, holing walls around it; each module in the blast takes the blast damage summed over its
## cells, falling off with distance, at once. Fractions of a point are dropped in both cases. So rounds through cargo
## holds, crew quarters and corridors only leave holes for the crew to patch, and a ship is crippled long before it is
## destroyed: it only breaks up once nearly all of its frame is holed (never while standalone, without a host).
##
## Fuel tanks are compartmentalised and self-sealing, so hits on them only lose a little fuel; thrusters have no
## place, but weaken as the frame they are mounted on is holed (see get_thruster_performance); and a main drive built
## from several engine modules loses each engine's share of thrust as it is knocked out.
##
## On its own (no Node2D parent) it works as a standalone model (tests, demo scenes). Show it with a ShipInternalsView
## and an ArmorSurfaceRect; crew live in a ShipCrew.
##
## Cells are addressed as Vector3i(x, y, deck).

signal armor_changed
signal breach_opened(cell: Vector3i, kind: BreachKind)
signal breach_patched(cell: Vector3i)
## A round's path across one deck, in cells (where it entered the deck to where it left it or stopped).
signal round_tracked(deck: int, from: Vector2, to: Vector2)
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
## Samples per cell along a round's path.
const TRACE_SAMPLES := 4.0

@export var layout: ShipLayout
## Share of the frame (hull and wall cells) that must stay intact; when more is holed the ship breaks up.
@export_range(0.0, 1.0, 0.01) var breakup_integrity: float = 0.05
## Spread (radians, standard deviation) of the height rounds hit at: the space view is flat, so it is random.
@export var vertical_spread: float = 0.35

@export_group("Thrusters")
## Thrusters keep full performance while the frame integrity is at least this.
@export_range(0.0, 1.0, 0.01) var thruster_full_integrity: float = 0.5
## Thrusters are dead once the frame integrity falls to this.
@export_range(0.0, 1.0, 0.01) var thruster_dead_integrity: float = 0.1
## Shape of the fall-off between the two, as Godot's ease() curve: below 1 the thrust fades slowly at first and drops
## off faster and faster as the frame nears the dead level (0.5 = 1 - (1 - t)^2).
@export_exp_easing var thruster_ease: float = 0.5

var surface: HullArmorSurface
var length: int
var diameter: int
var radius: float
var decks: int
## Deck of each module (-1 for the unplaced ones).
var module_decks: PackedInt32Array
## Open holes: Vector3i cell -> BreachKind.
var breaches: Dictionary = {}
## Paths over open deck and between decks by elevator: hull, walls and modules are solid, doors are open.
var nav: AStar3D
var thruster_performance := 1.0
var main_engine_performance := 1.0

## Placement of each module (null for the unplaced ones).
var _placements: Array[ModulePlacement] = []
## Cell type of each cell, deck by deck, row-major.
var _cells: PackedByteArray
## Module covering each cell (NO_MODULE for none).
var _module_at: PackedInt32Array
var _frame_cells := 0
## Frame cells ever holed: patching seals a hole but does not restore the frame's strength.
var _damaged_frame: Dictionary = {}
## Thruster performance last reported by thrusters_changed.
var _last_thrusters := 1.0


func _ready() -> void:
	if layout == null:
		layout = ShipLayout.create_default()
	super._ready()


#region Setup

## Replaces the layout (the layout editor's live preview): rebuilds the decks and armor and clears all damage.
func set_layout(new_layout: ShipLayout) -> void:
	layout = new_layout if new_layout else ShipLayout.create_default()
	_rebuild()
	layout_changed.emit()


func _collect_modules() -> Array[ShipModule]:
	var result: Array[ShipModule] = []
	_placements.clear()
	module_decks = PackedInt32Array()
	for deck in layout.get_deck_count():
		for placement in layout.get_deck(deck).modules:
			if placement == null or placement.module == null:
				continue
			result.append(placement.module)
			_placements.append(placement)
			module_decks.append(deck)
	for module in modules:
		if module == null:
			continue
		result.append(module)
		_placements.append(null)
		module_decks.append(-1)
	return result


## Placed modules are knocked out by hits; the unplaced ones (thrusters) wear down with the frame instead.
func _is_knockout_tracked(index: int) -> bool:
	return _placements[index] != null


func _setup_damage_model() -> void:
	breaches.clear()
	_damaged_frame.clear()
	length = maxi(layout.length, 3)
	diameter = maxi(layout.diameter, 3)
	radius = diameter / 2.0
	decks = layout.get_deck_count()
	# The same depth as an armor grid of this hull: armor mass spread over its columns.
	var thickness := armor.layers_for(armor_mass, maxi(armor_columns, 1)) if armor else layout.armor_thickness
	surface = HullArmorSurface.new(length, layout.get_circumference(), thickness)
	var count := length * diameter * decks
	_cells = PackedByteArray()
	_cells.resize(count)
	_cells.fill(Cell.DECK)
	_module_at = PackedInt32Array()
	_module_at.resize(count)
	_module_at.fill(NO_MODULE)
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
	for index in _placements.size():
		if _placements[index] == null:
			continue
		var placement := _placements[index]
		if placement.get_cell_count() < ceili(placement.module.size):
			push_warning("%s: %s is placed on %d cells, less than its size %.1f"
				% [name, placement.module.name, placement.get_cell_count(), placement.module.size])
		for cell in _cells_in(placement.rect, module_decks[index]):
			if get_cell(cell) == Cell.DECK:
				_module_at[_index(cell)] = index
	_frame_cells = 0
	for value in _cells:
		if value == Cell.HULL or value == Cell.WALL:
			_frame_cells += 1
	thruster_performance = get_thruster_performance()
	_build_nav()


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


## Placement of module `index` (null for the unplaced ones).
func get_placement(index: int) -> ModulePlacement:
	return _placements[index] if index >= 0 and index < _placements.size() else null


func is_module_placed(index: int) -> bool:
	return get_placement(index) != null


## Cells module `index` covers (an empty rectangle for the unplaced ones).
func get_module_rect(index: int) -> Rect2i:
	var placement := get_placement(index)
	return placement.rect if placement else Rect2i()


func get_module_deck(index: int) -> int:
	return module_decks[index]


## The cells of its placement; unplaced modules count at their base size.
func get_module_installed_size(index: int) -> float:
	var placement := get_placement(index)
	return float(placement.get_cell_count()) if placement else super.get_module_installed_size(index)


## Unplaced thrusters give the frame's thruster performance.
func get_module_performance(index: int) -> float:
	var engine := get_module(index) as EngineModule
	if engine and engine.is_thrusters() and not is_module_placed(index):
		return thruster_performance
	return super.get_module_performance(index)


## 0 (offline, repair not started) .. 1 (working); an offline module shows how far its repair has come.
func get_module_condition(index: int) -> float:
	return 1.0 if is_module_operational(index) else get_repair_progress(index) * 0.99


## Walkable cells next to a module, where crew stand to touch it.
func get_access_cells(index: int) -> Array[Vector3i]:
	var access: Array[Vector3i] = []
	if not is_module_placed(index):
		return access
	var rect := get_module_rect(index)
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


## Thrust of the main drive, 0..1: the share of its engines' thrust still working (1 with no main engines).
func get_main_engine_performance() -> float:
	var total := 0.0
	var working := 0.0
	for i in get_module_count():
		var engine := get_module(i) as EngineModule
		if engine and not engine.is_thrusters():
			total += engine.max_thrust
			working += engine.max_thrust * get_module_performance(i)
	return working / total if total > 0.0 else 1.0


func get_armor_integrity() -> float:
	return surface.get_integrity()

#endregion


#region Damage

## A hit of `damage` points with `profile`, its round travelling along `direction` (world space; standalone, the deck's:
## +x towards the bow). A zero direction comes from anywhere.
func _resolve_hit(damage: int, profile: ArmorGrid.DamageProfile, direction: Vector2) -> int:
	var path := _find_round_path(_to_hull_direction(direction))
	var entry: Vector3 = path[0]
	var exit: Vector3 = path[1]
	var entry_column := _armor_column(entry)
	var points := surface.apply_crater(entry_column.x, entry_column.y, damage, profile)
	if points > 0:
		_breach_hull_at(entry)
		if profile == ArmorGrid.DamageProfile.KINETIC:
			_trace_round(entry, exit, points)
		else:
			var point := _deck_point(entry)
			_blast(Vector3(point.x, point.y, _deck_of(entry)), points)
	surface.update_texture()
	armor_changed.emit()
	_check_breakup()
	return points


## Damage from inside the ship (a magazine cooking off): a blast centred on module `origin`, or on a random spot of
## open deck.
func apply_internal_damage(points: int, origin: int = -1) -> void:
	if is_destroyed or points <= 0:
		return
	var at := Vector3(rng.randi_range(1, length - 2) + 0.5, rng.randi_range(1, diameter - 2) + 0.5,
		rng.randi_range(0, decks - 1))
	if is_module_placed(origin):
		var rect := get_module_rect(origin)
		var centre := Vector2(rect.position) + Vector2(rect.size) / 2.0
		at = Vector3(centre.x, centre.y, module_decks[origin])
	_blast(at, points)
	_check_breakup()


## Flies a kinetic penetrator with `points` left from `entry` to `exit` (hull space). It spends a point on every wall
## and floor it holes; each module it passes through takes the whole cells of the path inside it at once, and the round
## spends that much.
func _trace_round(entry: Vector3, exit: Vector3, points: int) -> void:
	var steps := maxi(ceili(entry.distance_to(exit) * TRACE_SAMPLES), 1)
	var step_length := entry.distance_to(exit) / steps
	var last := Vector3i(-1, -1, -1)
	var track_deck := _deck_of(entry)
	var track_from := _deck_point(entry)
	var track_to := track_from
	var stopped := false
	# The module the round is inside, the path it has run in it and the points it had going in.
	var inside := NO_MODULE
	var inside_length := 0.0
	var inside_budget := 0
	for i in steps + 1:
		var point := entry.lerp(exit, float(i) / steps)
		var flat := _deck_point(point)
		var cell := Vector3i(floori(flat.x), floori(flat.y), _deck_of(point))
		var module := get_module_at(cell)
		if module != inside:
			points -= _strike_module(inside, inside_length, inside_budget)
			inside = module
			inside_length = 0.0
			inside_budget = points
		if inside != NO_MODULE:
			inside_length += step_length
			if floori(inside_length) >= inside_budget:
				# Spent inside the module.
				points -= _strike_module(inside, inside_length, inside_budget)
				inside = NO_MODULE
				stopped = true
				track_to = flat
				break
		if points <= 0:
			stopped = true
			break
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
		if points > 0 and get_cell(cell) == Cell.WALL:
			_open_breach(cell, BreachKind.WALL)
			points -= 1
		if points <= 0:
			# The round stops here.
			stopped = true
			track_to = Vector2(cell.x, cell.y) + Vector2(0.5, 0.5)
			break
	if not stopped:
		points -= _strike_module(inside, inside_length, inside_budget)
	_round_track(track_deck, track_from, track_to)
	if not stopped and points > 0:
		# Out through the far side: the round digs the armor from the inside.
		var exit_column := _armor_column(exit)
		if surface.dig(exit_column.x, exit_column.y, points) > 0 or surface.is_holed(exit_column.x, exit_column.y):
			_breach_hull_at(exit)


## A round ran `path_length` cells through module `index` with `budget` points: the module takes the whole cells, up
## to the budget, at once. Returns the points spent.
func _strike_module(index: int, path_length: float, budget: int) -> int:
	if index == NO_MODULE or budget <= 0:
		return 0
	var damage := mini(floori(path_length + 1e-6), budget)
	if damage > 0:
		damage_module(index, damage)
	return damage


func _round_track(deck: int, from: Vector2, to: Vector2) -> void:
	round_tracked.emit(deck, from, to)


## A blast of `points` at `origin` (x, y in cells, z the deck). It holes every wall within its radius; each module in
## it takes the blast summed over its cells (strongest at the centre, nothing at the edge), whole points only, at once.
func _blast(origin: Vector3, points: int) -> void:
	var deck := int(origin.z)
	var centre := Vector2(origin.x, origin.y)
	var blast_radius := minf(1.5 + points * 0.25, 4.0)
	var peak := 1.0 + points / 8.0
	var area := Rect2i(Vector2i(centre - Vector2.ONE * blast_radius), Vector2i.ONE * ceili(blast_radius * 2.0 + 1.0))
	var damage := {}
	for cell in _cells_in(area, deck):
		var distance := (Vector2(cell.x, cell.y) + Vector2(0.5, 0.5)).distance_to(centre)
		if distance > blast_radius:
			continue
		if get_cell(cell) == Cell.WALL:
			_open_breach(cell, BreachKind.WALL)
		var module := get_module_at(cell)
		if module != NO_MODULE:
			damage[module] = damage.get(module, 0.0) + peak * (1.0 - distance / blast_radius)
	for module: int in damage:
		var whole := floori(damage[module] + 1e-6)
		if whole > 0:
			damage_module(module, whole)


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


## The frame changed: rescale the thrusters, and break up once too little of it is left (not standalone).
func _check_breakup() -> void:
	_update_engines()
	if host and not is_destroyed and get_frame_integrity() < breakup_integrity:
		break_up()


func _update_engines() -> void:
	thruster_performance = get_thruster_performance() if _frame_cells > 0 else 1.0
	super._update_engines()
	var thrusters := thruster_performance
	var main := get_main_engine_performance()
	if not is_equal_approx(thrusters, _last_thrusters):
		_last_thrusters = thrusters
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


## The direction the hull's bow points in world space (radians); 0 standalone.
func get_hull_facing() -> float:
	if host == null:
		return 0.0
	var ship := host as Spaceship
	# Ships keep their facing in local space; their body does not rotate on the orbital map.
	return ship.facing if ship else global_rotation


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
	return Vector2i(clampi(floori(point.x), 0, length - 1), wrapi(floori(around * surface.height), 0, surface.height))


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


func _draw() -> void:
	# Standalone (the demo, the layout editor) there is no contact to mark.
	if host:
		super._draw()
