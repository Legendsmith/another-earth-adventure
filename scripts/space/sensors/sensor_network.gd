class_name SensorNetwork
extends Node
## Sensor detection for every SensorSuite and munition in the scene.
##
## Each sweep works out what every faction can see: a faction sees everything any of its operational suites detects,
## passively (by the contact's signature) or actively (by its cross section, while the suite pings). Contacts the
## player's side does not hold are hidden from view. The player's side also keeps a SensorTrack per contact: lost
## contacts stay on as ghosts with a projected course until they expire or are picked up again.

## Emitted after every sweep, once detection and the player's tracks are up to date.
signal scanned
signal track_acquired(track: SensorTrack)
signal track_lost(track: SensorTrack)

const GROUP := &"sensor_network"
@export var player_faction: StringName = Constants.PLAYER_GROUP
## Seconds of simulation time between sweeps.
@export var scan_interval: float = 0.25
## A passive contact closer than this share of the detection range is close enough to identify.
@export_range(0.0, 1.0) var identify_fraction: float = 0.35
@export_category("Ghosts")
## Seconds a lost ship stays on as a ghost (and how far ahead its course is projected).
@export var ghost_lifetime: float = 300.0
## Seconds a lost munition stays on as a ghost.
@export var munition_ghost_lifetime: float = 30.0
## Projection sample spacing in physics ticks.
@export var ghost_sample_every: int = 30

## Track picked in the Sensors console (highlighted on the plot).
var selected_track: SensorTrack

# faction -> {target (SensorSuite or Munition): SensorTrack.Lock}
var _detected: Dictionary = {}
# target -> SensorTrack, for the player's side
var _tracks: Dictionary = {}
var _next_ship_number := 1
var _next_munition_number := 1
var _scan_timer := 0.0
var _orbital_system: Node


static func find(tree: SceneTree) -> SensorNetwork:
	return tree.get_first_node_in_group(GROUP) as SensorNetwork if tree else null


func _enter_tree() -> void:
	add_to_group(GROUP)


func _ready() -> void:
	_orbital_system = get_tree().get_first_node_in_group(Constants.ORBITAL_SYSTEM_GROUP)


func _physics_process(delta: float) -> void:
	_scan_timer -= delta
	if _scan_timer <= 0.0:
		_scan_timer = scan_interval
		scan()


#region Queries

func get_suites() -> Array[SensorSuite]:
	var suites: Array[SensorSuite] = []
	for node in get_tree().get_nodes_in_group(SensorSuite.GROUP):
		var suite := node as SensorSuite
		if suite and suite.host and suite.is_inside_tree() and not suite.is_queued_for_deletion():
			suites.append(suite)
	return suites


func get_munitions() -> Array[Munition]:
	var munitions: Array[Munition] = []
	for node in get_tree().get_nodes_in_group(Munition.GROUP):
		if node is Munition and not node.is_queued_for_deletion():
			munitions.append(node)
	return munitions


## How `faction` holds `target` (a SensorSuite or Munition) after the last sweep.
func get_lock(faction: StringName, target: Object) -> SensorTrack.Lock:
	return _detected.get(faction, {}).get(target, SensorTrack.Lock.LOST)


func is_detected(faction: StringName, target: Object) -> bool:
	if target == null:
		return false
	if _faction_of(target) == faction and faction != &"":
		return true
	return get_lock(faction, target) != SensorTrack.Lock.LOST


## Does any operational suite of `faction` pick up a signature of `signature` at `at` passively?
func passive_detects(faction: StringName, at: Vector2, signature: float) -> bool:
	for suite in get_suites():
		if suite.get_faction() == faction and suite.is_operational():
			var reach := suite.passive_range_for(signature)
			if suite.get_world_position().distance_squared_to(at) <= reach * reach:
				return true
	return false


## The player's tracks: held contacts first (nearest first), then ghosts (most recently lost first).
func get_tracks() -> Array[SensorTrack]:
	var origin := get_player_position()
	var held: Array[SensorTrack] = []
	var ghosts: Array[SensorTrack] = []
	for track: SensorTrack in _tracks.values():
		if track.is_held():
			held.append(track)
		else:
			ghosts.append(track)
	held.sort_custom(func(a: SensorTrack, b: SensorTrack) -> bool:
		return a.last_position.distance_squared_to(origin) < b.last_position.distance_squared_to(origin))
	ghosts.sort_custom(func(a: SensorTrack, b: SensorTrack) -> bool: return a.last_seen > b.last_seen)
	held.append_array(ghosts)
	return held


func get_track_for(target: Object) -> SensorTrack:
	return _tracks.get(target)


## Drops a ghost from the plot.
func forget(track: SensorTrack) -> void:
	if track and track.is_ghost():
		_tracks.erase(_find_track_key(track))
		if selected_track == track:
			selected_track = null


## The player's own sensors (the first operational suite of the player's faction).
func get_player_suite() -> SensorSuite:
	for suite in get_suites():
		if suite.get_faction() == player_faction:
			return suite
	return null


func get_player_position() -> Vector2:
	var suite := get_player_suite()
	return suite.get_world_position() if suite else Vector2.ZERO


func get_time() -> float:
	return _orbital_system.StateTime if _orbital_system else Time.get_ticks_msec() / 1000.0

#endregion


#region Sweep

func scan() -> void:
	var suites := get_suites()
	var munitions := get_munitions()
	var sensors_by_faction: Dictionary = {}
	for suite in suites:
		var faction := suite.get_faction()
		if faction == &"" or not suite.is_operational():
			continue
		if not sensors_by_faction.has(faction):
			sensors_by_faction[faction] = []
		sensors_by_faction[faction].append(suite)
	_detected.clear()
	for faction: StringName in sensors_by_faction:
		var sensors: Array = sensors_by_faction[faction]
		var seen: Dictionary = {}
		for suite in suites:
			if suite.get_faction() != faction:
				var lock := _best_lock(sensors, suite.get_world_position(), suite.get_signature(), suite.cross_section)
				if lock != SensorTrack.Lock.LOST:
					seen[suite] = lock
		for munition in munitions:
			if munition.faction == faction:
				continue
			var lock := _best_lock(sensors, munition.get_world_position(), munition.get_signature(),
				munition.cross_section)
			if lock != SensorTrack.Lock.LOST:
				seen[munition] = lock
		_detected[faction] = seen
	_update_tracks(suites, munitions)
	_update_visibility(suites, munitions)
	scanned.emit()


func _best_lock(sensors: Array, at: Vector2, signature: float, cross_section: float) -> SensorTrack.Lock:
	var best := SensorTrack.Lock.LOST
	for sensor: SensorSuite in sensors:
		var distance_squared := sensor.get_world_position().distance_squared_to(at)
		var active_reach := sensor.active_range_for(cross_section)
		if distance_squared <= active_reach * active_reach:
			return SensorTrack.Lock.ACTIVE
		var passive_reach := sensor.passive_range_for(signature)
		if distance_squared <= passive_reach * passive_reach:
			best = SensorTrack.Lock.PASSIVE
	return best


## Close enough to a passive contact to make it out?
func _is_close_passive(at: Vector2, signature: float) -> bool:
	for suite in get_suites():
		if suite.get_faction() == player_faction and suite.is_operational():
			var reach := suite.passive_range_for(signature) * identify_fraction
			if suite.get_world_position().distance_squared_to(at) <= reach * reach:
				return true
	return false


static func _faction_of(target: Object) -> StringName:
	if not is_instance_valid(target):
		return &""
	if target is SensorSuite:
		return (target as SensorSuite).get_faction()
	if target is Munition:
		return (target as Munition).faction
	return &""

#endregion


#region Player tracks

func _update_tracks(suites: Array[SensorSuite], munitions: Array[Munition]) -> void:
	var now := get_time()
	var seen: Dictionary = _detected.get(player_faction, {})
	for suite in suites:
		if suite.get_faction() != player_faction or player_faction == &"":
			_update_track(suite, SensorTrack.Kind.SHIP, seen.get(suite, SensorTrack.Lock.LOST), suite.get_world_position(),
				suite.get_world_velocity(), suite.get_signature(), now)
	for munition in munitions:
		if munition.faction != player_faction:
			_update_track(munition, SensorTrack.Kind.MUNITION, seen.get(munition, SensorTrack.Lock.LOST),
				munition.get_world_position(), munition.linear_velocity, munition.get_signature(), now)
	for key in _tracks.keys():
		var track: SensorTrack = _tracks[key]
		if track.is_held() and not is_instance_valid(key):
			# Destroyed (or a munition detonating) while we watched: nothing left to track.
			_tracks.erase(key)
			if selected_track == track:
				selected_track = null
			continue
		if track.is_ghost():
			var lifetime := ghost_lifetime if track.kind == SensorTrack.Kind.SHIP else munition_ghost_lifetime
			if now - track.last_seen > lifetime:
				_tracks.erase(key)
				if selected_track == track:
					selected_track = null


func _update_track(target: Object, kind: SensorTrack.Kind, lock: SensorTrack.Lock, at: Vector2, velocity: Vector2,
		signature: float, now: float) -> void:
	var track: SensorTrack = _tracks.get(target)
	if lock == SensorTrack.Lock.LOST:
		if track and track.is_held():
			_lose(track, now)
		return
	var acquired := track == null or track.is_ghost()
	if track == null:
		track = SensorTrack.new()
		track.target = target
		track.kind = kind
		track.first_seen = now
		if kind == SensorTrack.Kind.SHIP:
			track.designation = "S-%02d" % _next_ship_number
			_next_ship_number += 1
		else:
			track.designation = "M-%02d" % _next_munition_number
			_next_munition_number += 1
		_tracks[target] = track
	track.lock = lock
	track.last_seen = now
	track.last_position = at
	track.last_velocity = velocity
	track.last_signature = signature
	track.ghost_points = PackedVector2Array()
	if lock == SensorTrack.Lock.ACTIVE or _is_close_passive(at, signature):
		track.identified = true
	if acquired:
		track_acquired.emit(track)


## Turns a held track into a ghost and projects its course from the last known state.
func _lose(track: SensorTrack, now: float) -> void:
	var lost_at := track.last_seen
	track.lock = SensorTrack.Lock.LOST
	track.ghost_points = PackedVector2Array()
	track.ghost_start = now
	track.ghost_end = now
	track_lost.emit(track)
	if _orbital_system == null or not _orbital_system.IsReady:
		return
	# Until the projection arrives the ghost drifts in a straight line (SensorTrack.get_position_at).
	var lifetime := ghost_lifetime if track.kind == SensorTrack.Kind.SHIP else munition_ghost_lifetime
	var job: RefCounted = _orbital_system.PredictAsync(track.last_position, track.last_velocity, {
		"max_time": lifetime,
		"sample_every": ghost_sample_every,
		"stop_after_orbits": 0.0,
	})
	if job == null:
		return
	job.connect(&"Completed", func(prediction: Variant) -> void:
		# Ignore a projection that arrives after the contact was picked up again (or lost again since).
		if prediction == null or not track.is_ghost() or track.last_seen != lost_at or prediction.SampleCount < 2:
			return
		track.ghost_points = prediction.GetWorldPoints()
		track.ghost_start = prediction.StartTime
		track.ghost_end = prediction.EndTime)


func _find_track_key(track: SensorTrack) -> Variant:
	for key in _tracks:
		if _tracks[key] == track:
			return key
	return null

#endregion


#region Visibility

## Hides contacts the player's side does not hold. Own ships and munitions are always shown.
func _update_visibility(suites: Array[SensorSuite], munitions: Array[Munition]) -> void:
	var seen: Dictionary = _detected.get(player_faction, {})
	for suite in suites:
		if suite.get_faction() == player_faction:
			continue
		var visible_now := seen.has(suite)
		var hull := suite.get_hull()
		if hull and not hull.hide_host_when_undetected:
			# Only the contact marker hides; the host (an asteroid) is in plain sight.
			hull.visible = visible_now
		else:
			suite.host.visible = visible_now
	for munition in munitions:
		munition.visible = munition.faction == player_faction or seen.has(munition)

#endregion
