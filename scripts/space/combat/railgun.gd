class_name Railgun
extends WeaponMount
## Hypervelocity railgun firing RailCanister rounds. Each shot needs `shot_energy` from the hull's power supply
## (reactors and power-generating drives), so only hulls with serious power can run one. Every shot is a huge
## electromagnetic discharge that sensors pick up from far away, even though the round itself is nearly invisible.

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

var charge := 0.0
var _rng := RandomNumberGenerator.new()


func _init() -> void:
	weapon_name = "Railgun"
	max_range = 4000.0


func _ready() -> void:
	super._ready()
	_rng.randomize()


func _physics_process(delta: float) -> void:
	if is_operational() and charge < shot_energy:
		charge = minf(charge + hull.get_power_supply() * delta, shot_energy)


func is_ready() -> bool:
	return charge >= shot_energy


func get_readiness() -> float:
	return charge / shot_energy if shot_energy > 0.0 else 1.0


## Time (s) for a round fired now to reach a target at `relative_position` moving at `relative_velocity` (both relative
## to the gun), or -1 if the round cannot catch it.
func intercept_time(relative_position: Vector2, relative_velocity: Vector2) -> float:
	var a := relative_velocity.length_squared() - muzzle_velocity * muzzle_velocity
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


func fire_at(target: CombatHull) -> bool:
	if not can_engage(target):
		return false
	var origin := hull.get_world_position()
	var own_velocity := hull.get_world_velocity()
	var relative := target.get_world_position() - origin
	var relative_velocity := target.get_world_velocity() - own_velocity
	var flight_time := intercept_time(relative, relative_velocity)
	if flight_time <= 0.0 or flight_time * muzzle_velocity > max_range * 1.5:
		return false
	var aim := (relative + relative_velocity * flight_time).normalized().rotated(_rng.randfn(0.0, aim_error))
	var canister := RailCanister.new()
	canister.faction = hull.faction
	canister.launcher = hull
	canister.target = target
	canister.burst_time = maxf(flight_time - burst_distance / muzzle_velocity, 0.05)
	canister.fragment_count = fragment_count
	canister.fragment_damage = fragment_damage
	canister.spread_speed = spread_speed
	canister.lifetime = flight_time + 5.0
	Munition.launch(canister, hull, origin + aim * (hull.hit_radius + 2.0), own_velocity + aim * muzzle_velocity)
	charge = 0.0
	var manager := SpaceCombatManager.find(get_tree())
	if manager:
		manager.report_discharge(hull, origin, discharge_signature, target, flight_time)
	return true
