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
##
## Modes:
## - INTERCEPT: a close pass of the destination (periapsis `intercept_distance`), no capture.
## - ORBIT: capture into an elliptical orbit. Only for bodies that themselves orbit something (not the star).
## - PARK: capture into a circular parking orbit; the ship then freezes into it (Spaceship.park). Also valid for the
##   body currently being orbited, to park after an intercept or from an elliptical orbit.
##
## Engines (`engine_use`): ANY flies the course on the main drive (thrusters only turn the ship); THRUSTERS_ONLY flies
## every burn on the thrusters - slow, but quiet with cold gas thrusters. Purely radial thruster burns are translations.

signal course_plotted(result: Dictionary)
signal course_updated(result: Dictionary)
signal course_completed(body_index: int)
signal plot_failed(reason: String)
signal mode_changed(mode: Mode)
signal engine_use_changed(engine_use: EngineUse)

enum Mode { INTERCEPT, ORBIT, PARK }

const MODE_NAMES := ["Intercept", "Orbit", "Park"]

enum EngineUse { ANY, THRUSTERS_ONLY }

const ENGINE_USE_NAMES := ["Any engine", "Thrusters only"]

@export var maneuvers: ManeuverPlanner
@export var mode: Mode = Mode.PARK:
	set(value):
		mode = value
		mode_changed.emit(value)
## Which engines the course is flown with.
@export var engine_use: EngineUse = EngineUse.ANY:
	set(value):
		engine_use = value
		engine_use_changed.emit(value)
## Closest-approach (periapsis) radius for Intercept, in px from the body's centre (0 = automatic).
@export var intercept_distance: float = 0.0
## Orbit mode: apoapsis = arrival periapsis × this ratio (limited to the body's sphere of influence).
@export var orbit_apoapsis_ratio: float = 3.0
@export var allow_gravity_assist: bool = true
## A gravity-assist course is chosen when it costs less than this fraction of the best direct course.
@export var gravity_assist_advantage: float = 0.9
## Periapsis radius of the Orbit and Park orbits (0 = automatic from the body's size).
@export var arrival_periapsis: float = 0.0
## Earliest the first burn may be, in simulation seconds (time to review the course and turn the ship).
@export var min_lead_time: float = 15.0
## Earliest a course-correction burn may be, in simulation seconds.
@export var correction_lead_time: float = 8.0
## Real seconds a plot may take; scaled by time warp and added to the lead times.
@export var planning_budget: float = 4.0
## Largest single course correction, as a fraction of the remaining delta-v.
@export_range(0.0, 1.0) var max_correction_fraction: float = 0.25
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
# Set while the planner reports a completed course burn, so its node removal is not mistaken for a hand-over.
var _completing: bool = false
# Extra lead time for re-plots after a departure window passed while plotting.
var _extra_lead: float = 0.0
var _plot_started: float = 0.0
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


## An active course (e.g. coasting to an intercept), or a plot in progress, keeps the ship under physics.
func blocks_parking() -> bool:
	return course_active or is_plotting


#region Plotting

func cycle_mode() -> void:
	mode = ((mode + 1) % MODE_NAMES.size()) as Mode


func cycle_engine_use() -> void:
	engine_use = ((engine_use + 1) % ENGINE_USE_NAMES.size()) as EngineUse


## Drive the course's burns are flown with.
func get_drive() -> Spaceship.Drive:
	return Spaceship.Drive.THRUSTERS if engine_use == EngineUse.THRUSTERS_ONLY else Spaceship.Drive.MAIN


## Plots a course to `body` (a CelestialBody) in the current mode and replaces the current maneuver nodes with it.
func plot_course(body: Node2D) -> void:
	_extra_lead = 0.0
	_plot_course(body)


func _plot_course(body: Node2D) -> void:
	var target: int = orbital_system.GetBodyIndex(body)
	if target < 0:
		_fail("unknown destination")
		return
	var body_name: String = orbital_system.GetBodyName(target)
	var current := _is_current_body(target)
	match mode:
		Mode.INTERCEPT:
			if current:
				_fail("already within %s's sphere of influence" % body_name)
				return
		Mode.ORBIT:
			if orbital_system.GetBodyParent(target) < 0:
				_fail("Orbit needs a body that orbits something; use Park around %s" % body_name)
				return
			if current:
				_fail("already orbiting %s; use Park to circularise" % body_name)
				return
		Mode.PARK:
			if current and _park_now(target):
				return
	_serial += 1
	var serial := _serial
	_target = target
	course_active = false
	is_plotting = true
	_plot_started = orbital_system.SimTime
	status = "Plotting course to %s..." % orbital_system.GetBodyName(target)
	# Courses are predicted under full physics, so the ship must leave its parking orbit now, not when the plot arrives.
	ship.unpark()
	var job: RefCounted = orbital_system.PlotCourseAsync(ship.get_state_position(), ship.get_state_velocity(), target,
		_options(min_lead_time + _extra_lead))
	job.connect(&"Completed", func(result: Dictionary) -> void: _on_plotted(result, serial))


func cancel() -> void:
	_serial += 1
	is_plotting = false
	course_active = false
	status = "Idle"


## True when `target` is the body the ship is orbiting (or one of its ancestors, e.g. the star while around a planet).
func _is_current_body(target: int) -> bool:
	var body: int = orbital_system.FindDominantBody(ship.get_state_position())
	while body >= 0:
		if body == target:
			return true
		body = orbital_system.GetBodyParent(body)
	return false


## Park immediately if the ship is already parked or already in a near-circular orbit around `target`.
func _park_now(target: int) -> bool:
	var body_name: String = orbital_system.GetBodyName(target)
	if ship.is_parked() and ship.get_parked_body() == target:
		status = "Already parked around %s" % body_name
		return true
	if orbital_system.FindDominantBody(ship.get_state_position()) != target:
		return false
	var info: Dictionary = orbital_system.GetOrbitInfo(ship.get_state_position(), ship.get_state_velocity(), target)
	if info.bound and info.eccentricity <= ship.park_eccentricity and maneuvers.nodes.is_empty() and ship.park(target):
		status = "Parked around %s" % body_name
		course_completed.emit(target)
		return true
	return false


## Default capture periapsis, mirroring TransferPlanner.DefaultPeriapsis.
func _arrival_periapsis(target: int) -> float:
	if arrival_periapsis > 0.0:
		return arrival_periapsis
	var radius: float = orbital_system.GetBodyRadius(target)
	var sphere: float = orbital_system.GetBodySphereOfInfluence(target)
	return maxf(minf(radius * 2.0, sphere * 0.3), radius * 1.3)


func _options(lead_time: float) -> Dictionary:
	var periapsis := intercept_distance if mode == Mode.INTERCEPT else _arrival_periapsis(_target)
	var options := {
		"capture": mode != Mode.INTERCEPT,
		"capture_apoapsis": periapsis * orbit_apoapsis_ratio if mode == Mode.ORBIT else 0.0,
		"allow_gravity_assist": allow_gravity_assist,
		"assist_advantage": gravity_assist_advantage,
		"arrival_periapsis": periapsis,
		"min_lead_time": lead_time + planning_budget * orbital_system.TimeWarp,
		"max_correction_delta_v": maxf(1.0, ship.get_delta_v_remaining(get_drive()) * max_correction_fraction),
		"ship_radius": ship.get_hull_radius(),
	}
	options.merge(ship.get_engine_model(get_drive()))
	return options


func _on_plotted(result: Dictionary, serial: int) -> void:
	if serial != _serial:
		return
	is_plotting = false
	last_result = result
	if not result.valid:
		_fail(_describe_failure(result.message))
		return
	if result.total_delta_v > ship.get_delta_v_remaining(get_drive()):
		_fail("needs %.1f px/s, only %.1f left" % [result.total_delta_v / SpaceScale.MAP_SCALE,
			ship.get_delta_v_remaining(get_drive()) / SpaceScale.MAP_SCALE])
		return
	if result.nodes[0].time - orbital_system.SimTime < 1.0:
		# Plotting took longer than the lead time allowed for: try again with more lead time.
		var elapsed: float = orbital_system.SimTime - _plot_started
		if _extra_lead < 4.0 * min_lead_time + elapsed:
			_extra_lead = maxf(2.0 * _extra_lead, elapsed + min_lead_time)
			_plot_course(orbital_system.GetBody(_target))
			return
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
		var node := maneuvers.add_node(plotted.time, plotted.prograde, plotted.radial, get_drive())
		node.course = true
		node.kind = plotted.kind
	_replacing = false


func _update_status(result: Dictionary) -> void:
	var destination: String = orbital_system.GetBodyName(_target)
	var via := ""
	if result.assist_body >= 0:
		via = " via %s" % orbital_system.GetBodyName(result.assist_body)
	var remaining := _course_delta_v() / SpaceScale.MAP_SCALE # Shown in world px/s.
	var what: String = MODE_NAMES[mode]
	if result.reaches_target:
		status = "%s %s%s: %d burns, Δv %.1f" % [what, destination, via, _course_node_count(), remaining]
	else:
		status = what + " course to %s (then on to %s): %d burns, Δv %.1f" % [
			orbital_system.GetBodyName(result.arrival_body), destination, _course_node_count(), remaining]


func _fail(reason: String) -> void:
	is_plotting = false
	if engine_use == EngineUse.THRUSTERS_ONLY:
		reason += " on thrusters only (low thrust: long burns may not be possible here)"
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
	var dominant: int = orbital_system.FindDominantBody(ship.get_state_position())
	if not encounter.capture and encounter.get("is_final", true) and orbital_system.SimTime > float(encounter.time) \
			and maneuvers.nodes.filter(func(n: Dictionary) -> bool: return n.get("course", false)).is_empty():
		_encounters.pop_front()
		_complete() # Intercept: the closest approach has been passed.
		return
	if dominant == encounter.body and _receding_from(encounter.body):
		# Past periapsis inside the destination's sphere: the capture burn is due as soon as possible, and re-plotting
		# would only push it later and higher. Leave the plan alone.
		return
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


func _receding_from(body: int) -> bool:
	var now: float = orbital_system.SimTime
	var rel: Vector2 = ship.get_state_position() - orbital_system.GetBodyPosition(body, now)
	var rel_vel: Vector2 = ship.get_state_velocity() - orbital_system.GetBodyVelocity(body, now)
	return rel.dot(rel_vel) > 0.0


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
	ship.unpark()
	var job: RefCounted = orbital_system.ContinueCourseAsync(ship.get_state_position(), ship.get_state_velocity(), _target,
		encounters, _options(correction_lead_time))
	job.connect(&"Completed", func(result: Dictionary) -> void: _on_updated(result, serial))


func _on_updated(result: Dictionary, serial: int) -> void:
	if serial != _serial:
		return
	is_plotting = false
	if not course_active:
		return
	if not result.valid and result.message != "no_burns_needed":
		# Keep flying the existing nodes; try again after the next burn.
		status = "Course update failed (%s), keeping current plan" % _describe_failure(result.message)
		return
	# "no_burns_needed" is a valid update too: on course, and (for an intercept) nothing left to burn.
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


func _complete() -> void:
	course_active = false
	var body_name: String = orbital_system.GetBodyName(_target)
	match mode:
		Mode.PARK:
			# The capture leaves a near-circular orbit: freeze it into an exact parking orbit.
			if ship.park(_target):
				status = "Parked around %s" % body_name
			else:
				status = "In orbit around %s (could not park)" % body_name
		Mode.ORBIT:
			var info: Dictionary = orbital_system.GetOrbitInfo(ship.get_state_position(), ship.get_state_velocity(), _target)
			var radius: float = orbital_system.GetBodyRadius(_target)
			status = "In orbit around %s: Pe %d  Ap %d" % [body_name, roundi((info.periapsis - radius) / SpaceScale.MAP_SCALE),
				roundi((info.apoapsis - radius) / SpaceScale.MAP_SCALE)]
		Mode.INTERCEPT:
			var info: Dictionary = orbital_system.GetOrbitInfo(ship.get_state_position(), ship.get_state_velocity(), _target)
			status = "Intercepted %s (closest approach %d px)" % [body_name, roundi(info.periapsis / SpaceScale.MAP_SCALE)]
	course_completed.emit(_target)


func _start_leg() -> void:
	_leg_start = orbital_system.SimTime
	_checks_done = 0


func _on_maneuver_completed(node: Dictionary) -> void:
	if not course_active or not node.get("course", false):
		return
	_completing = true # The planner emits nodes_changed right after this.
	_start_leg()
	match node.get("kind", ""):
		"capture":
			var encounter: Dictionary = _encounters.pop_front() if not _encounters.is_empty() else {}
			if encounter.get("is_final", true):
				_complete()
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
	if _completing:
		_completing = false
		return
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
