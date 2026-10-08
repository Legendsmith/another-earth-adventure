## Crew manifest display: shows who holds each crew slot, who is waiting for a slot and who is in cold storage.
## Also lets the streamer connect to a Twitch channel anonymously.
extends PanelContainer

const VACANT_TEXT: String = "— vacant —"
const COLD_STORAGE_SHOWN: int = 20

@onready var channel_edit: LineEdit = %ChannelEdit
@onready var connect_button: Button = %ConnectButton
@onready var status_label: Label = %StatusLabel
@onready var crew_list: VBoxContainer = %CrewList
@onready var waiting_list: VBoxContainer = %WaitingList
@onready var cold_list: VBoxContainer = %ColdList

## Freshness bars of visible members, keyed by user id, refreshed every decay tick.
var _bars: Dictionary[String, ProgressBar] = {}
var _rebuild_queued: bool = false


func _ready() -> void:
	channel_edit.text = Crew.channel_name
	connect_button.pressed.connect(_on_connect_pressed)
	channel_edit.text_submitted.connect(func(_text: String) -> void: _on_connect_pressed())
	VerySimpleTwitch.chat_connected.connect(_on_chat_connected)
	Crew.roster_changed.connect(_queue_rebuild)
	Crew.freshness_updated.connect(_update_bars)
	_rebuild()


func _on_connect_pressed() -> void:
	var channel: String = channel_edit.text.strip_edges()
	if channel.is_empty():
		status_label.text = "Enter a channel name"
		return
	Crew.set_channel_name(channel)
	status_label.text = "Connecting to %s…" % Crew.channel_name
	VerySimpleTwitch.end_chat_client()
	VerySimpleTwitch.login_chat_anon(Crew.channel_name)


func _on_chat_connected(channel: String) -> void:
	status_label.text = "Connected to %s" % channel


## Coalesces several roster changes in one frame (a busy chat) into a single rebuild.
func _queue_rebuild() -> void:
	if not _rebuild_queued:
		_rebuild_queued = true
		_rebuild.call_deferred()


func _rebuild() -> void:
	_rebuild_queued = false
	_bars.clear()
	for list: VBoxContainer in [crew_list, waiting_list, cold_list]:
		for child: Node in list.get_children():
			child.queue_free()

	for i: int in Crew.slots.size():
		var member: CrewMember = Crew.slots[i]
		crew_list.add_child(_make_row("%d." % (i + 1), member))

	var waiting: Array[CrewMember] = Crew.get_waiting()
	%WaitingHeader.text = "Waiting for a slot (%d)" % waiting.size()
	for member: CrewMember in waiting:
		waiting_list.add_child(_make_row("", member))

	var cold: Array[CrewMember] = Crew.get_cold_storage()
	%ColdHeader.text = "Cold storage (%d)" % cold.size()
	for member: CrewMember in cold.slice(0, COLD_STORAGE_SHOWN):
		var label := Label.new()
		label.text = member.display_name
		label.modulate = Color(1, 1, 1, 0.6)
		cold_list.add_child(label)


func _make_row(prefix: String, member: CrewMember) -> Control:
	var row := HBoxContainer.new()
	if prefix:
		var slot_label := Label.new()
		slot_label.text = prefix
		slot_label.custom_minimum_size.x = 32
		row.add_child(slot_label)

	var name_label := Label.new()
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.clip_text = true
	row.add_child(name_label)
	if member == null:
		name_label.text = VACANT_TEXT
		name_label.modulate = Color(1, 1, 1, 0.4)
		return row

	name_label.text = member.display_name
	if member.color_hex:
		name_label.add_theme_color_override(&"font_color", Color.from_string(member.color_hex, Color.WHITE))

	var bar := ProgressBar.new()
	bar.custom_minimum_size = Vector2(120, 0)
	bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	bar.show_percentage = false
	bar.max_value = Crew.max_freshness
	bar.value = member.freshness
	bar.tooltip_text = "Freshness"
	row.add_child(bar)
	_bars[member.user_id] = bar
	return row


func _update_bars() -> void:
	for user_id: String in _bars:
		var member: CrewMember = Crew.get_member(user_id)
		if member:
			_bars[user_id].value = member.freshness
