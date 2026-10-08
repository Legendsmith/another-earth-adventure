## Autoload "Crew": turns Twitch chatters into crew members.
## A chatter who sends a message takes a free crew slot under their display name. Each message adds
## freshness with a falloff, so rapid messages add little and spaced-out messages add a lot.
## Freshness decays over time; at 0 the chatter is retired to cold storage and their slot frees up.
## Sending !lurk retires a chatter immediately. The roster is saved between sessions.
extends Node

signal crew_joined(member: CrewMember)
signal crew_retired(member: CrewMember)
## Emitted whenever membership, names or slots change.
signal roster_changed
## Emitted once per decay tick, after freshness values have been updated.
signal freshness_updated

const SAVE_PATH: String = "user://crew_roster.json"
const SAVE_VERSION: int = 1
const TICK_SECONDS: float = 1.0
const AUTOSAVE_SECONDS: float = 15.0

## Number of crew slots chatters can occupy.
var crew_size: int = 8: set = set_crew_size
## Seconds a chatter at full freshness stays on the crew without sending another message.
var stale_seconds: float = 30.0 * 60.0
var max_freshness: float = 100.0
## Freshness a message adds when the chatter has been quiet for a while (or is new / returning from cold storage).
var message_gain: float = 50.0
## Time constant of the falloff curve. A message sent t seconds after the previous one adds
## message_gain * (1 - exp(-t / gain_recovery_seconds)), so spam adds almost nothing.
var gain_recovery_seconds: float = 90.0
var lurk_command: String = "!lurk"

## Twitch channel the manifest connects to, remembered between sessions.
var channel_name: String = ""

var members: Dictionary[String, CrewMember] = {}
var slots: Array[CrewMember] = []

var _tick_accumulator: float = 0.0
var _autosave_accumulator: float = 0.0
var _dirty: bool = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	slots.resize(crew_size)
	load_roster()
	VerySimpleTwitch.chat_message_received.connect(_on_chat_message_received)


func _process(delta: float) -> void:
	_tick_accumulator += delta
	if _tick_accumulator >= TICK_SECONDS:
		decay(_tick_accumulator)
		_tick_accumulator = 0.0
	_autosave_accumulator += delta
	if _autosave_accumulator >= AUTOSAVE_SECONDS:
		_autosave_accumulator = 0.0
		if _dirty:
			save_roster()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_EXIT_TREE:
		if _dirty:
			save_roster()


#region Chat handling

func _on_chat_message_received(chatter: VSTChatter) -> void:
	var user_id: String = chatter.tags.user_id if chatter.tags.user_id else chatter.login
	var display_name: String = chatter.tags.display_name if chatter.tags.display_name else chatter.login
	register_message(user_id, chatter.login, display_name, chatter.message, chatter.tags.color_hex)


## Records a chat message from a chatter. Also usable for testing without a Twitch connection.
func register_message(user_id: String, login: String, display_name: String, message: String, color_hex: String = "") -> void:
	if user_id.is_empty():
		return
	var member: CrewMember = members.get(user_id)
	if member == null:
		member = CrewMember.new()
		member.user_id = user_id
		members[user_id] = member
	member.login = login
	member.display_name = display_name
	if color_hex:
		member.color_hex = color_hex
	var now: float = Time.get_unix_time_from_system()

	if message.strip_edges().to_lower().begins_with(lurk_command):
		member.last_message_unix = now
		retire(member)
		_mark_changed()
		return

	member.freshness = minf(max_freshness, member.freshness + freshness_gain(member, now))
	member.last_message_unix = now
	member.message_count += 1
	if not member.is_on_crew():
		_try_assign_slot(member)
	_mark_changed()


## Freshness a message sent at [param now] would add for [param member].
func freshness_gain(member: CrewMember, now: float) -> float:
	if member.is_cold() or member.last_message_unix <= 0.0:
		return message_gain
	var elapsed: float = maxf(0.0, now - member.last_message_unix)
	return message_gain * (1.0 - exp(-elapsed / gain_recovery_seconds))

#endregion


#region Freshness and slots

func decay(seconds: float) -> void:
	var loss: float = max_freshness / stale_seconds * seconds
	var retired_any: bool = false
	for member: CrewMember in members.values():
		if member.is_cold():
			continue
		member.freshness = maxf(0.0, member.freshness - loss)
		if member.is_cold():
			retire(member)
			retired_any = true
	if retired_any:
		_mark_changed()
	freshness_updated.emit()


## Moves a member to cold storage, freeing their crew slot for a waiting chatter.
func retire(member: CrewMember) -> void:
	member.freshness = 0.0
	if member.is_on_crew():
		slots[member.slot] = null
		member.slot = -1
		crew_retired.emit(member)
		_fill_open_slots()


func _try_assign_slot(member: CrewMember) -> bool:
	var free_slot: int = slots.find(null)
	if free_slot == -1:
		return false
	slots[free_slot] = member
	member.slot = free_slot
	crew_joined.emit(member)
	return true


## Gives free slots to the freshest waiting chatters.
func _fill_open_slots() -> void:
	var waiting: Array[CrewMember] = get_waiting()
	for member: CrewMember in waiting:
		if not _try_assign_slot(member):
			break


func set_crew_size(new_size: int) -> void:
	crew_size = maxi(0, new_size)
	if not is_node_ready():
		return
	for i: int in range(crew_size, slots.size()):
		if slots[i]:
			slots[i].slot = -1
	slots.resize(crew_size)
	_fill_open_slots()
	_mark_changed()

#endregion


#region Queries

## Crew members currently holding a slot, in slot order.
func get_crew() -> Array[CrewMember]:
	var crew: Array[CrewMember] = []
	for member: CrewMember in slots:
		if member:
			crew.append(member)
	return crew


func get_member(user_id: String) -> CrewMember:
	return members.get(user_id)


## Chatters with freshness who are waiting for a free slot, freshest first.
func get_waiting() -> Array[CrewMember]:
	var waiting: Array[CrewMember] = []
	for member: CrewMember in members.values():
		if member.is_waiting():
			waiting.append(member)
	waiting.sort_custom(func(a: CrewMember, b: CrewMember) -> bool: return a.freshness > b.freshness)
	return waiting


## Retired chatters, most recently seen first.
func get_cold_storage() -> Array[CrewMember]:
	var cold: Array[CrewMember] = []
	for member: CrewMember in members.values():
		if member.is_cold():
			cold.append(member)
	cold.sort_custom(func(a: CrewMember, b: CrewMember) -> bool: return a.last_message_unix > b.last_message_unix)
	return cold

#endregion


#region Saving

func _mark_changed() -> void:
	_dirty = true
	roster_changed.emit()


func set_channel_name(new_channel: String) -> void:
	channel_name = new_channel.strip_edges().to_lower()
	_mark_changed()


## Freshness is saved as-is and only decays while the game runs, so the crew is kept between sessions.
func save_roster() -> Error:
	var member_data: Array[Dictionary] = []
	for member: CrewMember in members.values():
		member_data.append(member.to_dict())
	var data: Dictionary = {
		"version": SAVE_VERSION,
		"channel_name": channel_name,
		"members": member_data,
	}
	var file := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if file == null:
		push_warning("Could not save crew roster: %s" % error_string(FileAccess.get_open_error()))
		return FileAccess.get_open_error()
	file.store_string(JSON.stringify(data, "\t"))
	file.close()
	_dirty = false
	return OK


func load_roster() -> Error:
	if not FileAccess.file_exists(SAVE_PATH):
		return ERR_FILE_NOT_FOUND
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(SAVE_PATH))
	if not parsed is Dictionary:
		push_warning("Crew roster save is corrupt, starting with an empty roster.")
		return ERR_FILE_CORRUPT
	var data: Dictionary = parsed
	channel_name = str(data.get("channel_name", ""))
	members.clear()
	slots.fill(null)
	for entry: Variant in data.get("members", []):
		if not entry is Dictionary:
			continue
		var member: CrewMember = CrewMember.from_dict(entry)
		if member.user_id.is_empty():
			continue
		members[member.user_id] = member
		if member.is_cold() or member.slot >= crew_size or (member.slot >= 0 and slots[member.slot] != null):
			member.slot = -1
		elif member.slot >= 0:
			slots[member.slot] = member
	_fill_open_slots()
	roster_changed.emit()
	return OK

#endregion
