class_name SpaceCombatManager
extends Node
## Contact selection and threat warnings for every combat hull in the scene.
##
## What each faction can see comes from the SensorNetwork (each hull's SensorSuite): a faction can only target what
## its sensors hold, so cold torpedoes and railgun rounds stay unseen until they are close or burning.
## Threats the player needs to react to are raised as warnings (and drop time warp).

signal warning_raised(text: String, severity: Severity)

enum Severity { INFO, CAUTION, DANGER }

const GROUP := &"space_combat"
const MUNITION_GROUP := Munition.GROUP
## Seconds (real time) a warning stays on screen.
const WARNING_TIME := 8.0
const MAX_WARNINGS := 6

@export var player_faction: StringName = Constants.PLAYER_GROUP
## Drop to normal time when the player's side detects a new threat.
@export var drop_warp_on_threat: bool = true

## Contact the player's weapons fire at (cycled with combat_cycle_contact).
var selected_contact: CombatHull
## Active warnings: {text, severity, time_left}.
var warnings: Array[Dictionary] = []

var _network: SensorNetwork
var _known_hulls: Dictionary = {}
var _railgun_warned: Dictionary = {}
var _munition_warned: Dictionary = {}
var _orbital_system: Node


static func find(tree: SceneTree) -> SpaceCombatManager:
	return tree.get_first_node_in_group(GROUP) as SpaceCombatManager if tree else null


func _enter_tree() -> void:
	add_to_group(GROUP)


func _ready() -> void:
	_orbital_system = get_tree().get_first_node_in_group(Constants.ORBITAL_SYSTEM_GROUP)
	_network = SensorNetwork.find(get_tree())
	if _network == null:
		push_warning("SpaceCombatManager: no SensorNetwork in the scene, nothing can be detected")
		return
	_network.scanned.connect(_on_scanned)


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
	if _network == null or not is_instance_valid(target):
		return false
	if target is CombatHull:
		return target.faction == faction or _network.is_detected(faction, target.get_sensor_suite())
	return _network.is_detected(faction, target)


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

## After every sensor sweep: drop a selected contact that was lost and warn about new threats.
func _on_scanned() -> void:
	var hulls := get_hulls()
	for hull in hulls:
		if not _known_hulls.has(hull):
			_watch_hull(hull)
	if is_instance_valid(selected_contact) and (selected_contact.is_destroyed or not is_detected_by(player_faction, selected_contact)):
		selected_contact = null
	_update_player_view(hulls, get_munitions())


## Raises warnings for newly detected threats.
func _update_player_view(hulls: Array[CombatHull], munitions: Array[Munition]) -> void:
	var player := get_player_hull()
	var origin := player.get_world_position() if player else Vector2.ZERO
	for hull in hulls:
		if not hull.is_hostile_to(player_faction):
			continue
		var visible_now := is_detected_by(player_faction, hull)
		if visible_now and hull.has_railgun() and not _railgun_warned.has(hull):
			_railgun_warned[hull] = true
			raise_warning("RAILGUN DETECTED: %s at %d px. Its rounds are nearly invisible in flight: keep moving."
				% [hull.display_name, roundi(hull.get_world_position().distance_to(origin))], Severity.DANGER)
	for munition in munitions:
		if not CombatHull.factions_hostile(munition.faction, player_faction):
			continue
		if is_detected_by(player_faction, munition) and not _munition_warned.has(munition):
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
	if source.is_hostile_to(player_faction) and _network and _network.passive_detects(player_faction, at, signature):
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
