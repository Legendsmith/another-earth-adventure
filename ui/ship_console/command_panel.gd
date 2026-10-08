extends VBoxContainer
## Command mode of the ShipConsole: collecting rewards from the planet in low orbit, the crew, and crew expeditions
## (coming later).

const LOG_LINES := 4

var console: ShipConsole
var _log: PackedStringArray = []
var _watched_planets: Dictionary = {}
var _crew_dirty := true

@onready var _planet_info: Label = %PlanetInfo
@onready var _collect_button: Button = %CollectButton
@onready var _rewards_log: Label = %RewardsLog
@onready var _crew_title: Label = %CrewTitle
@onready var _crew_list: VBoxContainer = %CrewList
@onready var _manifest_popup: PopupPanel = %ManifestPopup


func setup(owner_console: ShipConsole) -> void:
	console = owner_console
	_collect_button.pressed.connect(_on_collect_pressed)
	%ManifestButton.pressed.connect(func() -> void: _manifest_popup.popup_centered())
	Crew.roster_changed.connect(func() -> void: _crew_dirty = true)
	Crew.freshness_updated.connect(func() -> void: _crew_dirty = true)
	visibility_changed.connect(func() -> void: _crew_dirty = true)


func _process(_delta: float) -> void:
	_watch_planets()
	if not is_visible_in_tree():
		return
	_update_planet()
	if _crew_dirty:
		_crew_dirty = false
		_rebuild_crew()


#region Planet rewards

## The planet whose low orbit the player's ship is in, if any.
func get_orbited_planet() -> Planet:
	for node in get_tree().get_nodes_in_group(Planet.GROUP):
		var planet := node as Planet
		if planet and planet.is_in_low_orbit():
			return planet
	return null


func _update_planet() -> void:
	var planet := get_orbited_planet()
	if planet == null:
		_planet_info.text = "Not in low orbit of a planet. Low orbit is the ring around each planet."
		_collect_button.disabled = true
		return
	var type_name: String = planet.planet_type.display_name if planet.planet_type else "Unknown"
	var status := "rewards already collected" if planet.data.collected else "rewards waiting"
	_planet_info.text = "In low orbit of %s (%s): %s" % [_planet_name(planet), type_name, status]
	_collect_button.disabled = not planet.can_collect()


func _on_collect_pressed() -> void:
	var planet := get_orbited_planet()
	if planet and planet.can_collect():
		planet.collect_rewards()


## Collection with E happens on the planet itself, so the log listens to every planet.
func _watch_planets() -> void:
	for node in get_tree().get_nodes_in_group(Planet.GROUP):
		if not _watched_planets.has(node):
			_watched_planets[node] = true
			(node as Planet).rewards_collected.connect(_on_rewards_collected)


func _on_rewards_collected(planet: Planet, rewards: PlanetRewards) -> void:
	_log.insert(0, "%s: %s" % [_planet_name(planet), describe_rewards(rewards)])
	if _log.size() > LOG_LINES:
		_log.resize(LOG_LINES)
	_rewards_log.text = "\n".join(_log)


static func describe_rewards(rewards: PlanetRewards) -> String:
	if rewards == null or rewards.is_empty():
		return "nothing of value"
	var parts: PackedStringArray = []
	if rewards.crew > 0:
		parts.append("%d crew" % rewards.crew)
	for id: StringName in rewards.items:
		parts.append("%d %s" % [rewards.items[id], String(id).capitalize()])
	for id: StringName in rewards.resources:
		parts.append("%d %s" % [rewards.resources[id], String(id).capitalize()])
	return ", ".join(parts)


static func _planet_name(planet: Planet) -> String:
	var body := planet.get_parent()
	return String(body.name) if body else String(planet.name)

#endregion


#region Crew

func _rebuild_crew() -> void:
	for child in _crew_list.get_children():
		child.queue_free()
	var crew := Crew.get_crew()
	_crew_title.text = "Crew %d/%d   (%d waiting)" % [crew.size(), Crew.slots.size(), Crew.get_waiting().size()]
	if crew.is_empty():
		var empty := Label.new()
		empty.text = "No crew aboard. Chatters join the crew when they talk in Twitch chat."
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		empty.modulate = Color(1, 1, 1, 0.6)
		_crew_list.add_child(empty)
		return
	for member in crew:
		var row := HBoxContainer.new()
		var name_label := Label.new()
		name_label.text = member.display_name
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_label.clip_text = true
		if member.color_hex:
			name_label.add_theme_color_override(&"font_color", Color.from_string(member.color_hex, Color.WHITE))
		row.add_child(name_label)
		var assignment := Label.new()
		assignment.text = "aboard"
		assignment.modulate = Color(1, 1, 1, 0.6)
		row.add_child(assignment)
		var bar := ProgressBar.new()
		bar.custom_minimum_size = Vector2(90, 0)
		bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		bar.show_percentage = false
		bar.max_value = Crew.max_freshness
		bar.value = member.freshness
		bar.tooltip_text = "Freshness"
		row.add_child(bar)
		_crew_list.add_child(row)

#endregion
