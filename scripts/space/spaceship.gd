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


func _on_body_entered(body: Node) -> void:
	crashed.emit(body)


func _draw() -> void:
	# Keep the ship visible when the camera is zoomed far out.
	var s := hull_size * maxf(1.0, 1.0 / get_canvas_transform().get_scale().x)
	draw_colored_polygon(PackedVector2Array([Vector2(s, 0), Vector2(-s * 0.7, s * 0.6), Vector2(-s * 0.4, 0), Vector2(-s * 0.7, -s * 0.6)]), hull_color)
	if _current_thrust > 0.0:
		var length := s * (0.6 + 1.2 * _current_thrust / max_thrust)
		draw_colored_polygon(PackedVector2Array([Vector2(-s * 0.45, s * 0.3), Vector2(-s * 0.45 - length, 0), Vector2(-s * 0.45, -s * 0.3)]), flame_color)
