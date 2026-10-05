class_name OrbitalNavigator
extends Node
## Autopilot for the parent Spaceship. Asks the C# planner for a transfer to `target_body`, then flies it:
## departure (ejection) burn, mid-course corrections, powered gravity-assist flybys, and a capture burn at
## periapsis. Every burn is a real finite burn executed by the ship's engine under Godot physics, so
## execution errors are expected and cleaned up by the corrections.

signal state_changed(new_state: State)
signal plan_ready(plan: Dictionary)
signal arrived(body_index: int)
signal navigation_failed(reason: String)

enum State { IDLE, PLANNING, WAITING_FOR_BURN, BURNING, COASTING, ARRIVED, FAILED }
## Mirrors AnotherEarth.Orbital.BurnKind.
enum BurnKind { IMPULSE, EJECTION, FLYBY_PERIAPSIS, CAPTURE_PERIAPSIS, CORRECTION }

@export var target_body: Node2D
@export var auto_start: bool = true
## Circularise at the target. When false the ship just intercepts it.
@export var capture: bool = true
@export var allow_gravity_assist: bool = true
## A gravity-assist route is taken when it costs less than this fraction of the best direct route.
## Values above 1 make NPCs prefer slingshots even at extra cost.
@export var gravity_assist_advantage: float = 0.9
## Target periapsis radius at arrival (0 = automatic from the body's size).
@export var arrival_periapsis: float = 0.0
## Earliest a planned burn may start (time to turn the ship around), in simulation seconds.
@export var min_lead_time: float = 8.0
## Fractions of each coast leg at which a course correction is computed.
@export var correction_points: PackedFloat32Array = PackedFloat32Array([0.2, 0.55, 0.85])
## Corrections smaller than this (px/s) are skipped.
@export var min_correction_delta_v: float = 0.05
@export var max_replans: int = 3
## Real seconds the planner may take; scaled by time warp and added to the lead time of the first burn.
@export var planning_budget: float = 4.0
## Largest course correction as a fraction of the remaining delta-v.
@export_range(0.0, 1.0) var max_correction_fraction: float = 0.25
## After arrival, re-circularise whenever tides drag the periapsis below this multiple of the body radius.
@export var station_keeping_periapsis: float = 1.2
## Print autopilot decisions to the output.
@export var debug_log: bool = false

var state: State = State.IDLE
var plan: Dictionary = {}
var ship: Spaceship
var orbital_system: Node
var target_index: int = -1

var _burns: Array[Dictionary] = []
var _encounters: Array[Dictionary] = []
var _active_burn: Dictionary = {}
var _leg_start: float = 0.0
var _corrections_done: int = 0
var _serial: int = 0
var _busy: bool = false
var _inside_encounter: bool = false
var _arrival_corrected: bool = false
var _replans: int = 0


func _ready() -> void:
	# Run after the OrbitalSystem but before the ship, so a burn started this tick thrusts this tick.
	process_physics_priority = -1
	ship = get_parent() as Spaceship
	assert(ship != null, "OrbitalNavigator must be a child of a Spaceship")
	ship.burn_completed.connect(_on_burn_completed)
	ship.fuel_depleted.connect(_on_fuel_depleted)
	orbital_system = get_tree().get_first_node_in_group(Constants.ORBITAL_SYSTEM_GROUP)
	if auto_start and target_body:
		if not orbital_system.IsReady:
			await Signal(orbital_system, &"EphemerisRebuilt")
		# Let ships settle into their starting orbits first.
		await get_tree().physics_frame
		navigate_to(target_body)


## Plans and flies a transfer to `body` (a CelestialBody).
func navigate_to(body: Node2D) -> void:
	target_body = body
	target_index = orbital_system.GetBodyIndex(body)
	if target_index < 0:
		_fail("unknown_target")
		return
	_replans = 0
	_plan()


## Stops the autopilot and hands control back.
func cancel() -> void:
	_serial += 1
	_busy = false
	_burns.clear()
	_encounters.clear()
	if ship.is_burning():
		ship.cancel_burn()
	ship.release_heading()
	_set_state(State.IDLE)


func is_active() -> bool:
	return state in [State.PLANNING, State.WAITING_FOR_BURN, State.BURNING, State.COASTING]


## The next pending burn, or an empty Dictionary.
func get_next_burn() -> Dictionary:
	return _burns[0] if not _burns.is_empty() else {}


func get_next_encounter() -> Dictionary:
	return _encounters[0] if not _encounters.is_empty() else {}


func _physics_process(_delta: float) -> void:
	match state:
		State.WAITING_FOR_BURN:
			_update_waiting()
		State.COASTING:
			_update_coasting()
		State.ARRIVED:
			_update_station_keeping()


#region Planning

func _plan() -> void:
	_serial += 1
	var serial := _serial
	_burns.clear()
	_encounters.clear()
	ship.release_heading()
	_busy = true
	_set_state(State.PLANNING)
	var options := {
		"capture": capture,
		"allow_gravity_assist": allow_gravity_assist,
		"assist_advantage": gravity_assist_advantage,
		"arrival_periapsis": arrival_periapsis,
		"min_lead_time": min_lead_time + planning_budget * orbital_system.TimeWarp,
	}
	options.merge(_engine())
	var job: RefCounted = orbital_system.PlanTransferAsync(ship.global_position, ship.linear_velocity, target_index, options)
	job.connect(&"Completed", func(result: Dictionary) -> void: _on_plan(result, serial))


func _on_plan(result: Dictionary, serial: int) -> void:
	if serial != _serial:
		return
	_busy = false
	_log("plan %s: est. dv %.1f, refined %s (miss %.0f), %d burns" % [result.message,
		result.estimated_delta_v, result.refined, result.refine_miss, result.burns.size()])
	if not result.valid:
		_fail(result.message)
		return
	if result.estimated_delta_v > ship.get_delta_v_remaining():
		_fail("insufficient_delta_v")
		return
	plan = result
	for burn: Dictionary in result.burns:
		var copy := burn.duplicate()
		copy.resolved = burn.kind in [BurnKind.IMPULSE, BurnKind.EJECTION, BurnKind.CORRECTION]
		_burns.append(copy)
	for encounter: Dictionary in result.encounters:
		_encounters.append(encounter.duplicate())
	_corrections_done = 0
	_inside_encounter = false
	_arrival_corrected = false
	plan_ready.emit(plan)

	var now: float = orbital_system.SimTime
	if not _burns.is_empty() and _burns[0].resolved:
		if _burns[0].time - _burn_half_duration(_burns[0]) < now:
			_log("departure window passed while planning")
			_replan("departure_window_missed")
			return
		_leg_start = _burns[0].time
		_set_state(State.WAITING_FOR_BURN)
	else:
		_leg_start = now
		_set_state(State.COASTING)


func _replan(reason: String) -> void:
	_replans += 1
	if _replans > max_replans:
		_fail(reason)
		return
	_plan()

#endregion


#region Burns

func _update_waiting() -> void:
	if _burns.is_empty():
		_set_state(State.COASTING)
		return
	var burn: Dictionary = _burns[0]
	var now: float = orbital_system.SimTime
	if burn.kind == BurnKind.EJECTION:
		_track_ejection_point(burn, now)
	var delta_v: Vector2 = burn.delta_v
	var start: float = burn.time - _burn_half_duration(burn)
	if now >= start - ship.get_turn_time(delta_v) - 1.0:
		ship.hold_heading(delta_v)
	if now >= start:
		_log("burn %s: %.2f px/s" % [BurnKind.keys()[burn.kind], delta_v.length()])
		_burns.pop_front()
		_active_burn = burn
		ship.release_heading()
		ship.execute_burn(delta_v)
		_set_state(State.BURNING)


## Ejection burns are tied to a point of the parking orbit: keep the burn time and direction locked to where the
## ship actually is, so phase drift over many orbits does not move the burn.
func _track_ejection_point(burn: Dictionary, now: float) -> void:
	if not burn.has("planned_time"):
		burn.planned_time = burn.time
	var body: int = burn.body
	var rel: Vector2 = ship.global_position - orbital_system.GetBodyPosition(body, now)
	var rel_vel: Vector2 = ship.linear_velocity - orbital_system.GetBodyVelocity(body, now)
	var h := rel.cross(rel_vel)
	var spin := 1.0 if h >= 0.0 else -1.0
	var angular_rate := absf(h) / rel.length_squared()
	var period := TAU / angular_rate
	if absf(now - float(burn.planned_time)) > period:
		return # Too early to lock on; keep the planned time.
	# Of the passes over the burn point, take the one closest to the planned time.
	var to_go := fposmod((float(burn.reference_angle) - rel.angle()) * spin, TAU) / angular_rate
	var best := now + to_go
	for k: int in [-1, 1]:
		var candidate: float = now + to_go + k * period
		if absf(candidate - float(burn.planned_time)) < absf(best - float(burn.planned_time)):
			best = candidate
	burn.time = best
	# Frame at the burn point itself (the burn starts before the ship gets there).
	var radial := Vector2.from_angle(burn.reference_angle)
	var along := Vector2(-radial.y, radial.x) * spin
	var local: Vector2 = burn.local_delta_v
	burn.delta_v = radial * local.x + along * local.y


func _burn_half_duration(burn: Dictionary) -> float:
	return 0.5 * ship.get_burn_duration((burn.delta_v as Vector2).length())


func _on_burn_completed(_achieved: Vector2) -> void:
	if state != State.BURNING:
		return
	var burn := _active_burn
	_active_burn = {}
	match burn.kind:
		BurnKind.CAPTURE_PERIAPSIS:
			var encounter: Dictionary = _encounters.pop_front() if not _encounters.is_empty() else {}
			if encounter.get("is_final", true) and encounter.get("body", target_index) == target_index:
				_set_state(State.ARRIVED)
				arrived.emit(target_index)
			else:
				# Captured around the parent of a moon target: plan the next hop from this orbit.
				_replans = 0
				_plan()
			return
		BurnKind.FLYBY_PERIAPSIS:
			_advance_encounter()
		BurnKind.IMPULSE, BurnKind.EJECTION:
			_leg_start = burn.time
			_corrections_done = 0
	_continue_after_burn()


func _continue_after_burn() -> void:
	if not _burns.is_empty() and _burns[0].resolved:
		_set_state(State.WAITING_FOR_BURN)
	else:
		_set_state(State.COASTING)


func _on_fuel_depleted() -> void:
	if is_active():
		_fail("out_of_fuel")

#endregion


#region Station keeping

func _update_station_keeping() -> void:
	if station_keeping_periapsis <= 0.0 or ship.is_burning() or target_index < 0:
		return
	var now: float = orbital_system.SimTime
	var info: Dictionary = orbital_system.GetOrbitInfo(ship.global_position, ship.linear_velocity, target_index)
	var radius: float = orbital_system.GetBodyRadius(target_index)
	if info.is_empty() or info.periapsis > radius * station_keeping_periapsis:
		return
	# Circular velocity at the current point, keeping the direction of travel.
	var rel: Vector2 = ship.global_position - orbital_system.GetBodyPosition(target_index, now)
	var rel_vel: Vector2 = ship.linear_velocity - orbital_system.GetBodyVelocity(target_index, now)
	var spin := 1.0 if rel.cross(rel_vel) >= 0.0 else -1.0
	var circular := Vector2(-rel.y, rel.x).normalized() * spin * sqrt(orbital_system.GetBodyMu(target_index) / rel.length())
	var delta_v := circular - rel_vel
	if delta_v.length() < min_correction_delta_v or delta_v.length() > ship.get_delta_v_remaining():
		return
	_log("station keeping: periapsis %.0f, burning %.2f px/s" % [info.periapsis, delta_v.length()])
	ship.execute_burn(delta_v)

#endregion


#region Coasting

func _update_coasting() -> void:
	if _busy:
		return
	if not _burns.is_empty() and _burns[0].resolved:
		_set_state(State.WAITING_FOR_BURN)
		return
	if _encounters.is_empty():
		_set_state(State.ARRIVED)
		arrived.emit(target_index)
		return

	var encounter: Dictionary = _encounters[0]
	var now: float = orbital_system.SimTime
	var dominant: int = orbital_system.FindDominantBody(ship.global_position)
	var body: int = encounter.body

	if dominant == body:
		_inside_encounter = true
		var burn := _pending_burn_for(body)
		if not burn.is_empty():
			_resolve_periapsis_burn(burn)
		return
	if _inside_encounter:
		# Left the sphere of an unpowered flyby.
		_advance_encounter()
		return

	# Mid-course corrections, once clear of the departure body.
	var leg: float = maxf(encounter.time - _leg_start, 1.0)
	if _corrections_done < correction_points.size() and _is_on_route(dominant, body) \
			and now >= _leg_start + correction_points[_corrections_done] * leg:
		_corrections_done += 1
		_request_correction(encounter)
		return

	if now > encounter.time + maxf(60.0, 0.25 * leg):
		_log("missed encounter with %s" % orbital_system.GetBodyName(body))
		_replan("encounter_missed")


func _advance_encounter() -> void:
	if not _encounters.is_empty():
		_encounters.pop_front()
	_inside_encounter = false
	_arrival_corrected = false
	_leg_start = orbital_system.SimTime
	_corrections_done = 0


func _pending_burn_for(body: int) -> Dictionary:
	if _burns.is_empty():
		return {}
	var burn: Dictionary = _burns[0]
	if burn.body == body and burn.kind in [BurnKind.FLYBY_PERIAPSIS, BurnKind.CAPTURE_PERIAPSIS]:
		return burn
	return {}


## True when `dominant` is the encounter body or one of its ancestors (i.e. we left the departure body).
func _is_on_route(dominant: int, body: int) -> bool:
	if dominant < 0:
		return false
	var current := body
	while current >= 0:
		if current == dominant:
			return true
		current = orbital_system.GetBodyParent(current)
	return false


## Periapsis burns are only computed once inside the body's sphere, from a fresh prediction of the pass.
func _resolve_periapsis_burn(burn: Dictionary) -> void:
	_busy = true
	var serial := _serial
	var options := {"max_time": 900.0, "watch_body": burn.body, "stop_after_orbits": 0.0, "sample_every": 30}
	var job: RefCounted = orbital_system.PredictAsync(ship.global_position, ship.linear_velocity, options)
	job.connect(&"Completed", func(prediction: RefCounted) -> void: _on_periapsis_predicted(prediction, burn, serial))


func _on_periapsis_predicted(prediction: RefCounted, burn: Dictionary, serial: int) -> void:
	if serial != _serial:
		return
	_busy = false
	var approach: Dictionary = prediction.GetClosestApproach()
	if not approach.found:
		return
	var rel_pos: Vector2 = approach.relative_position
	var rel_vel: Vector2 = approach.relative_velocity
	var radius: float = orbital_system.GetBodyRadius(burn.body)
	var encounter: Dictionary = _encounters[0]
	var tolerance := maxf(0.25 * absf(encounter.periapsis), 0.5 * radius)
	var off_target := absf(float(approach.signed_distance) - float(encounter.periapsis)) > tolerance
	if prediction.EndReason == "collision" or approach.distance < radius * 1.05 or (off_target and not _arrival_corrected):
		# Impact course or a poor periapsis: correct it first, the periapsis burn is resolved again afterwards.
		_arrival_corrected = true
		_log("arriving at %s with periapsis %.0f (want %.0f): correcting" % [orbital_system.GetBodyName(burn.body),
			approach.signed_distance, encounter.periapsis])
		_request_correction(encounter)
		return

	var delta_v: Vector2
	if burn.kind == BurnKind.CAPTURE_PERIAPSIS:
		# Velocity of a circular orbit at the periapsis point, turning the same way we are travelling.
		var mu: float = orbital_system.GetBodyMu(burn.body)
		var spin := 1.0 if rel_pos.cross(rel_vel) >= 0.0 else -1.0
		var circular := Vector2(-rel_pos.y, rel_pos.x).normalized() * spin * sqrt(mu / rel_pos.length())
		delta_v = circular - rel_vel
	else:
		delta_v = rel_vel.normalized() * float(burn.prograde_delta_v)

	burn.time = maxf(approach.time, orbital_system.SimTime + min_lead_time)
	if burn.kind == BurnKind.FLYBY_PERIAPSIS and _encounters.size() > 1:
		_target_flyby_burn(burn, delta_v)
		return
	burn.delta_v = delta_v
	burn.resolved = true
	_set_state(State.WAITING_FOR_BURN)


## A powered flyby is aimed at the *next* encounter: the targeting solver adjusts the periapsis burn so the outgoing
## leg reaches it, starting from the patched-conic estimate.
func _target_flyby_burn(burn: Dictionary, estimate: Vector2) -> void:
	_busy = true
	var serial := _serial
	var next: Dictionary = _encounters[1]
	var now: float = orbital_system.SimTime
	var horizon: float = maxf(next.time, now) + maxf(120.0, 0.5 * (next.time - now))
	var max_dv := maxf(1.0, ship.get_delta_v_remaining() * 0.5)
	var job: RefCounted = orbital_system.RefineBurnAsync(ship.global_position, ship.linear_velocity, burn.time,
		estimate, next.body, next.periapsis, next.time, false, horizon, max_dv, _engine())
	job.connect(&"Completed", func(result: Dictionary) -> void:
		if serial != _serial:
			return
		_busy = false
		var delta_v := estimate
		if result.has_encounter and result.miss < float(result.initial_miss):
			delta_v = result.delta_v
			next.time = result.encounter_time
		_log("flyby burn targeted at %s: %.2f px/s (estimate %.2f), periapsis %.0f (want %.0f)" % [
			orbital_system.GetBodyName(next.body), delta_v.length(), estimate.length(), result.periapsis, next.periapsis])
		if delta_v.length() < min_correction_delta_v:
			_burns.pop_front() # Unpowered flyby: the encounter advances when we leave the sphere.
			return
		burn.delta_v = delta_v
		burn.resolved = true
		_set_state(State.WAITING_FOR_BURN))


func _request_correction(encounter: Dictionary) -> void:
	_busy = true
	var serial := _serial
	var now: float = orbital_system.SimTime
	var burn_time := now + min_lead_time
	var horizon: float = maxf(encounter.time, now) + maxf(120.0, 0.5 * (encounter.time - now))
	var max_dv := maxf(1.0, ship.get_delta_v_remaining() * max_correction_fraction)
	var job: RefCounted = orbital_system.RefineBurnAsync(ship.global_position, ship.linear_velocity, burn_time,
		Vector2.ZERO, encounter.body, encounter.periapsis, encounter.time, false, horizon, max_dv, _engine())
	job.connect(&"Completed", func(result: Dictionary) -> void: _on_correction(result, burn_time, encounter, serial))


func _on_correction(result: Dictionary, burn_time: float, encounter: Dictionary, serial: int) -> void:
	if serial != _serial:
		return
	_busy = false
	_log("correction to %s: dv %.2f, periapsis %.0f (want %.0f), converged %s" % [
		orbital_system.GetBodyName(encounter.body), (result.delta_v as Vector2).length(), result.periapsis,
		encounter.periapsis, result.converged])
	var improved: bool = result.has_encounter and result.miss < 0.5 * float(result.initial_miss)
	if not result.has_encounter or not (result.converged or improved):
		return # Try again at the next correction point.
	var delta_v: Vector2 = result.delta_v
	var shift: float = result.encounter_time - encounter.time
	encounter.time = result.encounter_time
	for burn: Dictionary in _burns:
		if burn.body == encounter.body and not burn.resolved:
			burn.time += shift
	if delta_v.length() < min_correction_delta_v:
		return
	_burns.push_front({
		"kind": BurnKind.CORRECTION,
		"time": burn_time,
		"delta_v": delta_v,
		"prograde_delta_v": 0.0,
		"body": encounter.body,
		"resolved": true,
	})
	_set_state(State.WAITING_FOR_BURN)

#endregion


func _engine() -> Dictionary:
	return {"thrust": ship.max_thrust, "mass": ship.dry_mass + ship.fuel, "exhaust_velocity": ship.exhaust_velocity}


func _log(message: String) -> void:
	if debug_log:
		print("[%.1f] %s: %s" % [orbital_system.SimTime, ship.name, message])


func _set_state(new_state: State) -> void:
	if state == new_state:
		return
	state = new_state
	state_changed.emit(new_state)


func _fail(reason: String) -> void:
	_serial += 1
	_busy = false
	_burns.clear()
	_encounters.clear()
	ship.release_heading()
	_set_state(State.FAILED)
	navigation_failed.emit(reason)
	push_warning("%s navigation failed: %s" % [ship.name, reason])
