class_name Spaceship
extends RigidBody2D
## A ship flying under Godot's own 2D physics. Gravity comes from the point-gravity Area2D wells that
## every CelestialBody creates, so this script only handles the engine: thrust, fuel and attitude.
##
## The body lives on the orbital map (see SpaceScale), in map units: engines push it with MAP_SCALE of their thrust
## and their exhaust velocity is scaled the same way, so accelerations and delta-v are in map units while fuel use is
## unchanged. Facing belongs to local space: the body never rotates on the map; `facing` and `spin` are integrated
## here at world scale from the thruster torque, and only local-space drawing shows them.
##
## Fuel use follows the rocket equation: thrust F consumes F / exhaust_velocity mass per second,
## so total delta-v = exhaust_velocity * ln(wet mass / dry mass).

signal burn_started(delta_v: Vector2)
signal burn_completed(achieved: Vector2)
signal fuel_depleted
signal crashed(body: Node)
signal parked(body: int)
signal unparked

## Which engines a burn uses. MAIN falls back to the thrusters (and THRUSTERS to the main engine) if one is missing.
enum Drive { MAIN, THRUSTERS, BOTH }

const DRIVE_NAMES := ["Main drive", "Thrusters", "Main + thrusters"]
## Fraction of the full angular acceleration planned for when braking a turn (margin for the discrete step).
const TURN_PROFILE := 0.9

@export_category("Engine")
## Hull mass without fuel or engines.
@export var dry_mass: float = 8.0
@export var fuel_capacity: float = 50.0
@export var fuel: float = 50.0

## Definition for the main engine
@export var main_engine:EngineDefinition
## Maximum allowable mass of the engine installed as the main drive
@export var max_engine_mass:float = 1.5
## Thrusters are lower power systems that provide secondary propulsion and turn the ship.
@export var thrusters:EngineDefinition
## Maximum allowable mass of the engine installed as the ship's turning and maneuvering thrusters.
@export var max_thruster_mass:float = 0.5

@export_category("Attitude")
## Turn rate limit in radians per second. Turning is done by the thrusters (their turn_torque) and costs fuel:
## every turn spins the ship up and back down, so faster turns cost more.
@export_range(0.1, 10.0, 0.01, "radians_as_degrees") var max_turn_rate: float = 1.6
## Radius of gyration of the hull in world px: moment of inertia = mass * radius_of_gyration^2.
@export var radius_of_gyration: float = 1.5
## Lever arm of the attitude thrusters in px: a torque T takes T / thruster_arm of thrust.
@export var thruster_arm: float = 8.0
## A burn only fires while the nose is within this angle of the burn direction.
@export_range(0.0, 45.0, 0.1, "radians_as_degrees") var burn_alignment: float = deg_to_rad(5.0)
## Remaining delta-v (world px/s) at which an automatic burn is considered complete.
@export var burn_tolerance: float = 0.02

@export_category("Orbit")
## On spawn, give the ship the velocity of a circular orbit around the dominant body.
@export var start_in_circular_orbit: bool = true
@export var orbit_retrograde: bool = false

@export_category("Parking Orbit")
## Freeze into an exact circular "parking orbit" when the orbit is circular and nothing needs the ship.
## A parked ship is moved along its circle without any force integration: no cost, and no floating point drift.
@export var auto_park: bool = true
## Maximum eccentricity that counts as circular for automatic parking.
@export var park_eccentricity: float = 0.03
## Seconds (simulation) between automatic parking checks.
@export var park_check_interval: float = 1.0

@export_category("Visual")
@export var hull_color: Color = Color(0.9, 0.95, 1.0)
@export var hull_size: float = 8.0

## Manual throttle (0..1) along the nose. Ignored during automatic burns.
var throttle: float = 0.0
## Manual turn input (-1..1). Overrides any held heading.
var steer: float = 0.0
## Engines used by the manual throttle.
var manual_drive: Drive = Drive.MAIN
## Manual thruster translation in world space (length 0..1 is the throttle): the thrusters push the ship along it
## without turning. Fired alongside the manual throttle; ignored during automatic burns.
var manual_translation := Vector2.ZERO
## Facing in local space (radians, 0 = +x) and its rate of turn (rad/s). The map body itself never rotates.
var facing := 0.0
var spin := 0.0
## Engines knocked out by combat damage (CombatHull) produce no thrust.
var main_engine_online := true
var thrusters_online := true

var orbital_system: Node

var _burning := false
var _burn_remaining := Vector2.ZERO
var _burn_achieved := Vector2.ZERO
var _burn_drive: Drive = Drive.MAIN
var _burn_translate := false
var _held_heading := Vector2.ZERO
# Last tick's engine output, for drawing: force, drive, direction (global) and attitude torque.
var _current_thrust := 0.0
var _current_drive: Drive = Drive.MAIN
var _current_direction := Vector2.ZERO
var _current_torque := 0.0
var _current_translation := Vector2.ZERO

# Parking orbit: circle of radius _park_radius around _park_body, angle = _park_angle0 + _park_rate * (t - _park_t0).
var _park_body := -1
var _park_radius := 0.0
var _park_rate := 0.0
var _park_angle0 := 0.0
var _park_t0 := 0.0
var _next_park_check := 0.0


func _ready() -> void:
	# Attitude is simulated in local space, not by the map body.
	facing = global_rotation
	rotation = 0.0
	lock_rotation = true
	gravity_scale = 1.0
	linear_damp_mode = RigidBody2D.DAMP_MODE_REPLACE
	linear_damp = 0.0
	angular_damp_mode = RigidBody2D.DAMP_MODE_REPLACE
	angular_damp = 0.0
	can_sleep = false
	contact_monitor = true
	max_contacts_reported = 4
	body_entered.connect(_on_body_entered)
	if main_engine and main_engine.mass > max_engine_mass:
		push_warning("%s: main engine %s (mass %.2f) exceeds the main engine mass limit %.2f"
			% [name, main_engine.name, main_engine.mass, max_engine_mass])
	if thrusters and thrusters.mass > max_thruster_mass:
		push_warning("%s: thrusters %s (mass %.2f) exceed the thruster mass limit %.2f"
			% [name, thrusters.name, thrusters.mass, max_thruster_mass])
	if not thrusters or thrusters.turn_torque <= 0.0:
		push_warning("%s has no attitude thrusters: it cannot turn" % name)
	_update_mass()
	orbital_system = get_tree().get_first_node_in_group(Constants.ORBITAL_SYSTEM_GROUP)
	if start_in_circular_orbit and orbital_system:
		if not orbital_system.IsReady:
			await Signal(orbital_system, &"EphemerisRebuilt")
		var body: int = orbital_system.FindDominantBody(global_position)
		if body >= 0:
			linear_velocity = orbital_system.GetCircularVelocity(global_position, body, orbit_retrograde)


func _physics_process(delta: float) -> void:
	if is_parked():
		if _wants_control():
			unpark()
		else:
			_update_parked()
			return
	elif auto_park and orbital_system and orbital_system.IsReady and orbital_system.SimTime >= _next_park_check:
		_next_park_check = orbital_system.SimTime + park_check_interval
		_try_auto_park()
	# Mass is updated at the start of the tick so the physics step uses the mass the thrust was computed for.
	_update_mass()
	var nose := get_nose()
	var direction := nose
	var drive := manual_drive
	var force := 0.0
	_current_torque = 0.0

	if _burning:
		drive = _burn_drive
		var thrust := get_drive_thrust(drive)
		if _burn_remaining.length() <= burn_tolerance * SpaceScale.MAP_SCALE:
			_finish_burn()
			_set_turn_rate(0.0, delta)
		elif _burn_translate:
			# Thrusters push along the burn vector whatever the heading: no turning needed, but a held heading is
			# still flown to.
			if _held_heading != Vector2.ZERO:
				_turn_toward(_held_heading, delta)
			else:
				_set_turn_rate(0.0, delta)
			direction = _burn_remaining.normalized()
			force = minf(thrust, _burn_remaining.length() * mass / delta)
		else:
			var target := _burn_remaining.normalized()
			_turn_toward(target, delta)
			if absf(nose.angle_to(target)) <= burn_alignment:
				# Never overshoot: the last tick only applies what is left.
				force = minf(thrust, _burn_remaining.dot(nose) * mass / delta)
	else:
		if steer != 0.0:
			_set_turn_rate(clampf(steer, -1.0, 1.0) * max_turn_rate, delta)
		elif _held_heading != Vector2.ZERO:
			_turn_toward(_held_heading, delta)
		else:
			_set_turn_rate(0.0, delta)
		force = get_drive_thrust(drive) * clampf(throttle, 0.0, 1.0)

	force = _consume_fuel(force, get_drive_exhaust_velocity(drive), delta)
	_current_thrust = force
	_current_drive = drive
	_current_direction = direction
	if force > 0.0:
		apply_central_force(direction * force)
		if _burning:
			var achieved := direction * (force / mass * delta)
			_burn_remaining -= achieved
			_burn_achieved += achieved
	_apply_manual_translation(delta)
	facing = wrapf(facing + spin * delta, -PI, PI)
	queue_redraw()


## Thrusters push along `manual_translation` whatever the heading.
func _apply_manual_translation(delta: float) -> void:
	_current_translation = Vector2.ZERO
	if _burning or manual_translation == Vector2.ZERO or thrusters == null or not thrusters_online:
		return
	var thrust := get_drive_thrust(Drive.THRUSTERS) * minf(manual_translation.length(), 1.0)
	var force := _consume_fuel(thrust, get_drive_exhaust_velocity(Drive.THRUSTERS), delta)
	if force > 0.0:
		_current_translation = manual_translation.normalized() * force
		apply_central_force(_current_translation)


#region Engine

## Mass without fuel: hull plus installed engines and combat armor.
func get_dry_mass() -> float:
	var total := dry_mass
	if main_engine:
		total += main_engine.mass
	if thrusters:
		total += thrusters.mass
	for child in get_children():
		if child is CombatHull:
			total += child.armor_mass
	return total


func _update_mass() -> void:
	mass = get_dry_mass() + fuel


## Engines that fire for `drive` (falls back to whichever engine is installed).
func get_drive_engines(drive: Drive) -> Array[EngineDefinition]:
	var main: EngineDefinition = main_engine if main_engine_online else null
	var secondary: EngineDefinition = thrusters if thrusters_online else null
	var engines: Array[EngineDefinition] = []
	match drive:
		Drive.MAIN:
			engines.append(main if main else secondary)
		Drive.THRUSTERS:
			engines.append(secondary if secondary else main)
		Drive.BOTH:
			engines.append(main)
			engines.append(secondary)
	return engines.filter(func(e: EngineDefinition) -> bool: return e != null)


func has_drive(drive: Drive) -> bool:
	return not get_drive_engines(drive).is_empty()


## Thrust of `drive` on the orbital map: MAP_SCALE of the engines' thrust (see SpaceScale).
func get_drive_thrust(drive: Drive) -> float:
	var total := 0.0
	for engine in get_drive_engines(drive):
		total += engine.max_thrust
	return total * SpaceScale.MAP_SCALE


## Effective exhaust velocity of the engines of `drive` firing together (total thrust / total mass flow), in map
## units: delta-v from it is map delta-v. Scaling thrust and exhaust velocity together leaves fuel use unchanged.
func get_drive_exhaust_velocity(drive: Drive) -> float:
	var thrust := 0.0
	var flow := 0.0
	for engine in get_drive_engines(drive):
		if engine.exhaust_velocity > 0.0:
			thrust += engine.max_thrust
			flow += engine.max_thrust / engine.exhaust_velocity
	return thrust / flow * SpaceScale.MAP_SCALE if flow > 0.0 else SpaceScale.MAP_SCALE


## {thrust, mass, exhaust_velocity} of `drive` for the C# planners and predictor (finite burns).
func get_engine_model(drive: Drive = Drive.MAIN) -> Dictionary:
	return {
		"thrust": get_drive_thrust(drive),
		"mass": get_dry_mass() + fuel,
		"exhaust_velocity": get_drive_exhaust_velocity(drive),
	}


## Delta-v left in the tanks using `drive` (rocket equation), in map units.
func get_delta_v_remaining(drive: Drive = Drive.MAIN) -> float:
	return get_drive_exhaust_velocity(drive) * log((get_dry_mass() + fuel) / get_dry_mass())


## Seconds of full thrust needed for a burn of `delta_v` (map units) with the current mass.
func get_burn_duration(delta_v: float, drive: Drive = Drive.MAIN) -> float:
	return burn_duration_for(get_dry_mass() + fuel, delta_v, drive)


## Seconds of full thrust needed for a burn of `delta_v` (map units) starting at mass `start_mass`.
func burn_duration_for(start_mass: float, delta_v: float, drive: Drive) -> float:
	var exhaust := get_drive_exhaust_velocity(drive)
	var thrust := get_drive_thrust(drive)
	if thrust <= 0.0:
		return INF
	return start_mass * (1.0 - exp(-delta_v / exhaust)) / (thrust / exhaust)


## Thruster torque available for turning.
func get_turn_torque() -> float:
	return thrusters.turn_torque if thrusters and thrusters_online else 0.0


## Moment of inertia of the hull in local space.
func get_turn_inertia() -> float:
	return (get_dry_mass() + fuel) * radius_of_gyration * radius_of_gyration


## Angular acceleration the thrusters can give the ship (rad/s^2).
func get_turn_acceleration() -> float:
	var current_inertia := get_turn_inertia()
	return get_turn_torque() / current_inertia if current_inertia > 0.0 else 0.0


## Direction the nose points (local space facing).
func get_nose() -> Vector2:
	return Vector2.from_angle(facing)


## Seconds needed to turn the nose to `direction` from rest (accelerate, coast at max_turn_rate, brake).
func get_turn_time(direction: Vector2) -> float:
	var angle := absf(get_nose().angle_to(direction))
	var accel := get_turn_acceleration() * TURN_PROFILE
	if accel <= 0.0:
		return 0.0 # Cannot turn at all.
	var time: float
	if angle <= max_turn_rate * max_turn_rate / accel:
		time = 2.0 * sqrt(angle / accel)
	else:
		time = angle / max_turn_rate + max_turn_rate / accel
	return time * 1.1


## Starts an automatic burn: turns to the remaining delta-v vector (map units) and thrusts until it is used up.
## A `translate` burn pushes along the delta-v vector without turning (thrusters only).
func execute_burn(delta_v: Vector2, drive: Drive = Drive.MAIN, translate_burn: bool = false) -> void:
	unpark()
	_burning = true
	_burn_remaining = delta_v
	_burn_achieved = Vector2.ZERO
	_burn_drive = drive
	_burn_translate = translate_burn
	burn_started.emit(delta_v)


func cancel_burn() -> void:
	_burning = false
	_burn_remaining = Vector2.ZERO


func is_burning() -> bool:
	return _burning


func get_burn_remaining() -> Vector2:
	return _burn_remaining


## Keeps the nose pointed along `direction` while not burning (used to pre-orient before a burn).
func hold_heading(direction: Vector2) -> void:
	unpark()
	_held_heading = direction.normalized()


## The heading being held (zero when none).
func get_held_heading() -> Vector2:
	return _held_heading


func release_heading() -> void:
	_held_heading = Vector2.ZERO


func _finish_burn() -> void:
	_burning = false
	_burn_remaining = Vector2.ZERO
	burn_completed.emit(_burn_achieved)


func _turn_toward(direction: Vector2, delta: float) -> void:
	if direction == Vector2.ZERO:
		_set_turn_rate(0.0, delta)
		return
	var diff := get_nose().angle_to(direction)
	# Fastest rate from which the ship can still stop at the target heading.
	var stop_rate := sqrt(2.0 * get_turn_acceleration() * TURN_PROFILE * absf(diff))
	var rate := minf(minf(max_turn_rate, stop_rate), absf(diff) / delta)
	_set_turn_rate(signf(diff) * rate, delta)


## Fires the attitude thrusters toward turn rate `rate`, limited by their torque and the fuel. The torque turns the
## ship in local space (`spin`), not the map body.
func _set_turn_rate(rate: float, delta: float) -> void:
	var max_torque := get_turn_torque()
	if max_torque <= 0.0:
		return
	var current_inertia := get_turn_inertia()
	var torque := clampf((rate - spin) * current_inertia / delta, -max_torque, max_torque)
	if absf(torque) < 1e-6:
		return
	# The torque is a thrust of torque / arm at the thrusters' exhaust velocity.
	var force := _consume_fuel(absf(torque) / thruster_arm, thrusters.exhaust_velocity, delta)
	torque = signf(torque) * force * thruster_arm
	_current_torque = torque
	spin += torque / current_inertia * delta


## Draws fuel for `force` at `exhaust_velocity` for one tick; returns the force actually available.
func _consume_fuel(force: float, exhaust_velocity: float, delta: float) -> float:
	if force <= 0.0 or fuel <= 0.0:
		return 0.0
	var needed := force / exhaust_velocity * delta
	if needed <= fuel:
		fuel -= needed
		return force
	# Partial last tick, then the engine flames out.
	force = fuel * exhaust_velocity / delta
	fuel = 0.0
	fuel_depleted.emit()
	if _burning:
		_finish_burn()
	return force


## Engine emissions for combat sensors: every online engine idles at its active signature and rises toward its
## maximum signature with the thrust it is giving.
func get_sensor_signature() -> float:
	var signature := 0.0
	var firing: Array = get_drive_engines(_current_drive) if _current_thrust > 0.0 else []
	var output := _current_thrust / maxf(get_drive_thrust(_current_drive), 1e-6)
	for engine: EngineDefinition in [main_engine if main_engine_online else null, thrusters if thrusters_online else null]:
		if engine == null:
			continue
		signature += engine.active_sensor_signature
		if engine in firing:
			signature += (engine.max_sensor_signature - engine.active_sensor_signature) * clampf(output, 0.0, 1.0)
	if _current_torque != 0.0 and thrusters and thrusters_online and not (thrusters in firing):
		signature += (thrusters.max_sensor_signature - thrusters.active_sensor_signature) \
			* clampf(absf(_current_torque) / maxf(get_turn_torque(), 1e-6), 0.0, 1.0)
	return signature

#endregion


#region Parking orbit

func is_parked() -> bool:
	return _park_body >= 0


## Body index of the parking orbit, or -1.
func get_parked_body() -> int:
	return _park_body


## Freezes the ship into a circular orbit around `body` at its current distance and direction of travel.
## Returns false if the ship is not in that body's sphere of influence.
func park(body: int = -1) -> bool:
	if not orbital_system or not orbital_system.IsReady:
		return false
	if body < 0:
		body = orbital_system.FindDominantBody(global_position)
	if body < 0 or _burning:
		return false
	var now: float = orbital_system.SimTime
	var rel: Vector2 = global_position - orbital_system.GetBodyPosition(body, now)
	var rel_vel: Vector2 = linear_velocity - orbital_system.GetBodyVelocity(body, now)
	if rel.length() >= orbital_system.GetBodySphereOfInfluence(body):
		return false
	var spin := 1.0 if rel.cross(rel_vel) >= 0.0 else -1.0
	_park_body = body
	_park_radius = rel.length()
	_park_rate = spin * sqrt(orbital_system.GetBodyMu(body) / pow(_park_radius, 3.0))
	_park_angle0 = rel.angle()
	_park_t0 = now
	_held_heading = Vector2.ZERO
	spin = 0.0
	# A frozen kinematic body ignores gravity and forces; it is moved along the circle in _update_parked().
	freeze_mode = RigidBody2D.FREEZE_MODE_KINEMATIC
	freeze = true
	parked.emit(body)
	return true


## Leaves the parking orbit with the exact circular velocity, back under full physics.
func unpark() -> void:
	if not is_parked():
		return
	# Leave from the exact state at the time the next physics step integrates from (OrbitalSystem.StateTime),
	# so the free flight continues the circle seamlessly whenever in the tick this is called.
	var now: float = orbital_system.SimTime
	var exit_position := get_state_position()
	var exit_velocity := get_state_velocity()
	_park_body = -1
	freeze = false
	global_position = exit_position
	linear_velocity = exit_velocity
	spin = 0.0
	_next_park_check = now + park_check_interval
	unparked.emit()


## Hull radius to hand to the orbital solvers ("ship_radius"): gravity wells act on the ship, and planets hit it, as
## soon as the hull overlaps them rather than when its centre crosses, and the predictions must do the same.
func get_hull_radius() -> float:
	var radius := 0.0
	for child in get_children():
		var collision := child as CollisionShape2D
		if collision == null or collision.disabled or collision.shape == null:
			continue
		var circle := collision.shape as CircleShape2D
		if circle != null:
			radius = maxf(radius, collision.position.length() + circle.radius)
		else:
			var rect := collision.shape.get_rect()
			radius = maxf(radius, collision.position.length() + maxf(rect.position.length(), rect.end.length()))
	return radius


## Position and velocity to hand to the orbital solvers: they belong to OrbitalSystem.StateTime.
## For a parked ship they are computed exactly at that time, whatever point of the physics tick this is called at
## (the node position is only updated during the ship's own physics tick, so it can lag one tick behind).
func get_state_position() -> Vector2:
	if not is_parked():
		return global_position
	var t: float = orbital_system.StateTime
	return orbital_system.GetBodyPosition(_park_body, t) + Vector2.from_angle(_parked_angle(t)) * _park_radius


func get_state_velocity() -> Vector2:
	if not is_parked():
		return linear_velocity
	var t: float = orbital_system.StateTime
	return orbital_system.GetBodyVelocity(_park_body, t) + _parked_relative_velocity(t)


func _parked_angle(time: float) -> float:
	return _park_angle0 + _park_rate * (time - _park_t0)


func _parked_relative_velocity(time: float) -> Vector2:
	var radial := Vector2.from_angle(_parked_angle(time))
	return Vector2(-radial.y, radial.x) * _park_rate * _park_radius


func _update_parked() -> void:
	var now: float = orbital_system.SimTime
	global_position = orbital_system.GetBodyPosition(_park_body, now) + Vector2.from_angle(_parked_angle(now)) * _park_radius
	queue_redraw()


## Something needs the ship under power: manual input, a burn, a held heading, or a blocking child
## (a node with `blocks_parking()`, e.g. pending maneuvers or an active autopilot).
func _wants_control() -> bool:
	if _burning or throttle > 0.0 or steer != 0.0 or manual_translation != Vector2.ZERO or _held_heading != Vector2.ZERO:
		return true
	for child in get_children():
		if child.has_method(&"blocks_parking") and child.blocks_parking():
			return true
	return false


func _try_auto_park() -> void:
	if _wants_control():
		return
	var body: int = orbital_system.FindDominantBody(global_position)
	if body < 0:
		return
	var info: Dictionary = orbital_system.GetOrbitInfo(global_position, linear_velocity, body)
	if info.is_empty() or not info.bound or info.eccentricity > park_eccentricity:
		return
	var limit: float = minf(orbital_system.GetBodySphereOfInfluence(body), orbital_system.GetBodyGravityRange(body))
	if info.periapsis < orbital_system.GetBodyRadius(body) * 1.02 or info.apoapsis > limit * 0.95:
		return
	park(body)

#endregion


func _on_body_entered(body: Node) -> void:
	crashed.emit(body)


func _draw() -> void:
	if not SpaceScale.local_view:
		_draw_map_marker()
		return
	_draw_hull()


## On the orbital map a ship is a dot: its facing only exists in local space.
func _draw_map_marker() -> void:
	var pixel := 1.0 / get_canvas_transform().get_scale().x
	draw_circle(Vector2.ZERO, 3.0 * pixel, hull_color)


## The hull at its local-space facing, with engine plumes. Sizes are world px, kept visible when zoomed out.
func _draw_hull() -> void:
	var s := hull_size * SpaceScale.draw_scale(self)
	draw_set_transform(Vector2.ZERO, facing)
	draw_colored_polygon(PackedVector2Array([Vector2(s, 0), Vector2(-s * 0.7, s * 0.6), Vector2(-s * 0.4, 0), Vector2(-s * 0.7, -s * 0.6)]), hull_color)
	if _current_thrust > 0.0:
		var local := _current_direction.rotated(-facing)
		var total := get_drive_thrust(_current_drive)
		for engine in get_drive_engines(_current_drive):
			var strength := _current_thrust / total
			if engine == main_engine and local.x > 0.99:
				_draw_plume(Vector2(-s * 0.45, 0.0), Vector2.LEFT, s, strength, engine)
			else:
				# Thruster puff on the side opposite the push.
				_draw_plume(-local * s * 0.5, -local, s * 0.5, strength, engine)
	if _current_translation != Vector2.ZERO and thrusters:
		# Thruster puff on the side opposite the push.
		var push := _current_translation.rotated(-facing).normalized()
		_draw_plume(-push * s * 0.5, -push, s * 0.5, _current_translation.length() / maxf(get_drive_thrust(Drive.THRUSTERS), 1e-6), thrusters)
	if _current_torque != 0.0 and thrusters:
		# Attitude puffs at the nose and tail, on opposite sides.
		var side := Vector2.DOWN if _current_torque > 0.0 else Vector2.UP
		var strength := absf(_current_torque) / maxf(get_turn_torque(), 1e-6)
		_draw_plume(Vector2(s * 0.6, 0.0) - side * s * 0.15, -side, s * 0.35, strength, thrusters)
		_draw_plume(Vector2(-s * 0.5, 0.0) + side * s * 0.4, side, s * 0.35, strength, thrusters)
	draw_set_transform(Vector2.ZERO)


func _draw_plume(at: Vector2, direction: Vector2, size: float, strength: float, engine: EngineDefinition) -> void:
	var length := size * (0.6 + 1.2 * clampf(strength, 0.0, 1.0)) * engine.flame_size
	var side := Vector2(-direction.y, direction.x) * size * 0.3 * sqrt(engine.flame_size)
	draw_colored_polygon(PackedVector2Array([at + side, at + direction * length, at - side]), engine.flame_color)
