class_name ManeuverPlanner
extends Node
## The player's maneuver nodes for the parent Spaceship, and their automatic execution.
##
## A node is {time, prograde, radial, drive}: delta-v in px/s along the ship's velocity and away from the body it is
## orbiting, measured when the burn starts, and the engines that fly it (Spaceship.Drive). A thrusters-only node
## with no prograde component is a translation: the thrusters push sideways and the ship does not turn. That is the same frame the C# predictor uses for node burns, so the
## previewed path is the path that will be flown. Each burn is centred on its node time and executed by the
## ship's engine; a node is removed once its burn completes.

signal nodes_changed
signal maneuver_started(node: Dictionary)
signal maneuver_completed(node: Dictionary)

## Time warp eases down ahead of a burn, one level at a time, spending this many real seconds at each level.
@export var warp_ramp_step: float = 1.0
## Real seconds at 1x before the ship starts turning for a burn. Warp stays at 1x until the burn completes.
@export var warp_stop_lead: float = 3.0
## Start turning toward the burn direction this many simulation seconds before the turn is strictly needed.
@export var align_margin: float = 2.0
## Nodes whose burn start is further in the past than this are discarded instead of executed.
@export var stale_after: float = 5.0

var ship: Spaceship
var orbital_system: Node
## Sorted by time.
var nodes: Array[Dictionary] = []

## Nodes below this delta-v (px/s) count as empty.
const EMPTY_DELTA_V := 1e-3

var _executing: Dictionary = {}


func _ready() -> void:
	# After the OrbitalSystem (time) but before the ship, so a burn started this tick thrusts this tick.
	process_physics_priority = -1
	ship = get_parent() as Spaceship
	assert(ship != null, "ManeuverPlanner must be a child of a Spaceship")
	orbital_system = get_tree().get_first_node_in_group(Constants.ORBITAL_SYSTEM_GROUP)
	ship.burn_completed.connect(_on_burn_completed)


#region Editing

func add_node(time: float, prograde: float = 0.0, radial: float = 0.0,
		drive: Spaceship.Drive = Spaceship.Drive.MAIN) -> Dictionary:
	var node := {"time": time, "prograde": prograde, "radial": radial, "drive": drive}
	nodes.append(node)
	_sort()
	nodes_changed.emit()
	return node


func remove_node(node: Dictionary) -> void:
	if is_same(node, _executing):
		ship.cancel_burn()
		_executing = {}
	nodes.erase(node)
	ship.release_heading()
	nodes_changed.emit()


func clear() -> void:
	if not _executing.is_empty():
		ship.cancel_burn()
		_executing = {}
	nodes.clear()
	ship.release_heading()
	nodes_changed.emit()


## Call after changing a node's time or delta-v.
func node_edited(_node: Dictionary) -> void:
	_sort()
	nodes_changed.emit()


## True when a node has no delta-v, i.e. it would not change the trajectory.
func is_empty_node(node: Dictionary) -> bool:
	return get_delta_v(node) < EMPTY_DELTA_V


## Removes every node that would not change the trajectory. Returns how many were removed.
func remove_empty_nodes() -> int:
	var empty := nodes.filter(func(n: Dictionary) -> bool: return is_empty_node(n) and not is_same(n, _executing))
	if empty.is_empty():
		return 0
	for node in empty:
		nodes.erase(node)
	nodes_changed.emit()
	return empty.size()


## Pending maneuvers keep the ship out of its parking orbit (see Spaceship.park).
func blocks_parking() -> bool:
	return not nodes.is_empty()


func is_executing(node: Dictionary) -> bool:
	return is_same(node, _executing)


func get_drive(node: Dictionary) -> Spaceship.Drive:
	return node.get("drive", Spaceship.Drive.MAIN)


## Thrusters-only, purely radial/anti-radial nodes are flown as translations, without turning the ship.
func is_translation(node: Dictionary) -> bool:
	return get_drive(node) == Spaceship.Drive.THRUSTERS and absf(node.prograde) < EMPTY_DELTA_V


func get_delta_v(node: Dictionary) -> float:
	return Vector2(node.prograde, node.radial).length()


func get_total_delta_v() -> float:
	var total := 0.0
	for node in nodes:
		total += get_delta_v(node)
	return total


## Burn duration of a node, accounting for the fuel used by the nodes before it.
func get_burn_duration(node: Dictionary) -> float:
	return ship.burn_duration_for(_mass_before(node), get_delta_v(node), get_drive(node))


func get_burn_start(node: Dictionary) -> float:
	return node.time - 0.5 * get_burn_duration(node)


## Nodes as burns for OrbitalSystem.PredictAsync, so the preview includes them as finite burns.
func get_prediction_burns() -> Array:
	var burns := []
	for node in nodes:
		if is_same(node, _executing) or is_empty_node(node):
			continue # Being flown (already in the ship's real state), or changes nothing.
		var drive := get_drive(node)
		burns.append({
			"time": node.time,
			"prograde": node.prograde,
			"radial": node.radial,
			"thrust": ship.get_drive_thrust(drive),
			"mass": _mass_before(node),
			"exhaust_velocity": ship.get_drive_exhaust_velocity(drive),
		})
	return burns


func _mass_before(node: Dictionary) -> float:
	var mass := ship.get_dry_mass() + ship.fuel
	for other in nodes:
		if is_same(other, node):
			break
		if is_same(other, _executing):
			continue
		mass /= exp(get_delta_v(other) / ship.get_drive_exhaust_velocity(get_drive(other)))
	return maxf(mass, ship.get_dry_mass())


func _sort() -> void:
	nodes.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.time < b.time)

#endregion


#region Execution

func _physics_process(_delta: float) -> void:
	if not orbital_system.IsReady:
		return
	_update_warp_cap()
	if nodes.is_empty() or not _executing.is_empty():
		return
	var now: float = orbital_system.SimTime
	var node: Dictionary = nodes[0]
	if is_empty_node(node):
		# An empty node changes nothing: never let it block the nodes after it.
		if now >= node.time:
			remove_node(node)
		return
	var start := get_burn_start(node)
	if now > start + stale_after:
		remove_node(node) # Missed (e.g. placed in the past); never fire a burn at the wrong point.
		return

	var delta_v := current_delta_v(node)
	var translate := is_translation(node)
	if not translate and now >= start - ship.get_turn_time(delta_v) - align_margin:
		ship.hold_heading(delta_v)
	if now >= start:
		_executing = node
		ship.release_heading()
		ship.execute_burn(delta_v, get_drive(node), translate)
		maneuver_started.emit(node)


## Caps time warp as the next burn approaches, easing it down a level at a time (see warp_ramp_step), and holds 1x
## while the burn runs.
func _update_warp_cap() -> void:
	var cap := -1
	if not _executing.is_empty() or ship.is_burning():
		cap = 0
	else:
		for node in nodes:
			if is_empty_node(node):
				continue
			var turn_start := get_burn_start(node)
			if not is_translation(node):
				turn_start -= ship.get_turn_time(current_delta_v(node)) + align_margin
			cap = orbital_system.WarpIndexForRamp(turn_start - orbital_system.SimTime, warp_ramp_step, warp_stop_lead)
			break
	if cap >= orbital_system.WarpLevels.size() - 1:
		cap = -1
	if cap != orbital_system.WarpCapIndex:
		orbital_system.WarpCapIndex = cap


func _exit_tree() -> void:
	if orbital_system != null and is_instance_valid(orbital_system):
		orbital_system.WarpCapIndex = -1


## Inertial delta-v of a node from the ship's current state (prograde/radial relative to the dominant body).
func current_delta_v(node: Dictionary) -> Vector2:
	var now: float = orbital_system.SimTime
	var body: int = orbital_system.FindDominantBody(ship.get_state_position())
	var rel_pos := ship.get_state_position()
	var rel_vel := ship.get_state_velocity()
	if body >= 0:
		rel_pos -= orbital_system.GetBodyPosition(body, now)
		rel_vel -= orbital_system.GetBodyVelocity(body, now)
	var axes := orbital_axes(rel_pos, rel_vel)
	return axes[0] * float(node.prograde) + axes[1] * float(node.radial)


## [prograde, radial-out] unit vectors; mirrors ImpulseBurn.OrbitalAxes in C#.
static func orbital_axes(rel_pos: Vector2, rel_vel: Vector2) -> Array[Vector2]:
	var prograde := rel_vel.normalized()
	if prograde == Vector2.ZERO:
		prograde = rel_pos.normalized().orthogonal() * -1.0
	var radial := Vector2(-prograde.y, prograde.x)
	if radial.dot(rel_pos) < 0.0:
		radial = -radial
	return [prograde, radial]


## Manual control during a burn aborts it (emergency override). The node is discarded.
func abort_current() -> void:
	if _executing.is_empty():
		return
	var node := _executing
	_executing = {}
	ship.cancel_burn()
	nodes.erase(node)
	nodes_changed.emit()


func _on_burn_completed(_achieved: Vector2) -> void:
	if _executing.is_empty():
		return
	var node := _executing
	_executing = {}
	nodes.erase(node)
	maneuver_completed.emit(node)
	nodes_changed.emit()

#endregion
