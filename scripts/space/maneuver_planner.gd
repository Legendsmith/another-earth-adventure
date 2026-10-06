class_name ManeuverPlanner
extends Node
## The player's maneuver nodes for the parent Spaceship, and their automatic execution.
##
## A node is {time, prograde, radial}: delta-v in px/s along the ship's velocity and away from the body it is
## orbiting, measured when the burn starts. That is the same frame the C# predictor uses for node burns, so the
## previewed path is the path that will be flown. Each burn is centred on its node time and executed by the
## ship's engine; a node is removed once its burn completes.

signal nodes_changed
signal maneuver_started(node: Dictionary)
signal maneuver_completed(node: Dictionary)

## Drop out of time warp this many real seconds before a burn starts.
@export var warp_stop_lead: float = 4.0
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

func add_node(time: float, prograde: float = 0.0, radial: float = 0.0) -> Dictionary:
	var node := {"time": time, "prograde": prograde, "radial": radial}
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


func is_executing(node: Dictionary) -> bool:
	return is_same(node, _executing)


func get_delta_v(node: Dictionary) -> float:
	return Vector2(node.prograde, node.radial).length()


func get_total_delta_v() -> float:
	var total := 0.0
	for node in nodes:
		total += get_delta_v(node)
	return total


## Burn duration of a node, accounting for the fuel used by the nodes before it.
func get_burn_duration(node: Dictionary) -> float:
	var mass := _mass_before(node)
	var dv := get_delta_v(node)
	return mass * (1.0 - exp(-dv / ship.exhaust_velocity)) / (ship.max_thrust / ship.exhaust_velocity)


func get_burn_start(node: Dictionary) -> float:
	return node.time - 0.5 * get_burn_duration(node)


## Nodes as burns for OrbitalSystem.PredictAsync, so the preview includes them as finite burns.
func get_prediction_burns() -> Array:
	var burns := []
	for node in nodes:
		if is_same(node, _executing) or is_empty_node(node):
			continue # Being flown (already in the ship's real state), or changes nothing.
		burns.append({
			"time": node.time,
			"prograde": node.prograde,
			"radial": node.radial,
			"thrust": ship.max_thrust,
			"mass": _mass_before(node),
			"exhaust_velocity": ship.exhaust_velocity,
		})
	return burns


func _mass_before(node: Dictionary) -> float:
	var mass := ship.dry_mass + ship.fuel
	for other in nodes:
		if is_same(other, node):
			break
		if is_same(other, _executing):
			continue
		mass /= exp(get_delta_v(other) / ship.exhaust_velocity)
	return maxf(mass, ship.dry_mass)


func _sort() -> void:
	nodes.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.time < b.time)

#endregion


#region Execution

func _physics_process(_delta: float) -> void:
	if nodes.is_empty() or not _executing.is_empty() or not orbital_system.IsReady:
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
	var warp: int = orbital_system.TimeWarp
	if warp > 1 and start - now < (warp_stop_lead + align_margin) * warp:
		orbital_system.SetTimeWarpIndex(0)
	if now >= start - ship.get_turn_time(delta_v) - align_margin:
		ship.hold_heading(delta_v)
	if now >= start:
		_executing = node
		ship.release_heading()
		ship.execute_burn(delta_v)
		maneuver_started.emit(node)


## Inertial delta-v of a node from the ship's current state (prograde/radial relative to the dominant body).
func current_delta_v(node: Dictionary) -> Vector2:
	var now: float = orbital_system.SimTime
	var body: int = orbital_system.FindDominantBody(ship.global_position)
	var rel_pos := ship.global_position
	var rel_vel := ship.linear_velocity
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
