class_name TorpedoLauncher
extends WeaponMount
## Launches Torpedo munitions from a magazine. See Torpedo for the flight profile.

@export var magazine: int = 4
@export var reload_time: float = 20.0
## Speed the launcher kicks the torpedo off at, toward the target (px/s).
@export var launch_speed: float = 15.0

@export_category("Torpedo")
@export var thrust_accel: float = 30.0
@export var burn_time: float = 40.0
@export var cruise_speed: float = 70.0
@export var engagement_range: float = 1200.0
@export var damage: int = 16
@export var spread: int = 3

var ammo: int
var _reload := 0.0


func _init() -> void:
	weapon_name = "Torpedoes"
	max_range = 6000.0


func _ready() -> void:
	super._ready()
	ammo = magazine


func _physics_process(delta: float) -> void:
	if _reload > 0.0:
		_reload = maxf(_reload - delta, 0.0)


func is_ready() -> bool:
	return ammo > 0 and _reload <= 0.0


func get_readiness() -> float:
	if ammo <= 0:
		return 0.0
	return 1.0 - _reload / reload_time if reload_time > 0.0 else 1.0


func fire_at(target: CombatHull) -> bool:
	if not can_engage(target):
		return false
	var origin := hull.get_world_position()
	var direction := (target.get_world_position() - origin).normalized()
	var torpedo := Torpedo.new()
	torpedo.faction = hull.faction
	torpedo.launcher = hull
	torpedo.target = target
	torpedo.thrust_accel = thrust_accel
	torpedo.burn_time = burn_time
	torpedo.cruise_speed = cruise_speed
	torpedo.engagement_range = engagement_range
	torpedo.damage = damage
	torpedo.spread = spread
	Munition.launch(torpedo, hull, origin + direction * (hull.hit_radius + 4.0),
		hull.get_world_velocity() + direction * launch_speed)
	ammo -= 1
	_reload = reload_time
	return true


func get_status() -> String:
	return "%s [%d/%d]" % [super.get_status(), ammo, magazine]
