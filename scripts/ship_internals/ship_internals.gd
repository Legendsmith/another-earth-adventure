class_name ShipInternals
extends Node
## The inside of a ship: its armor surface, its deck plan and the modules on it, and the damage done to them.
##
## The hull is a cylindrical tube. Hits strike the armor surface (HullArmorSurface, the tube unrolled into armor
## columns) and dig a crater; points that get through carry on inside. A kinetic round flies straight on through the
## tube: it holes the hull where it enters, every wall it crosses, damages each module in its path (one point each, which
## it spends) and, if it still has points left, digs its way out the far side. An explosive hit bursts just inside the
## hole it blew. So rounds through the crew quarters and corridors only leave holes for the crew to patch, and a ship
## is crippled long before it is destroyed: it only breaks up once nearly all of its frame is holed.
##
## Two systems are spread through the ship rather than knocked out: fuel tanks are compartmentalised and self-sealing,
## so hits on them only lose a little fuel; and thrusters have no module at all, but weaken as the frame they are
## mounted on is holed (see get_thruster_performance).
##
## Add it as a child of a CombatHull to take over the hull's armor and internal damage (see CombatHull.internals):
## modules then stand for the hull's components of the same name. On its own it works as a standalone model (tests,
## demo scenes). Show it with a ShipInternalsView and an ArmorSurfaceRect.

signal armor_changed
signal breach_opened(cell: Vector2i, kind: BreachKind)
signal breach_patched(cell: Vector2i)
signal module_damaged(index: int)
signal module_destroyed(index: int)
signal module_repaired(index: int)
## A round's path across the deck, in cells (from where it entered to where it exited or stopped).
signal round_tracked(from: Vector2, to: Vector2)
## A hit on a fuel tank module lost `fraction` of the ship's fuel capacity before the tank sealed.
signal fuel_leaked(index: int, fraction: float)
signal thrusters_changed(performance: float)
## A new layout was set (set_layout): everything was rebuilt and all damage cleared.
signal layout_changed

enum Cell { DECK, HULL, WALL, DOOR }
## Where a hole is. HULL and DECK breaches are open to space: through the hull wall at the side of the deck, or through
## the hull above or below the deck. WALL breaches are in internal walls.
enum BreachKind { HULL, WALL, DECK }

const NO_MODULE := -1

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
## Cell type of each deck cell, row-major (y * length + x).
var cells: PackedByteArray
## Module covering each deck cell (NO_MODULE for none).
var module_at: PackedInt32Array
## Damage taken by each module (same order as layout.modules).
var module_damage: PackedInt32Array
## Open holes: cell -> BreachKind.
var breaches: Dictionary = {}
## Paths over open deck (cell units): hull, walls and modules are solid, doors are open.
var astar: AStarGrid2D
var rng := RandomNumberGenerator.new()
## Fuel lost to hits on fuel tanks, as a share of the fuel capacity.
var fuel_lost := 0.0
var thruster_performance := 1.0

var _frame_cells := 0
## Frame cells ever holed: patching seals a hole but does not restore the frame's strength.
var _damaged_frame: Dictionary = {}
## CombatHull component index of each module (-1 for none).
var _component_index: PackedInt32Array
## Deck point that internal blasts start from (the module that just blew up), or x < 0 for a random point.
var _blast_origin := Vector2(-1.0, -1.0)
## The ship's undamaged thrusters: the ship gets its own copy, scaled by thruster_performance.
var _base_thrusters: EngineDefinition


func _ready() -> void:
	rng.randomize()
	if layout == null:
		layout = ShipLayout.create_default()
	hull = get_parent() as CombatHull
	if hull:
		hull.internals = self
	_build()


#region Setup

## Replaces the layout (the layout editor's live preview): rebuilds the deck and armor and clears all damage.
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
	var thickness := layout.armor_thickness
	if hull:
		# The same depth as the hull's armor grid: armor mass spread over its columns.
		thickness = hull.armor.layers_for(hull.armor_mass, maxi(hull.armor_columns, 1)) if hull.armor else 0
	armor = HullArmorSurface.new(length, layout.get_circumference(), thickness)
	cells = PackedByteArray()
	cells.resize(length * diameter)
	cells.fill(Cell.DECK)
	module_at = PackedInt32Array()
	module_at.resize(length * diameter)
	module_at.fill(NO_MODULE)
	for y in diameter:
		for x in length:
			if x == 0 or y == 0 or x == length - 1 or y == diameter - 1:
				cells[_index(Vector2i(x, y))] = Cell.HULL
	for rect in layout.walls:
		_fill(rect, Cell.WALL)
	for door in layout.doors:
		if _in_bounds(door) and get_cell(door) == Cell.WALL:
			cells[_index(door)] = Cell.DOOR
	module_damage = PackedInt32Array()
	module_damage.resize(layout.modules.size())
	_component_index = PackedInt32Array()
	_component_index.resize(layout.modules.size())
	for i in layout.modules.size():
		var module := layout.modules[i]
		_component_index[i] = hull.find_component(module.component_name) if hull and module.component_name else -1
		for cell in _cells_in(module.rect):
			if get_cell(cell) == Cell.DECK:
				module_at[_index(cell)] = i
	_frame_cells = 0
	for value in cells:
		if value == Cell.HULL or value == Cell.WALL:
			_frame_cells += 1
	_build_astar()
	_update_thrusters()


func _build_astar() -> void:
	astar = AStarGrid2D.new()
	astar.region = Rect2i(0, 0, length, diameter)
	astar.cell_size = Vector2.ONE
	astar.offset = Vector2(0.5, 0.5)
	astar.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	astar.update()
	for y in diameter:
		for x in length:
			var cell := Vector2i(x, y)
			astar.set_point_solid(cell, not is_walkable(cell))


func _fill(rect: Rect2i, value: Cell) -> void:
	for cell in _cells_in(rect):
		if get_cell(cell) == Cell.DECK:
			cells[_index(cell)] = value

#endregion


#region Queries

func get_cell(cell: Vector2i) -> Cell:
	return cells[_index(cell)] as Cell if _in_bounds(cell) else Cell.HULL


func get_module_at(cell: Vector2i) -> int:
	return module_at[_index(cell)] if _in_bounds(cell) else NO_MODULE


## Open deck or a door, with no module on it.
func is_walkable(cell: Vector2i) -> bool:
	var value := get_cell(cell)
	return (value == Cell.DECK or value == Cell.DOOR) and get_module_at(cell) == NO_MODULE


func get_module(index: int) -> ShipModule:
	return layout.modules[index]


func get_module_hit_points(index: int) -> int:
	var component := _component_index[index]
	return hull.components[component].hit_to_kill if component >= 0 else maxi(layout.modules[index].hit_points, 1)


## Fuel tanks are never knocked out.
func is_module_operational(index: int) -> bool:
	return is_fuel_tank(index) or module_damage[index] < get_module_hit_points(index)


func is_fuel_tank(index: int) -> bool:
	return layout.modules[index].type == ShipModule.Type.FUEL_TANK


## 0 (wrecked) .. 1 (undamaged).
func get_module_condition(index: int) -> float:
	if is_fuel_tank(index):
		return 1.0
	return 1.0 - float(module_damage[index]) / get_module_hit_points(index)


## Walkable cells next to a module, where crew stand to touch it.
func get_access_cells(index: int) -> Array[Vector2i]:
	var access: Array[Vector2i] = []
	var rect := layout.modules[index].rect.grow(1)
	for cell in _cells_in(rect):
		if is_walkable(cell) and not layout.modules[index].rect.has_point(cell):
			access.append(cell)
	return access


## Path over open deck between two cells (empty when there is none).
func find_path(from: Vector2i, to: Vector2i) -> Array[Vector2i]:
	if not _in_bounds(from) or not _in_bounds(to):
		return []
	return astar.get_id_path(from, to, true)


func is_breached(cell: Vector2i) -> bool:
	return breaches.has(cell)


## Holes open to space (hull and deck breaches).
func get_hull_breach_count() -> int:
	var count := 0
	for kind in breaches.values():
		if kind != BreachKind.WALL:
			count += 1
	return count


## Share of the frame never holed: hull and wall cells, counting holes through the hull above and below the deck as
## frame too. The ship breaks up below breakup_integrity.
func get_frame_integrity() -> float:
	return 1.0 - minf(float(_damaged_frame.size()) / maxi(_frame_cells, 1), 1.0)


## Thrust of the ship's thrusters, 0..1. They are mounted all over the hull, so no single hit knocks them out: they
## keep full thrust while the frame is at least thruster_full_integrity, then fade along the thruster_ease curve, more
## and more steeply, to nothing at thruster_dead_integrity.
func get_thruster_performance() -> float:
	var t := inverse_lerp(thruster_dead_integrity, thruster_full_integrity, get_frame_integrity())
	return ease(clampf(t, 0.0, 1.0), thruster_ease)

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
			_blast(_deck_point(entry), points)
	armor.update_texture()
	armor_changed.emit()
	_check_breakup()
	return points


## Damage from inside the ship (a magazine cooking off): a blast centred on the module that just blew up, or on a random
## spot of open deck.
func apply_internal_damage(points: int) -> void:
	var origin := _blast_origin
	if origin.x < 0.0:
		var cell := Vector2i(rng.randi_range(1, length - 2), rng.randi_range(1, diameter - 2))
		origin = Vector2(cell) + Vector2(0.5, 0.5)
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
		_sync_component(index)
		return
	module_destroyed.emit(index)
	var rect := layout.modules[index].rect
	_blast_origin = Vector2(rect.position) + Vector2(rect.size) / 2.0
	_sync_component(index)
	_blast_origin = Vector2(-1.0, -1.0)


func _trace_round(entry: Vector3, exit: Vector3, points: int) -> void:
	var from := _deck_point(entry)
	var to := _deck_point(exit)
	var hit_modules := {}
	var end := to
	for cell in _cells_on_segment(from, to):
		if get_cell(cell) == Cell.WALL:
			_open_breach(cell, BreachKind.WALL)
		var module := get_module_at(cell)
		if module != NO_MODULE and not hit_modules.has(module):
			hit_modules[module] = true
			damage_module(module)
			points -= 1
			if points <= 0:
				# The round stops in the module.
				end = Vector2(cell) + Vector2(0.5, 0.5)
				break
	if points > 0:
		# Out through the far side: the round digs the armor from the inside.
		var exit_column := _armor_column(exit)
		if armor.dig(exit_column.x, exit_column.y, points) > 0 or armor.is_holed(exit_column.x, exit_column.y):
			_breach_hull_at(exit)
	round_tracked.emit(from, end)


func _blast(origin: Vector2, points: int) -> void:
	var blast_radius := minf(1.5 + points * 0.25, 4.0)
	var module_hits := 1 + floori(points / 4.0)
	var hit_modules := {}
	var area := Rect2i(Vector2i(origin - Vector2.ONE * blast_radius), Vector2i.ONE * ceili(blast_radius * 2.0 + 1.0))
	for cell in _cells_in(area):
		if (Vector2(cell) + Vector2(0.5, 0.5)).distance_to(origin) > blast_radius:
			continue
		if get_cell(cell) == Cell.WALL:
			_open_breach(cell, BreachKind.WALL)
		var module := get_module_at(cell)
		if module != NO_MODULE and not hit_modules.has(module):
			hit_modules[module] = true
	for module in hit_modules:
		damage_module(module, module_hits)


## Holes the hull where a round crossed the tube's surface at `point`: through the hull wall when it crossed the side
## or an end of the tube, else through the hull above or below the deck.
func _breach_hull_at(point: Vector3) -> void:
	var cell := _deck_cell(point)
	if point.x <= 0.01 or point.x >= length - 0.01:
		cell.x = 0 if point.x < length / 2.0 else length - 1
		_open_breach(cell, BreachKind.HULL)
	elif absf(point.z) < radius * 0.5:
		cell.y = 0 if point.y < 0.0 else diameter - 1
		_open_breach(cell, BreachKind.HULL)
	else:
		_open_breach(cell, BreachKind.DECK)


func _open_breach(cell: Vector2i, kind: BreachKind) -> void:
	if not _in_bounds(cell):
		return
	_damaged_frame[cell] = true
	if breaches.has(cell):
		return
	breaches[cell] = kind
	breach_opened.emit(cell, kind)


func _check_breakup() -> void:
	_update_thrusters()
	if hull and not hull.is_destroyed and get_frame_integrity() < breakup_integrity:
		hull.break_up()


func _leak_fuel(index: int, points: int) -> void:
	var fraction := fuel_loss_per_hit * points
	fuel_lost += fraction
	var ship := hull.host as Spaceship if hull else null
	if ship:
		ship.fuel = maxf(ship.fuel - fraction * ship.fuel_capacity, 0.0)
	fuel_leaked.emit(index, fraction)


func _update_thrusters() -> void:
	var performance := get_thruster_performance()
	var ship := hull.host as Spaceship if hull else null
	if ship and ship.thrusters:
		if _base_thrusters == null:
			# Engine definitions are shared resources: scale a copy of this ship's own.
			_base_thrusters = ship.thrusters
			ship.thrusters = _base_thrusters.duplicate()
		ship.thrusters.max_thrust = _base_thrusters.max_thrust * performance
		ship.thrusters.turn_torque = _base_thrusters.turn_torque * performance
	if not is_equal_approx(performance, thruster_performance):
		thruster_performance = performance
		thrusters_changed.emit(performance)

#endregion


#region Repairs

## Crew patch a hole. Returns false when there was none. Patching seals the hole but the armor column stays holed.
func patch_breach(cell: Vector2i) -> bool:
	if not breaches.has(cell):
		return false
	breaches.erase(cell)
	breach_patched.emit(cell)
	return true


## Crew repair `points` of a module's damage. Returns false when it was undamaged.
func repair_module(index: int, points: int = 1) -> bool:
	if module_damage[index] <= 0 or points <= 0:
		return false
	module_damage[index] = maxi(module_damage[index] - points, 0)
	_sync_component(index)
	module_repaired.emit(index)
	return true


func _sync_component(index: int) -> void:
	var component := _component_index[index]
	if hull and component >= 0:
		hull.set_component_damage(component, module_damage[index])

#endregion


#region Geometry

## Hull space: x along the tube from the stern (0) to the bow (length), y across the deck (-radius..radius), z up from
## the deck plane.
func _to_hull_direction(direction: Vector2) -> Vector3:
	if direction.length_squared() < 1e-12:
		var random := Vector3(rng.randfn(), rng.randfn(), rng.randfn())
		return random.normalized() if random.length_squared() > 1e-12 else Vector3.RIGHT
	var local := direction.rotated(-hull.global_rotation) if hull else direction
	local = local.normalized()
	return Vector3(local.x, local.y, rng.randfn(0.0, vertical_spread)).normalized()


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


func _deck_cell(point: Vector3) -> Vector2i:
	return Vector2i(_deck_point(point).floor())


## Every cell the segment passes through, in order.
func _cells_on_segment(from: Vector2, to: Vector2) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	var steps := maxi(ceili(from.distance_to(to) * 4.0), 1)
	for i in steps + 1:
		var cell := Vector2i(from.lerp(to, float(i) / steps).floor())
		if result.is_empty() or result[-1] != cell:
			result.append(cell)
	return result


func _cells_in(rect: Rect2i) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	var area := rect.intersection(Rect2i(0, 0, length, diameter))
	for y in range(area.position.y, area.end.y):
		for x in range(area.position.x, area.end.x):
			result.append(Vector2i(x, y))
	return result


func _in_bounds(cell: Vector2i) -> bool:
	return cell.x >= 0 and cell.y >= 0 and cell.x < length and cell.y < diameter


func _index(cell: Vector2i) -> int:
	return cell.y * length + cell.x

#endregion
