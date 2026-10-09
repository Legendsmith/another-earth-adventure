class_name PlayerWeapons
extends Node
## Player fire control for the parent CombatHull, driven by the combat mode's G.U.I.D.E actions: cycle or click a
## detected hostile contact to target it, pick a weapon (slots 1-3 are the hull's weapons in order) and fire it.

signal selected_weapon_changed(index: int)

const CYCLE_CONTACT_ACTION: GUIDEAction = preload("res://ui/guide/combat_cycle_contact.tres")
const SELECT_ACTION: GUIDEAction = preload("res://ui/guide/combat_select.tres")
const FIRE_ACTION: GUIDEAction = preload("res://ui/guide/combat_fire.tres")
const WEAPON_ACTIONS: Array[GUIDEAction] = [
	preload("res://ui/guide/combat_select_weapon_1.tres"),
	preload("res://ui/guide/combat_select_weapon_2.tres"),
	preload("res://ui/guide/combat_select_weapon_3.tres"),
]

var hull: CombatHull
## Index into the hull's weapons of the one that fires.
var selected_weapon := 0


static func find_on(combat_hull: CombatHull) -> PlayerWeapons:
	if combat_hull == null:
		return null
	for child in combat_hull.get_children():
		if child is PlayerWeapons:
			return child
	return null


func _ready() -> void:
	hull = get_parent() as CombatHull
	CYCLE_CONTACT_ACTION.just_triggered.connect(cycle_contact)
	SELECT_ACTION.just_triggered.connect(_on_select_action)
	FIRE_ACTION.just_triggered.connect(fire_selected)
	for i in WEAPON_ACTIONS.size():
		WEAPON_ACTIONS[i].just_triggered.connect(select_weapon.bind(i))


func get_weapons() -> Array[WeaponMount]:
	if hull == null:
		return []
	return hull.get_weapons()


func get_selected_weapon() -> WeaponMount:
	var weapons := get_weapons()
	return weapons[selected_weapon] if selected_weapon < weapons.size() else null


func select_weapon(index: int) -> void:
	if index >= get_weapons().size():
		_warn("No weapon in slot %d" % (index + 1))
		return
	selected_weapon = index
	selected_weapon_changed.emit(index)


func cycle_contact() -> void:
	var manager := SpaceCombatManager.find(get_tree())
	if manager:
		manager.cycle_selected_contact()


## Targets the contact clicked on the plot.
func _on_select_action() -> void:
	var manager := SpaceCombatManager.find(get_tree())
	var overlay := CombatOverlay.find(get_tree())
	if manager and overlay:
		var contact := overlay.contact_under_mouse()
		if contact:
			manager.selected_contact = contact


## Fires the selected weapon at the selected contact, or says why it cannot.
func fire_selected() -> void:
	var manager := SpaceCombatManager.find(get_tree())
	if manager == null or hull == null:
		return
	var target := manager.selected_contact
	if not is_instance_valid(target):
		_warn("No contact selected (Tab or click one)")
		return
	var weapon := get_selected_weapon()
	if weapon == null:
		_warn("No weapon fitted")
		return
	if weapon.fire_at(target):
		return
	var reason := "not ready"
	if not weapon.is_operational():
		reason = "offline"
	elif not weapon.in_range(target):
		reason = "target out of range (%d px max)" % roundi(weapon.max_range)
	elif weapon.is_ready():
		reason = "no firing solution"
	_warn("Cannot fire %s: %s" % [weapon.weapon_name, reason])


func _warn(text: String) -> void:
	var manager := SpaceCombatManager.find(get_tree())
	if manager:
		manager.raise_warning(text, SpaceCombatManager.Severity.CAUTION)
