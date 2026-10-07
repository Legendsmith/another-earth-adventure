class_name WeaponMount
extends Node2D
## Base for weapons mounted on a CombatHull (the mount's parent).

@export var weapon_name: String = "Weapon"
@export var max_range: float = 3000.0
## Fired by the hull's CombatAI. Off for the player's weapons, which fire on command.
@export var auto_fire: bool = true
## Internal component (ShipComponent.name) that runs this weapon; the weapon stops when it is destroyed. Empty = none.
@export var component_name: String = ""

var hull: CombatHull


func _ready() -> void:
	hull = get_parent() as CombatHull
	if hull == null:
		push_warning("%s must be a child of a CombatHull" % name)


func is_operational() -> bool:
	if hull == null or hull.is_destroyed:
		return false
	return component_name.is_empty() or hull.is_component_operational(hull.find_component(component_name))


## Loaded / charged and able to fire now.
func is_ready() -> bool:
	return false


## 0..1 progress of the current reload or charge.
func get_readiness() -> float:
	return 1.0 if is_ready() else 0.0


func in_range(target: CombatHull) -> bool:
	return target.get_world_position().distance_to(hull.get_world_position()) <= max_range


func can_engage(target: CombatHull) -> bool:
	return is_instance_valid(target) and not target.is_destroyed and is_operational() and is_ready() and in_range(target)


## Fires at `target`. Returns false when the weapon could not fire (not ready, out of range, no firing solution).
func fire_at(_target: CombatHull) -> bool:
	return false


## One-line status for the HUD.
func get_status() -> String:
	if not is_operational():
		return "%s: OFFLINE" % weapon_name
	return "%s: %s" % [weapon_name, "ready" if is_ready() else "%d%%" % roundi(get_readiness() * 100.0)]
