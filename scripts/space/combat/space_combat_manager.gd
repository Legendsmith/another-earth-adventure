class_name SpaceCombatManager
extends Node
## Sensors and threat warnings for every combat hull in the scene.
##
## Detection is passive: a sensor of strength S sees a contact of signature X within S * sqrt(X) px (inverse-square
## falloff). A faction knows everything any of its hulls can see. Hostile hulls and munitions the player's side has not
## detected are hidden, so cold torpedoes and railgun rounds stay invisible until they are close or burning.
## Threats the player needs to react to are raised as warnings (and drop time warp).

signal warning_raised(text: String, severity: Severity)

enum Severity { INFO, CAUTION, DANGER }

const GROUP := &"space_combat"
const MUNITION_GROUP := Munition.GROUP
## Seconds (real time) a warning stays on screen.
const WARNING_TIME := 8.0
const MAX_WARNINGS := 6

@export var player_faction: StringName = Constants.PLAYER_GROUP
## Seconds of simulation time between sensor sweeps.
@export var scan_interval: float = 0.25
## Drop to normal time when the player's side detects a new threat.
@export var drop_warp_on_threat: bool = true

## Contact the player's weapons fire at (cycled with combat_cycle_contact).
var selected_contact: CombatHull
## Active warnings: {text, severity, time_left}.
var warnings: Array[Dictionary] = []

# faction -> {object: true} of what that faction currently detects.
var _detected: Dictionary = {}
var _known_hulls: Dictionary = {}
var _railgun_warned: Dictionary = {}
var _munition_warned: Dictionary = {}
var _scan_timer := 0.0
var _orbital_system: Node


static func find(tree: SceneTree) -> SpaceCombatManager:
	return tree.get_first_node_in_group(GROUP) as SpaceCombatManager if tree else null


func _enter_tree() -> void:
	add_to_group(GROUP)


func _ready() -> void:
	_orbital_system = get_tree().get_first_node_in_group(Constants.ORBITAL_SYSTEM_GROUP)


func _physics_process(delta: float) -> void:
	_scan_timer -= delta
	if _scan_timer <= 0.0:
		_scan_timer = scan_interval
		_scan()


func _process(delta: float) -> void:
	for i in range(warnings.size() - 1, -1, -1):
		warnings[i].time_left -= delta
		if warnings[i].time_left <= 0.0:
			warnings.remove_at(i)


#region Queries

func get_hulls() -> Array[CombatHull]:
	var hulls: Array[CombatHull] = []
	for node in get_tree().get_nodes_in_group(CombatHull.GROUP):
		var hull := node as CombatHull
		if hull and not hull.is_destroyed and hull.is_inside_tree():
			hulls.append(hull)
	return hulls


func get_munitions() -> Array[Munition]:
	var munitions: Array[Munition] = []
	for node in get_tree().get_nodes_in_group(MUNITION_GROUP):
		if node is Munition and not node.is_queued_for_deletion():
			munitions.append(node)
	return munitions


func is_detected_by(faction: StringName, target: Object) -> bool:
	if target is CombatHull and target.faction == faction:
		return true
	return _detected.get(faction, {}).has(target)


## Hostile hulls `faction` currently detects, nearest to `from` first.
func get_contacts(faction: StringName, from: Vector2) -> Array[CombatHull]:
	var contacts: Array[CombatHull] = []
	for hull in get_hulls():
		if hull.is_hostile_to(faction) and is_detected_by(faction, hull):
			contacts.append(hull)
	contacts.sort_custom(func(a: CombatHull, b: CombatHull) -> bool:
		return a.get_world_position().distance_squared_to(from) < b.get_world_position().distance_squared_to(from))
	return contacts


## Hostile munitions `faction` currently detects.
func get_detected_munitions(faction: StringName) -> Array[Munition]:
	var found: Array[Munition] = []
	for munition in get_munitions():
		if CombatHull.factions_hostile(munition.faction, faction) and is_detected_by(faction, munition):
			found.append(munition)
	return found


## The player's hull, even once destroyed (it stays in the scene).
func get_player_hull() -> CombatHull:
	for node in get_tree().get_nodes_in_group(CombatHull.GROUP):
		var hull := node as CombatHull
		if hull and hull.faction == player_faction:
			return hull
	return null


## Selects the next hostile contact the player's side detects (nearest first).
func cycle_selected_contact() -> void:
	var player := get_player_hull()
	if not player:
		return
	var contacts := get_contacts(player_faction, player.get_world_position())
	if contacts.is_empty():
		selected_contact = null
		return
	var index := contacts.find(selected_contact)
	selected_contact = contacts[(index + 1) % contacts.size()]

#endregion


#region Detection

func _scan() -> void:
	var hulls := get_hulls()
	var munitions := get_munitions()
	var factions: Dictionary = {}
	for hull in hulls:
		factions[hull.faction] = true
		if not _known_hulls.has(hull):
			_watch_hull(hull)
	for faction: StringName in factions:
		var seen: Dictionary = {}
		var sensors := hulls.filter(func(h: CombatHull) -> bool: return h.faction == faction)
		for hull in hulls:
			if hull.faction != faction and _any_detects(sensors, hull.get_world_position(), hull.get_signature()):
				seen[hull] = true
		for munition in munitions:
			if munition.faction == faction or _any_detects(sensors, munition.get_world_position(), munition.get_signature()):
				seen[munition] = true
		_detected[faction] = seen
	if is_instance_valid(selected_contact) and (selected_contact.is_destroyed or not is_detected_by(player_faction, selected_contact)):
		selected_contact = null
	_update_player_view(hulls, munitions)


func _any_detects(sensors: Array, at: Vector2, signature: float) -> bool:
	for sensor: CombatHull in sensors:
		var reach := sensor.detection_range_for(signature)
		if sensor.get_world_position().distance_squared_to(at) <= reach * reach:
			return true
	return false


## Hides what the player's side cannot see and raises warnings for newly detected threats.
func _update_player_view(hulls: Array[CombatHull], munitions: Array[Munition]) -> void:
	var player := get_player_hull()
	var origin := player.get_world_position() if player else Vector2.ZERO
	var seen: Dictionary = _detected.get(player_faction, {})
	for hull in hulls:
		if not hull.is_hostile_to(player_faction):
			continue
		var visible_now := seen.has(hull)
		hull.visible = visible_now
		if hull.hide_host_when_undetected and hull.host:
			hull.host.visible = visible_now
		if visible_now and hull.has_railgun() and not _railgun_warned.has(hull):
			_railgun_warned[hull] = true
			raise_warning("RAILGUN DETECTED: %s at %d px. Its rounds are nearly invisible in flight: keep moving."
				% [hull.display_name, roundi(hull.get_world_position().distance_to(origin))], Severity.DANGER)
	for munition in munitions:
		if not CombatHull.factions_hostile(munition.faction, player_faction):
			munition.visible = true
			continue
		var visible_now := seen.has(munition)
		munition.visible = visible_now
		if visible_now and not _munition_warned.has(munition):
			_munition_warned[munition] = true
			raise_warning("%s detected at %d px" % [munition.munition_name,
				roundi(munition.get_world_position().distance_to(origin))], Severity.DANGER)
	# Forget freed objects.
	for key in _railgun_warned.keys():
		if not is_instance_valid(key):
			_railgun_warned.erase(key)
	for key in _munition_warned.keys():
		if not is_instance_valid(key):
			_munition_warned.erase(key)
	for key in _known_hulls.keys():
		if not is_instance_valid(key):
			_known_hulls.erase(key)


## A weapon discharge (railgun shot) at `at` with signature `signature`, aimed at `target`.
## Every faction whose sensors catch the flash learns the shooter's position; the player is warned.
func report_discharge(source: CombatHull, at: Vector2, signature: float, target: CombatHull, flight_time: float) -> void:
	if not is_instance_valid(source):
		return
	source.add_emission(signature)
	var player_sensors := get_hulls().filter(func(h: CombatHull) -> bool: return h.faction == player_faction)
	if source.is_hostile_to(player_faction) and _any_detects(player_sensors, at, signature):
		var line := "RAILGUN DISCHARGE from %s" % source.display_name
		if target and target.faction == player_faction:
			line += ": round inbound, impact in about %.1f s" % flight_time
		raise_warning(line, Severity.DANGER)

#endregion


#region Warnings

func raise_warning(text: String, severity: Severity = Severity.INFO) -> void:
	warnings.push_front({"text": text, "severity": severity, "time_left": WARNING_TIME})
	if warnings.size() > MAX_WARNINGS:
		warnings.resize(MAX_WARNINGS)
	warning_raised.emit(text, severity)
	if severity == Severity.DANGER and drop_warp_on_threat and _orbital_system and _orbital_system.TimeWarp > 1:
		_orbital_system.SetTimeWarpIndex(0)


func _watch_hull(hull: CombatHull) -> void:
	_known_hulls[hull] = true
	if hull.faction == player_faction:
		hull.hit_taken.connect(func(damage: int, penetrating: int) -> void:
			if penetrating > 0:
				raise_warning("Hit for %d: %d through the armor" % [damage, penetrating], Severity.DANGER)
			else:
				raise_warning("Hit for %d: armor held" % damage, Severity.CAUTION))
		hull.component_destroyed.connect(func(component: ShipComponent) -> void:
			raise_warning("%s destroyed" % component.name, Severity.DANGER))
		hull.destroyed.connect(func() -> void: raise_warning("SHIP DESTROYED", Severity.DANGER))
	else:
		hull.destroyed.connect(func() -> void:
			if hull.is_hostile_to(player_faction):
				raise_warning("%s destroyed" % hull.display_name, Severity.INFO))

#endregion
