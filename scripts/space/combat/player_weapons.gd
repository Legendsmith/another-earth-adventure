class_name PlayerWeapons
extends Node
## Player fire control for the parent CombatHull, driven by the combat mode's G.U.I.D.E actions: cycle or click a
## detected hostile contact to target it, pick a weapon (slots 1-3 are the hull's weapons in order) and fire it.
##
## Point defence groundwork: incoming munitions can be locked (click one, or lock every inbound one) and each lock is
## assessed for the chance it gets through the point defence net and strikes its target. With no point defence
## mounts fitted the net stops nothing.

signal selected_weapon_changed(index: int)
signal munition_locks_changed

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
## Incoming munitions locked for point defence.
var munition_locks: Array[Munition] = []


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


## The weapons that fire together (one for now: the selected slot).
func get_selected_weapons() -> Array[WeaponMount]:
	var weapon := get_selected_weapon()
	if weapon == null:
		return []
	return [weapon]


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


## Targets the contact clicked on the plot, or locks (or unlocks) the incoming munition clicked.
func _on_select_action() -> void:
	var manager := SpaceCombatManager.find(get_tree())
	var overlay := CombatOverlay.find(get_tree())
	if manager == null or overlay == null:
		return
	var contact := overlay.contact_under_mouse()
	if contact:
		manager.selected_contact = contact
		return
	var munition := overlay.munition_under_mouse()
	if munition:
		toggle_munition_lock(munition)


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


#region Point defence

func _process(_delta: float) -> void:
	# Drop locks on munitions that are gone or no longer seen.
	var manager := SpaceCombatManager.find(get_tree())
	var changed := false
	for i in range(munition_locks.size() - 1, -1, -1):
		var munition := munition_locks[i]
		if not is_instance_valid(munition) or munition.is_queued_for_deletion() or manager == null \
				or not manager.is_detected_by(hull.faction, munition):
			munition_locks.remove_at(i)
			changed = true
	if changed:
		munition_locks_changed.emit()


## Hostile munitions the player's side can see.
func get_inbound_munitions() -> Array[Munition]:
	var manager := SpaceCombatManager.find(get_tree())
	if manager == null or hull == null:
		return []
	return manager.get_detected_munitions(hull.faction)


func is_munition_locked(munition: Munition) -> bool:
	return munition_locks.has(munition)


func lock_munition(munition: Munition) -> void:
	if is_instance_valid(munition) and not munition_locks.has(munition):
		munition_locks.append(munition)
		munition_locks_changed.emit()


func unlock_munition(munition: Munition) -> void:
	if munition_locks.has(munition):
		munition_locks.erase(munition)
		munition_locks_changed.emit()


func toggle_munition_lock(munition: Munition) -> void:
	if is_munition_locked(munition):
		unlock_munition(munition)
	else:
		lock_munition(munition)


## Locks every inbound munition the player's side can see.
func lock_all_inbound() -> void:
	for munition in get_inbound_munitions():
		lock_munition(munition)


func clear_munition_locks() -> void:
	if not munition_locks.is_empty():
		munition_locks.clear()
		munition_locks_changed.emit()


## Point defence mounts on the hull (none until point defence is added).
func get_point_defence_mounts() -> Array[WeaponMount]:
	var mounts: Array[WeaponMount] = []
	for weapon in get_weapons():
		if weapon.is_point_defence() and weapon.is_operational():
			mounts.append(weapon)
	return mounts


## How a munition's run looks: {target, time_to_impact (s, -1 if it misses), closest_approach (px), closing (px/s),
## hit_chance (strikes if nothing stops it), pd_kill_chance (the net stops it), strike_chance (gets through the net
## and strikes its target)}. Straight-line estimate; guided torpedoes are assumed to home in.
func assess_munition(munition: Munition) -> Dictionary:
	var target: CombatHull = munition.target if munition.has_valid_target() else hull
	var relative := munition.get_world_position() - target.get_world_position()
	var relative_velocity := munition.linear_velocity - target.get_world_velocity()
	var speed_squared := relative_velocity.length_squared()
	var time := 0.0 if speed_squared < 1e-6 else maxf(-relative.dot(relative_velocity) / speed_squared, 0.0)
	var closest := (relative + relative_velocity * time).length()
	var closing := -relative.dot(relative_velocity) / maxf(relative.length(), 1e-6)
	var guided := munition is Torpedo and munition.has_valid_target()
	var hit_chance := 1.0 if guided or closest <= target.hit_radius else 0.0
	var leak := 1.0
	for mount in get_point_defence_mounts():
		leak *= 1.0 - clampf(mount.get_point_defence_kill_chance(munition), 0.0, 1.0)
	return {
		"target": target,
		"time_to_impact": time if hit_chance > 0.0 else -1.0,
		"closest_approach": closest,
		"closing": closing,
		"hit_chance": hit_chance,
		"pd_kill_chance": 1.0 - leak,
		"strike_chance": leak * hit_chance,
	}

#endregion
