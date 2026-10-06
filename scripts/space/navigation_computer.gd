class_name NavigationComputer
extends Node
## The player ship's navigation computer: plots a course to a celestial body and lays it out as maneuver nodes,
## then keeps that course on target in flight.
##
## It never flies the ship itself: its nodes are executed by the ManeuverPlanner like any the player placed, and
## can be inspected before they fire. Interplanetary courses are very sensitive to how precisely the departure burn
## is flown, so after each burn (once the ship is on its way) and on arrival in the destination's sphere of influence
## the remaining course is re-plotted from the ship's actual state, adding a correction node if needed and
## re-solving the capture/flyby burns. Moon destinations are reached in hops: after capturing around the parent
## body, the next leg is plotted automatically. Editing one of the course's nodes by hand hands that node to the
## player; when no course nodes are left, maintenance stops.

signal course_plotted(result: Dictionary)
signal course_updated(result: Dictionary)
signal course_completed(body_index: int)
signal plot_failed(reason: String)

@export var maneuvers: ManeuverPlanner
## Circularise at the destination (otherwise the course only intercepts it).
@export var capture: bool = true
@export var allow_gravity_assist: bool = true
## A gravity-assist course is chosen when it costs less than this fraction of the best direct course.
@export var gravity_assist_advantage: float = 0.9
## Desired periapsis radius at the destination (0 = automatic).
@export var arrival_periapsis: float = 0.0
## Earliest the first burn may be, in simulation seconds (time to review the course and turn the ship).
@export var min_lead_time: float = 15.0
## Earliest a course-correction burn may be, in simulation seconds.
@export var correction_lead_time: float = 8.0
## Real seconds a plot may take; scaled by time warp and added to the lead times.
@export var planning_budget: float = 4.0
## Re-plot the course in flight to correct execution errors.
@export var maintain_course: bool = true
## Fractions of each coast leg at which the course is re-checked (in addition to after every burn).
@export var check_points: PackedFloat32Array = PackedFloat32Array([0.3, 0.6])

var ship: Spaceship
var orbital_system: Node
var is_plotting: bool = false
## True while the computer is flying (maintaining) a plotted course.
var course_active: bool = false
## Human-readable status for the HUD.
var status: String = "Idle"
var last_result: Dictionary = {}

var _serial: int = 0
var _target: int = -1
var _encounters: Array = []
var _needs_update: bool = false
var _sphere_updated: Dictionary = {}
var _replacing: bool = false
var _leg_start: float = 0.0
var _checks_done: int = 0


func _ready() -> void:
	ship = get_parent() as Spaceship
	assert(ship != null, "NavigationComputer must be a child of a Spaceship")
	orbital_system = get_tree().get_first_node_in_group(Constants.ORBITAL_SYSTEM_GROUP)
	# Report plots that finish while the game is paused for planning.
	process_mode = Node.PROCESS_MODE_ALWAYS
	maneuvers.maneuver_completed.connect(_on_maneuver_completed)
	maneuvers.nodes_changed.connect(_on_nodes_changed)


#region Plotting

## Plots a course to `body` (a CelestialBody) and replaces the current maneuver nodes with it.
func plot_course(body: Node2D) -> void:
	var target: int = orbital_system.GetBodyIndex(body)
	if target < 0:
		_fail("unknown destination")
		return
	_serial += 1
	var serial := _serial
	_target = target
	course_active = false
	is_plotting = true
	status = "Plotting course to %s..." % orbital_system.GetBodyName(target)
	var job: RefCounted = orbital_system.PlotCourseAsync(ship.global_position, ship.linear_velocity, target,
		_options(min_lead_time))
	job.connect(&"Completed", func(result: Dictionary) -> void: _on_plotted(result, serial))


func cancel() -> void:
	_serial += 1
	is_plotting = false
	course_active = false
	status = "Idle"


func _options(lead_time: float) -> Dictionary:
	return {
		"capture": capture,
		"allow_gravity_assist": allow_gravity_assist,
		"assist_advantage": gravity_assist_advantage,
		"arrival_periapsis": arrival_periapsis,
		"min_lead_time": lead_time + planning_budget * orbital_system.TimeWarp,
		"thrust": ship.max_thrust,
		"mass": ship.dry_mass + ship.fuel,
		"exhaust_velocity": ship.exhaust_velocity,
	}


func _on_plotted(result: Dictionary, serial: int) -> void:
	if serial != _serial:
		return
	is_plotting = false
	last_result = result
	if not result.valid:
		_fail(_describe_failure(result.message))
		return
	if result.total_delta_v > ship.get_delta_v_remaining():
		_fail("needs %.1f px/s, only %.1f left" % [result.total_delta_v, ship.get_delta_v_remaining()])
		return
	if result.nodes[0].time - orbital_system.SimTime < 1.0:
		_fail("departure window passed while plotting, try again")
		return

	maneuvers.clear()
	_add_course_nodes(result.nodes)
	_encounters = result.encounters.duplicate(true)
	_needs_update = false
	_sphere_updated.clear()
	_start_leg()
	course_active = true
	_update_status(result)
	course_plotted.emit(result)


func _add_course_nodes(nodes: Array) -> void:
	_replacing = true
	for plotted: Dictionary in nodes:
		var node := maneuvers.add_node(plotted.time, plotted.prograde, plotted.radial)
		node.course = true
		node.kind = plotted.kind
	_replacing = false


func _update_status(result: Dictionary) -> void:
	var destination: String = orbital_system.GetBodyName(_target)
	var via := ""
	if result.assist_body >= 0:
		via = " via %s" % orbital_system.GetBodyName(result.assist_body)
	var remaining := _course_delta_v()
	if result.reaches_target:
		status = "Course to %s%s: %d burns, Δv %.1f" % [destination, via, _course_node_count(), remaining]
	else:
		status = "Course to %s (then on to %s): %d burns, Δv %.1f" % [
			orbital_system.GetBodyName(result.arrival_body), destination, _course_node_count(), remaining]


func _fail(reason: String) -> void:
	is_plotting = false
	status = "No course: %s" % reason
	plot_failed.emit(reason)


static func _describe_failure(message: String) -> String:
	match message:
		"no_transfer_found": return "no transfer window found"
		"no_departure_window", "no_ejection_window": return "no departure window"
		"on_collision_course": return "ship is on a collision course"
		"course_impacts": return "the course would impact"
		"no_encounter": return "could not reach the destination"
		"no_burns_needed": return "already there"
		"invalid_target": return "invalid destination"
		_: return message

#endregion


#region Course maintenance

func _physics_process(_delta: float) -> void:
	if not course_active or not maintain_course or is_plotting or _encounters.is_empty() or get_tree().paused:
		return
	if ship.is_burning() or _burn_imminent():
		return
	var encounter: Dictionary = _encounters[0]
	var dominant: int = orbital_system.FindDominantBody(ship.global_position)
	if dominant == encounter.body and not _sphere_updated.has(encounter.body):
		# Arrived in the destination's sphere: refine the periapsis and capture/flyby burn from the actual approach.
		_sphere_updated[encounter.body] = true
		_request_update()
	elif _is_on_route(dominant, encounter.body):
		var now: float = orbital_system.SimTime
		var due := _checks_done < check_points.size() 			and now >= _leg_start + check_points[_checks_done] * (float(encounter.time) - _leg_start)
		if _needs_update or due:
			_needs_update = false
			while _checks_done < check_points.size() 					and now >= _leg_start + check_points[_checks_done] * (float(encounter.time) - _leg_start):
				_checks_done += 1
			_request_update()


## True if a course burn starts soon: don't move nodes the ship is already turning for.
func _burn_imminent() -> bool:
	for node in maneuvers.nodes:
		if node.get("course", false):
			return maneuvers.get_burn_start(node) - orbital_system.SimTime < correction_lead_time * 2.0
	return false


func _is_on_route(dominant: int, body: int) -> bool:
	if dominant < 0:
		return false
	var current := body
	while current >= 0:
		if current == dominant:
			return true
		current = orbital_system.GetBodyParent(current)
	return false


func _request_update() -> void:
	is_plotting = true
	var serial := _serial
	var encounters: Array[Dictionary] = []
	encounters.assign(_encounters)
	var job: RefCounted = orbital_system.ContinueCourseAsync(ship.global_position, ship.linear_velocity, _target,
		encounters, _options(correction_lead_time))
	job.connect(&"Completed", func(result: Dictionary) -> void: _on_updated(result, serial))


func _on_updated(result: Dictionary, serial: int) -> void:
	if serial != _serial:
		return
	is_plotting = false
	if not course_active:
		return
	if not result.valid:
		# Keep flying the existing nodes; try again after the next burn.
		status = "Course update failed (%s), keeping current plan" % _describe_failure(result.message)
		return
	# Replace the course's pending nodes; nodes the player placed or took over are left alone.
	_replacing = true
	for node in maneuvers.nodes.duplicate():
		if node.get("course", false) and not maneuvers.is_executing(node):
			maneuvers.remove_node(node)
	_replacing = false
	_add_course_nodes(result.nodes)
	_encounters = result.encounters.duplicate(true)
	_update_status(result)
	course_updated.emit(result)


func _start_leg() -> void:
	_leg_start = orbital_system.SimTime
	_checks_done = 0


func _on_maneuver_completed(node: Dictionary) -> void:
	if not course_active or not node.get("course", false):
		return
	_start_leg()
	match node.get("kind", ""):
		"capture":
			var encounter: Dictionary = _encounters.pop_front() if not _encounters.is_empty() else {}
			if encounter.get("is_final", true):
				course_active = false
				status = "Arrived in orbit around %s" % orbital_system.GetBodyName(_target)
				course_completed.emit(_target)
			else:
				# Captured around the parent of a moon destination: plot the next hop.
				plot_course(orbital_system.GetBody(_target))
		"flyby":
			if not _encounters.is_empty():
				_encounters.pop_front()
			_needs_update = true
		_:
			_needs_update = true


func _on_nodes_changed() -> void:
	if _replacing or not course_active:
		return
	if _course_node_count() == 0:
		course_active = false
		status = "Course handed to manual control"


func _course_node_count() -> int:
	return maneuvers.nodes.filter(func(n: Dictionary) -> bool: return n.get("course", false)).size()


func _course_delta_v() -> float:
	var total := 0.0
	for node in maneuvers.nodes:
		if node.get("course", false):
			total += maneuvers.get_delta_v(node)
	return total

#endregion
