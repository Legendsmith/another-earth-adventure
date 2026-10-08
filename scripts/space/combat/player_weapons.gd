class_name PlayerWeapons
extends Node
## Player fire control for the parent CombatHull: T selects the next detected hostile contact, F launches a torpedo
## at it and R fires the railgun (if the ship carries one and has the power to charge it).

var hull: CombatHull


func _ready() -> void:
	hull = get_parent() as CombatHull


func _unhandled_input(event: InputEvent) -> void:
	var manager := SpaceCombatManager.find(get_tree())
	if manager == null or hull == null:
		return
	if event.is_action_pressed(&"combat_cycle_contact"):
		manager.cycle_selected_contact()
	elif event.is_action_pressed(&"combat_fire_torpedo"):
		_fire(manager, func(w: WeaponMount) -> bool: return w is TorpedoLauncher, "torpedo")
	elif event.is_action_pressed(&"combat_fire_railgun"):
		_fire(manager, func(w: WeaponMount) -> bool: return w is Railgun, "railgun")
	else:
		return
	get_viewport().set_input_as_handled()


func _fire(manager: SpaceCombatManager, kind: Callable, label: String) -> void:
	var target := manager.selected_contact
	if not is_instance_valid(target):
		manager.raise_warning("No contact selected (T)", SpaceCombatManager.Severity.CAUTION)
		return
	var weapons := hull.get_weapons().filter(kind)
	if weapons.is_empty():
		manager.raise_warning("No %s fitted" % label, SpaceCombatManager.Severity.CAUTION)
		return
	for weapon: WeaponMount in weapons:
		if weapon.fire_at(target):
			return
	var first: WeaponMount = weapons[0]
	var reason := "not ready"
	if not first.is_operational():
		reason = "offline"
	elif not first.in_range(target):
		reason = "target out of range (%d px max)" % roundi(first.max_range)
	elif first.is_ready():
		reason = "no firing solution"
	manager.raise_warning("Cannot fire %s: %s" % [label, reason], SpaceCombatManager.Severity.CAUTION)
