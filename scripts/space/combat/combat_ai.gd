class_name CombatAI
extends Node
## Fires a CombatHull's automatic weapons (its parent's WeaponMounts with auto_fire) at the nearest hostile contact
## its faction has detected. Stops when the hull loses its bridge.
## Runs silent until its side picks up a hostile, then switches its active sensors on to hold the contact (which also
## lights it up on everyone else's passive sensors).

## Seconds of simulation time between decisions.
@export var think_interval: float = 1.0
## Torpedoes in flight at one target before launching more at it.
@export var max_torpedoes_per_target: int = 2
## Switch active sensors on while a hostile contact is held.
@export var go_active_on_contact: bool = true

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
	var suite: SensorSuite = hull.get_sensor_suite() if hull else null
	if hull == null or not hull.is_in_command():
		if suite:
			suite.active = false
		return
	var manager := SpaceCombatManager.find(get_tree())
	if manager == null:
		return
	var contacts := manager.get_contacts(hull.faction, hull.get_world_position())
	if suite and go_active_on_contact:
		suite.active = not contacts.is_empty()
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
