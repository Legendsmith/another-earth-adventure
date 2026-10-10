class_name Torpedo
extends Munition
## Long range guided cruise munition.
##
## COLD LAUNCH: it drifts clear of the launcher with its drive unlit for `cold_launch_time`, swinging its nose
## toward the intercept heading.
## BOOST: a short burn after launch puts the torpedo on an intercept course at `cruise_speed`.
## COAST: it runs cold toward the target with only cold-gas corrections, nearly invisible to sensors.
## TERMINAL: inside `engagement_range` it lights its drive and burns continuously until it hits or runs dry,
## steering with zero-effort-miss proportional navigation. Its acceleration and long burn time outmatch any ship's,
## but its drive only pushes along its nose and the nose turns slowly (`turn_rate`), so a ship that jinks late
## inside its turning circle can make it overshoot.

enum Phase { COLD_LAUNCH, BOOST, COAST, TERMINAL, SPENT }

const PHASE_NAMES := ["cold launch", "boosting", "coasting cold", "terminal burn", "spent"]
## Proportional navigation constant.
const NAVIGATION_GAIN := 3.0

## Drive acceleration (px/s^2).
var thrust_accel: float = 30.0
## How fast the nose (and so the drive) can swing (rad/s).
var turn_rate: float = 0.25
## Seconds after launch spent drifting with the drive unlit while the nose turns to the intercept heading.
var cold_launch_time: float = 1.5
## Seconds of full drive burn in the tanks (boost and terminal burn share it).
var burn_time: float = 40.0
## Closing speed the boost phase builds before going cold (px/s).
var cruise_speed: float = 70.0
## Longest boost before going cold, whatever the closing speed.
var max_boost_time: float = 4.0
## Distance at which the terminal burn starts (px).
var engagement_range: float = 1200.0
## Cold-gas correction acceleration while coasting (px/s^2) and its delta-v budget (px/s).
var correction_accel: float = 2.0
var correction_delta_v: float = 40.0
## Warhead damage points: an explosive, wide and shallow crater on the armor grid.
var damage: int = 16
## Detonation distance beyond the target's hit radius (px).
var fuse_radius: float = 4.0
var signature_cold: float = 0.05
var signature_boost: float = 8.0
var signature_burning: float = 60.0

var phase: Phase = Phase.COLD_LAUNCH
## Direction the nose points (global). The drive only thrusts along it. Set by the launcher before launch.
var heading := Vector2.ZERO
var _boost_elapsed := 0.0
var _thrust_fraction := 0.0
var _thrust_direction := Vector2.RIGHT


func _ready() -> void:
	super._ready()
	munition_name = "Torpedo"
	if heading == Vector2.ZERO:
		heading = linear_velocity.normalized() if linear_velocity.length_squared() > 1e-12 else Vector2.RIGHT


func _physics_process(delta: float) -> void:
	super._physics_process(delta)
	if is_queued_for_deletion():
		return
	_thrust_fraction = 0.0
	if not has_valid_target():
		if phase != Phase.SPENT:
			phase = Phase.SPENT
			lifetime = minf(lifetime, _age + 30.0)
		return
	var relative := target.get_world_position() - get_world_position()
	var relative_velocity := target.get_world_velocity() - get_world_velocity()
	if closest_approach(relative, relative_velocity, delta) <= target.hit_radius + fuse_radius:
		_detonate()
		return
	var accel := Vector2.ZERO
	match phase:
		Phase.COLD_LAUNCH:
			_turn_toward(guidance(thrust_accel, true), delta)
			if _age >= cold_launch_time:
				phase = Phase.BOOST
		Phase.BOOST:
			_boost_elapsed += delta
			accel = _drive(guidance(thrust_accel, true), delta)
			var closing := -relative.dot(relative_velocity) / maxf(relative.length(), 1e-6)
			if closing >= cruise_speed or _boost_elapsed >= max_boost_time:
				phase = Phase.COAST
		Phase.COAST:
			# Keep the nose on the line of sight, ready for the terminal burn. The cold-gas trim is too weak to
			# need the nose and pushes sideways directly.
			_turn_toward(relative, delta)
			if relative.length() <= engagement_range:
				phase = Phase.TERMINAL
			elif correction_delta_v > 0.0:
				accel = guidance(correction_accel, false)
				correction_delta_v -= accel.length() * delta
		Phase.TERMINAL:
			accel = _drive(guidance(thrust_accel, true), delta)
	if phase == Phase.BOOST or phase == Phase.TERMINAL:
		burn_time -= delta * accel.length() / thrust_accel
		if burn_time <= 0.0:
			phase = Phase.SPENT
			lifetime = minf(lifetime, _age + 60.0)
	if accel != Vector2.ZERO:
		apply_world_force(accel * mass)
		_thrust_fraction = accel.length() / thrust_accel
		_thrust_direction = accel.normalized()


## Swings the nose toward `direction` at no more than `turn_rate`.
func _turn_toward(direction: Vector2, delta: float) -> void:
	if direction == Vector2.ZERO:
		return
	var max_step := turn_rate * delta
	heading = heading.rotated(clampf(heading.angle_to(direction), -max_step, max_step))


## Turns toward the commanded acceleration and returns what the drive actually gives: the command's component
## along the nose, never backwards.
func _drive(command: Vector2, delta: float) -> Vector2:
	_turn_toward(command, delta)
	return heading * maxf(command.dot(heading), 0.0)


## Acceleration command toward the target, at most `max_accel`. Steers out the predicted miss distance
## (zero-effort miss over the time to go); with `keep_closing` the rest of the thrust pushes along the line of sight.
func guidance(max_accel: float, keep_closing: bool) -> Vector2:
	var relative := target.get_world_position() - get_world_position()
	var relative_velocity := target.get_world_velocity() - get_world_velocity()
	var distance := relative.length()
	if distance < 1e-6:
		return Vector2.ZERO
	var line_of_sight := relative / distance
	var closing := -relative.dot(relative_velocity) / distance
	var accel: Vector2
	if closing <= 1.0:
		# Not closing: cancel the sideways drift and accelerate at the target.
		var lateral := relative_velocity - line_of_sight * relative_velocity.dot(line_of_sight)
		accel = (lateral + line_of_sight * max_accel).limit_length(max_accel)
		return accel if keep_closing else lateral.limit_length(max_accel)
	var time_to_go := distance / closing
	var zero_effort_miss := relative + relative_velocity * time_to_go
	accel = (zero_effort_miss * (NAVIGATION_GAIN / (time_to_go * time_to_go))).limit_length(max_accel)
	if keep_closing:
		accel += line_of_sight * sqrt(maxf(max_accel * max_accel - accel.length_squared(), 0.0))
	return accel


func get_signature() -> float:
	match phase:
		Phase.BOOST:
			return signature_boost if _thrust_fraction > 0.0 else signature_cold
		Phase.TERMINAL:
			return signature_burning if _thrust_fraction > 0.0 else signature_cold
	return signature_cold


func get_warhead_damage() -> float:
	return damage


func _detonate() -> void:
	if has_valid_target():
		target.take_hit(damage, ArmorGrid.DamageProfile.EXPLOSIVE)
	spawn_explosion(14.0)
	queue_free()


func _draw() -> void:
	var s := 4.0 * get_zoom_scale()
	var side := Vector2(-heading.y, heading.x)
	var color := Color(1.0, 0.45, 0.35) if CombatHull.factions_hostile(faction, Constants.PLAYER_GROUP) else Color(0.5, 0.9, 1.0)
	draw_colored_polygon(PackedVector2Array([heading * s, -heading * s * 0.6 + side * s * 0.35,
		-heading * s * 0.6 - side * s * 0.35]), color)
	if _thrust_fraction > 0.0:
		var back := -_thrust_direction
		var flame_side := Vector2(-back.y, back.x) * s * 0.25
		draw_colored_polygon(PackedVector2Array([back * s * 0.5 + flame_side,
			back * s * (1.2 + 2.0 * _thrust_fraction), back * s * 0.5 - flame_side]), Color(1.0, 0.85, 0.5))
