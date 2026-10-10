class_name Railgun
extends WeaponMount
## Hypervelocity railgun firing RailCanister rounds. Each shot needs `shot_energy` from the hull's power supply
## (reactors and power-generating drives), so only hulls with serious power can run one. Every shot is a huge
## electromagnetic discharge that sensors pick up from far away, even though the round itself is nearly invisible.
##
## Long shots fly for minutes, so the firing solution flies the round and the target (assumed to coast) under the
## gravity of the body the gun is orbiting. The barrel is fixed in a firing arc and slews at a limited traverse rate:
## it cannot fire outside the arc, and cannot follow a target whose bearing sweeps faster than it can turn, which
## keeps close, fast movers safe from it.

## What the centre of the firing arc points along.
enum ArcFacing {
	## The host's nose.
	HULL_FORWARD,
	## Straight up, away from the body the gun is orbiting (an orbital gun platform shooting at higher orbits).
	AWAY_FROM_BODY,
}

## Newton iterations of the firing solution.
const SOLVE_ITERATIONS := 12
## Integration step of the firing solution (s). Rounds and targets fall under the same gravity, so a coarse step is
## close enough to the physics engine's flight.
const SOLVE_STEP := 1.0
const SOLVE_MAX_STEPS := 160
## Real milliseconds between firing solutions, whatever the time warp: solving is the costly part of a railgun.
const SOLVE_MIN_REAL_INTERVAL_MS := 250
## The firing solution must bring the round within this distance (px) of the target.
const SOLVE_TOLERANCE := 1.0

@export var muzzle_velocity: float = 900.0
## Energy per shot; charging takes shot_energy / power supply seconds.
@export var shot_energy: float = 600.0
## The canister bursts this far (px) short of the predicted closest approach.
@export var burst_distance: float = 60.0
@export var fragment_count: int = 24
@export var fragment_damage: int = 2
@export var spread_speed: float = 300.0
## Standard deviation of the aiming error (radians).
@export var aim_error: float = 0.002
## Signature of the discharge flash.
@export var discharge_signature: float = 3000.0

@export_category("Mount")
@export var arc_facing: ArcFacing = ArcFacing.HULL_FORWARD
## Half-width of the firing arc around its centre (180 degrees = all round).
@export_range(0.0, 180.0, 0.1, "radians_as_degrees") var arc_half_angle: float = PI
## How fast the barrel turns (rad/s). 0 = instantly.
@export_range(0.0, 180.0, 0.1, "radians_as_degrees") var traverse_rate: float = 0.0
## The barrel must be within this angle of the firing solution to fire.
@export_range(0.0, 10.0, 0.01, "radians_as_degrees") var aim_tolerance: float = deg_to_rad(0.25)
## Simulation seconds between firing solutions for the tracked target.
@export var solve_interval: float = 0.5
## Longest flight (s) the gun will plan a shot for.
@export var max_flight_time: float = 600.0

@export_category("Display")
## Draw the firing arc in the world (only for arcs narrower than all round).
@export var show_arc: bool = true
@export var arc_color: Color = Color(1.0, 0.35, 0.3, 0.12)
## Length of the drawn arc in screen pixels.
@export var arc_draw_length: float = 160.0

var charge := 0.0
## Barrel bearing relative to the arc centre (radians).
var barrel_angle := 0.0
var _rng := RandomNumberGenerator.new()
var _orbital_system: Node
var _track: CombatHull
## Last firing solution for _track: {direction, time, closing_speed}; empty when there is none.
var _solution: Dictionary = {}
var _solution_age := INF
var _next_solve_ms := 0


func _init() -> void:
	weapon_name = "Railgun"
	max_range = 4000.0


func _ready() -> void:
	super._ready()
	_rng.randomize()
	_orbital_system = get_tree().get_first_node_in_group(Constants.ORBITAL_SYSTEM_GROUP)


func _physics_process(delta: float) -> void:
	if is_operational() and charge < shot_energy:
		charge = minf(charge + hull.get_power_supply() * delta, shot_energy)
	_update_tracking(delta)
	if show_arc and arc_half_angle < PI:
		queue_redraw()


func is_ready() -> bool:
	return charge >= shot_energy


func get_readiness() -> float:
	return charge / shot_energy if shot_energy > 0.0 else 1.0


## Time (s) for a round fired now to reach a target at `relative_position` moving at `relative_velocity` (both relative
## to the gun), ignoring gravity, or -1 if the round cannot catch it.
func intercept_time(relative_position: Vector2, relative_velocity: Vector2) -> float:
	return linear_intercept_time(relative_position, relative_velocity, muzzle_velocity)


static func linear_intercept_time(relative_position: Vector2, relative_velocity: Vector2, speed: float) -> float:
	var a := relative_velocity.length_squared() - speed * speed
	var b := 2.0 * relative_position.dot(relative_velocity)
	var c := relative_position.length_squared()
	if absf(a) < 1e-6:
		return -c / b if b < 0.0 else -1.0
	var discriminant := b * b - 4.0 * a * c
	if discriminant < 0.0:
		return -1.0
	var root := sqrt(discriminant)
	var t1 := (-b - root) / (2.0 * a)
	var t2 := (-b + root) / (2.0 * a)
	var t := minf(t1, t2) if minf(t1, t2) > 0.0 else maxf(t1, t2)
	return t if t > 0.0 else -1.0


#region Mount

## World direction of the centre of the firing arc.
func get_arc_center() -> Vector2:
	if arc_facing == ArcFacing.AWAY_FROM_BODY and _orbital_system and _orbital_system.IsReady:
		var origin := hull.get_world_position()
		var body: int = _orbital_system.FindDominantBody(SpaceScale.to_map(origin))
		if body >= 0:
			var up: Vector2 = origin - SpaceScale.to_world(_orbital_system.GetBodyPosition(body, _orbital_system.StateTime))
			if up.length_squared() > 1e-6:
				return up.normalized()
	var host: Node2D = hull.host if hull and hull.host else self
	if host is Spaceship:
		return (host as Spaceship).get_nose()
	return Vector2.RIGHT.rotated(host.global_rotation)


## World direction the barrel points along.
func get_barrel_direction() -> Vector2:
	return get_arc_center().rotated(barrel_angle)


## Is the world direction `direction` inside the firing arc?
func in_arc(direction: Vector2) -> bool:
	return absf(get_arc_center().angle_to(direction)) <= arc_half_angle + 1e-6


## Slews the barrel toward the firing solution of the tracked target, re-solving it every solve_interval.
func _update_tracking(delta: float) -> void:
	if _track != null and (not is_instance_valid(_track) or _track.is_destroyed or not is_operational()):
		_track = null
		_solution = {}
	if _track == null:
		return
	_solution_age += delta
	if _solution_age >= solve_interval and Time.get_ticks_msec() >= _next_solve_ms:
		_solve(_track)
	if _solution.is_empty():
		return
	var wanted := clampf(get_arc_center().angle_to(_solution.direction), -arc_half_angle, arc_half_angle)
	if traverse_rate <= 0.0:
		barrel_angle = wanted
	else:
		barrel_angle = move_toward(barrel_angle, wanted, traverse_rate * delta)


func _solve(target: CombatHull) -> void:
	_solution_age = 0.0
	_next_solve_ms = Time.get_ticks_msec() + SOLVE_MIN_REAL_INTERVAL_MS
	var mu := 0.0
	var center := Vector2.ZERO
	var origin := hull.get_world_position()
	if _orbital_system and _orbital_system.IsReady:
		var body: int = _orbital_system.FindDominantBody(SpaceScale.to_map(origin))
		if body >= 0:
			# The solution is worked in world px: scale the body's map gravity up (mu goes as length cubed).
			mu = _orbital_system.GetBodyMu(body) / pow(SpaceScale.MAP_SCALE, 3.0)
			center = SpaceScale.to_world(_orbital_system.GetBodyPosition(body, _orbital_system.StateTime))
	_solution = solve_intercept(origin, hull.get_world_velocity(), target.get_world_position(),
		target.get_world_velocity(), muzzle_velocity, mu, center, max_flight_time)

#endregion


func fire_at(target: CombatHull) -> bool:
	if not can_engage(target):
		return false
	if target != _track or (_solution_age >= solve_interval and Time.get_ticks_msec() >= _next_solve_ms):
		_track = target
		_solve(target)
	if _solution.is_empty():
		return false
	var direction: Vector2 = _solution.direction
	var flight_time: float = _solution.time
	if flight_time * muzzle_velocity > max_range * 1.5 or not in_arc(direction):
		return false
	if traverse_rate <= 0.0:
		barrel_angle = get_arc_center().angle_to(direction)
	elif absf(angle_difference(get_barrel_direction().angle(), direction.angle())) > aim_tolerance:
		return false # Still slewing onto the target.
	var aim := direction.rotated(_rng.randfn(0.0, aim_error))
	var origin := hull.get_world_position()
	var own_velocity := hull.get_world_velocity()
	var lead := burst_distance / maxf(_solution.closing_speed, 1.0)
	var canister := RailCanister.new()
	canister.faction = hull.faction
	canister.launcher = hull
	canister.target = target
	canister.burst_time = maxf(flight_time - lead, 0.05)
	canister.fragment_count = fragment_count
	canister.fragment_damage = fragment_damage
	canister.spread_speed = spread_speed
	canister.fragment_lifetime = maxf(canister.fragment_lifetime, lead + 1.0)
	canister.lifetime = flight_time + 5.0
	Munition.launch(canister, hull, origin + aim * (hull.hit_radius + 2.0), own_velocity + aim * muzzle_velocity)
	charge = 0.0
	var manager := SpaceCombatManager.find(get_tree())
	if manager:
		manager.report_discharge(hull, origin, discharge_signature, target, flight_time)
	return true


func get_status() -> String:
	var status := super.get_status()
	if is_operational() and _track != null and not _solution.is_empty() and not in_arc(_solution.direction):
		status += " (target outside arc)"
	return status


#region Firing solution

## Firing solution for a round leaving `origin` at `speed` on top of the gun's `own_velocity`, against a target at
## `target_position` coasting at `target_velocity`. Both fall toward `center` with gravitational parameter `mu`
## (0 = no gravity, straight lines). Returns {direction, time, closing_speed}, or {} when no shot within `max_time`
## reaches the target.
static func solve_intercept(origin: Vector2, own_velocity: Vector2, target_position: Vector2,
		target_velocity: Vector2, speed: float, mu: float, center: Vector2, max_time: float) -> Dictionary:
	var relative := target_position - origin
	var relative_velocity := target_velocity - own_velocity
	var time := linear_intercept_time(relative, relative_velocity, speed)
	if mu <= 0.0:
		if time <= 0.0 or time > max_time:
			return {}
		var aim := (relative + relative_velocity * time).normalized()
		return {"direction": aim, "time": time, "closing_speed": (aim * speed - relative_velocity).length()}
	# Without gravity the round could not catch the target; gravity may still bring them together, so start from the
	# time the round would take to cover today's distance.
	if time <= 0.0:
		time = relative.length() / speed
	var direction := (relative + relative_velocity * time).normalized()
	# Newton's method on (bearing, flight time): the round must be where the target is at the end of the flight.
	var bearing := direction.angle()
	var miss := INF
	var closing := Vector2.ZERO
	for i in SOLVE_ITERATIONS:
		var steps := clampi(ceili(time / SOLVE_STEP), 8, SOLVE_MAX_STEPS)
		var target_state := _coast(target_position, target_velocity, time, steps, mu, center)
		var round_state := _coast(origin, own_velocity + Vector2.from_angle(bearing) * speed, time, steps, mu, center)
		var error: Vector2 = round_state[0] - target_state[0]
		miss = error.length()
		closing = round_state[1] - target_state[1]
		if miss <= SOLVE_TOLERANCE:
			break
		# Columns of the Jacobian: d(error)/d(bearing) by finite difference, d(error)/d(time) = relative velocity.
		var epsilon := 1e-4
		var nudged := _coast(origin, own_velocity + Vector2.from_angle(bearing + epsilon) * speed, time, steps, mu, center)
		var d_bearing: Vector2 = (nudged[0] - round_state[0]) / epsilon
		var d_time := closing
		var determinant := d_bearing.cross(d_time)
		if absf(determinant) < 1e-9:
			return {}
		# Solve d_bearing * a + d_time * b = -error.
		var step_bearing := -error.cross(d_time) / determinant
		var step_time := -d_bearing.cross(error) / determinant
		bearing += clampf(step_bearing, -0.5, 0.5)
		time = maxf(time + clampf(step_time, -0.5 * time, 0.5 * time), 0.05)
		if time > max_time:
			return {}
	if miss > SOLVE_TOLERANCE * 10.0:
		return {}
	return {"direction": Vector2.from_angle(bearing), "time": time, "closing_speed": closing.length()}


## [position, velocity] after coasting `time` seconds from `start_position`, `start_velocity` under point gravity `mu` at `center`
## (velocity Verlet in `steps` steps).
static func _coast(start_position: Vector2, start_velocity: Vector2, time: float, steps: int, mu: float,
		center: Vector2) -> Array:
	var dt := time / steps
	var point := start_position
	var velocity := start_velocity
	var offset := point - center
	var acceleration := -offset * (mu / pow(maxf(offset.length_squared(), 1.0), 1.5))
	for i in steps:
		velocity += acceleration * (0.5 * dt)
		point += velocity * dt
		offset = point - center
		acceleration = -offset * (mu / pow(maxf(offset.length_squared(), 1.0), 1.5))
		velocity += acceleration * (0.5 * dt)
	return [point, velocity]

#endregion


func _draw() -> void:
	if not show_arc or arc_half_angle >= PI or hull == null or hull.is_destroyed:
		return
	var length := arc_draw_length / get_canvas_transform().get_scale().x
	# Draw in world orientation from the gun's position.
	draw_set_transform(Vector2.ZERO, -global_rotation)
	var center := get_arc_center().angle()
	var points := PackedVector2Array([Vector2.ZERO])
	var segments := 24
	for i in segments + 1:
		points.append(Vector2.from_angle(center - arc_half_angle + 2.0 * arc_half_angle * i / segments) * length)
	draw_colored_polygon(points, arc_color)
	var barrel_color := Color(arc_color, minf(arc_color.a * 5.0, 1.0))
	draw_line(Vector2.ZERO, get_barrel_direction() * length, barrel_color, -1.0)
