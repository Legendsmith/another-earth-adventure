class_name Spaceship
extends RigidBody2D
## A ship flying under Godot's own 2D physics. Gravity comes from the point-gravity Area2D wells that
## every CelestialBody creates, so this script only handles the engine: thrust, fuel and attitude.
##
## Fuel use follows the rocket equation: thrust F consumes F / exhaust_velocity mass per second,
## so total delta-v = exhaust_velocity * ln(wet mass / dry mass).

signal burn_started(delta_v: Vector2)
signal burn_completed(achieved: Vector2)
signal fuel_depleted
signal crashed(body: Node)
signal parked(body: int)
signal unparked

@export_category("Engine")
@export var dry_mass: float = 10.0
@export var fuel_capacity: float = 5.0
@export var fuel: float = 5.0
## Maximum engine force (mass * px/s^2).
@export var max_thrust: float = 60.0
## Effective exhaust velocity in px/s (Isp * g0 in real units).
@export var exhaust_velocity: float = 220.0
## Attitude control turn rate in radians per second.
@export_range(0.1, 10.0, 0.01, "radians_as_degrees") var turn_rate: float = PI
## A burn only fires while the nose is within this angle of the burn direction.
@export_range(0.0, 45.0, 0.1, "radians_as_degrees") var burn_alignment: float = deg_to_rad(5.0)
## Remaining delta-v (px/s) at which an automatic burn is considered complete.
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
@export var flame_color: Color = Color(1.0, 0.6, 0.2)
@export var hull_size: float = 8.0

## Manual throttle (0..1) along the nose. Ignored during automatic burns.
var throttle: float = 0.0
## Manual turn input (-1..1). Overrides any held heading.
var steer: float = 0.0

var orbital_system: Node

var _burning := false
var _burn_remaining := Vector2.ZERO
var _burn_achieved := Vector2.ZERO
var _held_heading := Vector2.ZERO
var _current_thrust := 0.0

# Parking orbit: circle of radius _park_radius around _park_body, angle = _park_angle0 + _park_rate * (t - _park_t0).
var _park_body := -1
var _park_radius := 0.0
var _park_rate := 0.0
var _park_angle0 := 0.0
var _park_t0 := 0.0
var _next_park_check := 0.0


func _ready() -> void:
	gravity_scale = 1.0
	linear_damp_mode = RigidBody2D.DAMP_MODE_REPLACE
	linear_damp = 0.0
	angular_damp_mode = RigidBody2D.DAMP_MODE_REPLACE
	angular_damp = 0.0
	can_sleep = false
	contact_monitor = true
	max_contacts_reported = 4
	body_entered.connect(_on_body_entered)
	mass = dry_mass + fuel
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
	mass = dry_mass + fuel
	var nose := Vector2.RIGHT.rotated(global_rotation)
	var force := 0.0

	if _burning:
		var direction := _burn_remaining.normalized()
		_turn_toward(direction, delta)
		var along := _burn_remaining.dot(nose)
		if _burn_remaining.length() <= burn_tolerance:
			_finish_burn()
		elif absf(nose.angle_to(direction)) <= burn_alignment:
			# Never overshoot: the last tick only applies what is left.
			force = minf(max_thrust, along * mass / delta)
	else:
		if steer != 0.0:
			angular_velocity = steer * turn_rate
		elif _held_heading != Vector2.ZERO:
			_turn_toward(_held_heading, delta)
		else:
			angular_velocity = 0.0
		force = max_thrust * clampf(throttle, 0.0, 1.0)

	force = _consume_fuel(force, delta)
	_current_thrust = force
	if force > 0.0:
		apply_central_force(nose * force)
		if _burning:
			var achieved := nose * (force / mass * delta)
			_burn_remaining -= achieved
			_burn_achieved += achieved
	queue_redraw()


#region Engine

## Delta-v left in the tanks (rocket equation).
func get_delta_v_remaining() -> float:
	return exhaust_velocity * log((dry_mass + fuel) / dry_mass)


## Seconds of full thrust needed for a burn of `delta_v` px/s with the current mass.
func get_burn_duration(delta_v: float) -> float:
	var m0 := dry_mass + fuel
	var m1 := m0 / exp(delta_v / exhaust_velocity)
	var mass_flow := max_thrust / exhaust_velocity
	return (m0 - m1) / mass_flow


## Seconds needed to turn the nose to `direction`.
func get_turn_time(direction: Vector2) -> float:
	return absf(Vector2.RIGHT.rotated(global_rotation).angle_to(direction)) / turn_rate


## Starts an automatic burn: turns to the remaining delta-v vector and thrusts until it is used up.
func execute_burn(delta_v: Vector2) -> void:
	unpark()
	_burning = true
	_burn_remaining = delta_v
	_burn_achieved = Vector2.ZERO
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


func release_heading() -> void:
	_held_heading = Vector2.ZERO


func _finish_burn() -> void:
	_burning = false
	_burn_remaining = Vector2.ZERO
	burn_completed.emit(_burn_achieved)


func _turn_toward(direction: Vector2, delta: float) -> void:
	if direction == Vector2.ZERO:
		angular_velocity = 0.0
		return
	var diff := Vector2.RIGHT.rotated(global_rotation).angle_to(direction)
	angular_velocity = clampf(diff / delta, -turn_rate, turn_rate)


func _consume_fuel(force: float, delta: float) -> float:
	if force <= 0.0:
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
	angular_velocity = 0.0
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
	angular_velocity = 0.0
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
	if _burning or throttle > 0.0 or steer != 0.0 or _held_heading != Vector2.ZERO:
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
	# Keep the ship visible when the camera is zoomed far out.
	var s := hull_size * maxf(1.0, 1.0 / get_canvas_transform().get_scale().x)
	draw_colored_polygon(PackedVector2Array([Vector2(s, 0), Vector2(-s * 0.7, s * 0.6), Vector2(-s * 0.4, 0), Vector2(-s * 0.7, -s * 0.6)]), hull_color)
	if _current_thrust > 0.0:
		var length := s * (0.6 + 1.2 * _current_thrust / max_thrust)
		draw_colored_polygon(PackedVector2Array([Vector2(-s * 0.45, s * 0.3), Vector2(-s * 0.45 - length, 0), Vector2(-s * 0.45, -s * 0.3)]), flame_color)
