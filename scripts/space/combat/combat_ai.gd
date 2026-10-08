class_name CombatAI
extends Node
## Fires a CombatHull's automatic weapons (its parent's WeaponMounts with auto_fire) at the nearest hostile contact
## its faction has detected. Stops when the hull loses its bridge.

## Seconds of simulation time between decisions.
@export var think_interval: float = 1.0
## Torpedoes in flight at one target before launching more at it.
@export var max_torpedoes_per_target: int = 2

var hull: CombatHull
var _timer := 0.0


func _ready() -> void:
	hull = get_parent() as CombatHull
	_timer = randf() * think_interval


func _physics_process(delta: float) -> void:
	_timer -= delta
	if _timer > 0.0:
		return
	_timer = think_interval
	if hull == null or not hull.is_in_command():
		return
	var manager := SpaceCombatManager.find(get_tree())
	if manager == null:
		return
	var contacts := manager.get_contacts(hull.faction, hull.get_world_position())
	if contacts.is_empty():
		return
	for weapon in hull.get_weapons():
		if not weapon.auto_fire:
			continue
		for contact in contacts:
			if weapon is TorpedoLauncher and _torpedoes_at(manager, contact) >= max_torpedoes_per_target:
				continue
			if weapon.can_engage(contact) and weapon.fire_at(contact):
				break


func _torpedoes_at(manager: SpaceCombatManager, contact: CombatHull) -> int:
	var count := 0
	for munition in manager.get_munitions():
		if munition is Torpedo and munition.target == contact and munition.faction == hull.faction:
			count += 1
	return count
