class_name RailCanister
extends Munition
## Hypervelocity railgun canister round. It flies unpowered and almost without signature, then bursts shortly before
## its predicted closest approach, throwing a fan of fragments across the target's path: aiming errors and small dodges
## still leave some fragments on target. Each fragment that passes within the target's hit radius is a kinetic hit.

## Seconds after launch at which the canister bursts.
var burst_time: float = 1.0
var fragment_count: int = 24
## Damage of each fragment (kinetic: all of it into one armor column).
var fragment_damage: int = 2
## Sideways speed range of the fragments (px/s): with the burst distance it sets the width of the pattern.
var spread_speed: float = 300.0
## Seconds fragments stay dangerous after the burst.
var fragment_lifetime: float = 0.6
var signature: float = 0.02

var _burst := false
var _burst_age := 0.0
var _positions := PackedVector2Array()
var _velocities := PackedVector2Array()
var _alive: Array[bool] = []
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	super._ready()
	munition_name = "Railgun round"
	_rng.randomize()


func _physics_process(delta: float) -> void:
	super._physics_process(delta)
	if is_queued_for_deletion():
		return
	if not _burst:
		if _age >= burst_time:
			_do_burst()
		return
	_burst_age += delta
	if _burst_age >= fragment_lifetime:
		queue_free()
		return
	var hulls := get_tree().get_nodes_in_group(CombatHull.GROUP)
	for i in _positions.size():
		if not _alive[i]:
			continue
		for node in hulls:
			var hull := node as CombatHull
			if hull == null or hull == launcher or hull.is_destroyed or not hull.is_hostile_to(faction):
				continue
			var relative := hull.get_world_position() - _positions[i]
			var relative_velocity := hull.get_world_velocity() - _velocities[i]
			if closest_approach(relative, relative_velocity, delta) <= hull.hit_radius:
				hull.take_hit(fragment_damage, 0)
				_alive[i] = false
				break
		_positions[i] += _velocities[i] * delta


func _do_burst() -> void:
	_burst = true
	var velocity := linear_velocity
	var forward := velocity.normalized() if velocity.length_squared() > 1e-6 else Vector2.RIGHT
	var side := Vector2(-forward.y, forward.x)
	for i in fragment_count:
		_positions.append(global_position)
		_velocities.append(velocity + side * _rng.randf_range(-spread_speed, spread_speed)
			+ forward * _rng.randf_range(-0.1, 0.1) * spread_speed)
		_alive.append(true)
	# The fragments are moved by hand from here: stop the canister body.
	freeze_mode = RigidBody2D.FREEZE_MODE_KINEMATIC
	set_deferred(&"freeze", true)
	collision_mask = 0
	spawn_explosion(4.0, Color(0.8, 0.9, 1.0))


func get_signature() -> float:
	return signature


func get_world_position() -> Vector2:
	if _burst and not _positions.is_empty():
		return _positions[0]
	return global_position


func _draw() -> void:
	var s := get_zoom_scale()
	var color := Color(1.0, 0.8, 0.5) if CombatHull.factions_hostile(faction, Constants.PLAYER_GROUP) else Color(0.7, 0.95, 1.0)
	if not _burst:
		draw_circle(Vector2.ZERO, 1.5 * s, color)
		return
	# Fragments are kept in world coordinates.
	draw_set_transform_matrix(global_transform.affine_inverse())
	for i in _positions.size():
		if _alive[i]:
			draw_circle(_positions[i], 1.0 * s, color)
