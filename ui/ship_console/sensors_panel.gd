extends VBoxContainer
## Sensors mode of the ShipConsole: the active sensors switch, what the ship can see and how visible it is, the
## contact list (held contacts and ghosts of lost ones) and details on the selected contact.

## Signatures the range readout is quoted against.
const QUIET_SIGNATURE := 1.0
const BURNING_SIGNATURE := 40.0
## Passive sensor strength of a typical warship, for "you can be seen at" estimates.
const REFERENCE_SENSOR := 600.0
const HOSTILE_HEX := "#ff6b5e"
const FRIENDLY_HEX := "#8fe3ff"
const UNKNOWN_HEX := "#ffd27a"
const GHOST_HEX := "#9aa4b5"

var console: ShipConsole
var _network: SensorNetwork
var _tree_dirty := true

@onready var _active_toggle: CheckButton = %ActiveToggle
@onready var _active_status: Label = %ActiveStatus
@onready var _stats: Label = %SensorStats
@onready var _tree: Tree = %ContactTree
@onready var _details: RichTextLabel = %Details
@onready var _target_button: Button = %TargetContactButton
@onready var _forget_button: Button = %ForgetButton


func setup(owner_console: ShipConsole) -> void:
	console = owner_console
	_tree.set_column_title(0, "ID")
	_tree.set_column_title(1, "Contact")
	_tree.set_column_title(2, "Range")
	_tree.set_column_title(3, "Status")
	_tree.set_column_expand(0, false)
	_tree.set_column_custom_minimum_width(0, 56)
	_tree.set_column_expand(2, false)
	_tree.set_column_custom_minimum_width(2, 72)
	_tree.set_column_expand(3, false)
	_tree.set_column_custom_minimum_width(3, 96)
	_tree.item_selected.connect(_on_item_selected)
	_active_toggle.toggled.connect(_on_active_toggled)
	_target_button.pressed.connect(_on_target_pressed)
	_forget_button.pressed.connect(_on_forget_pressed)
	visibility_changed.connect(func() -> void: _tree_dirty = true)


func _process(_delta: float) -> void:
	if not is_visible_in_tree():
		return
	if _network == null:
		_network = SensorNetwork.find(get_tree())
		if _network == null:
			_stats.text = "No sensor network"
			return
		_network.scanned.connect(func() -> void: _tree_dirty = true)
	var suite := _player_suite()
	_update_sensor_status(suite)
	if _tree_dirty:
		_tree_dirty = false
		_rebuild_tree()
	_update_details()


func _player_suite() -> SensorSuite:
	return SensorSuite.find_on(console.ship) if console and is_instance_valid(console.ship) else null


#region Own sensors

func _on_active_toggled(on: bool) -> void:
	var suite := _player_suite()
	if suite:
		suite.active = on


func _update_sensor_status(suite: SensorSuite) -> void:
	if suite == null:
		_active_toggle.disabled = true
		_active_status.text = "No sensors"
		_stats.text = ""
		return
	_active_toggle.disabled = not suite.has_active_sensors()
	_active_toggle.set_pressed_no_signal(suite.active)
	_active_status.text = "PINGING: you are lit up" if suite.active else "Passive only: running quiet"
	_active_status.add_theme_color_override(&"font_color", Color(HOSTILE_HEX) if suite.active else Color(FRIENDLY_HEX))
	var signature := suite.get_signature()
	var lines: PackedStringArray = []
	lines.append("Own signature %.1f: a warship's passive sensors pick you up at %d px" % [signature,
		roundi(REFERENCE_SENSOR * sqrt(signature))])
	lines.append("Passive: quiet ship at %d px, burning drive at %d px" % [roundi(suite.passive_range_for(QUIET_SIGNATURE)),
		roundi(suite.passive_range_for(BURNING_SIGNATURE))])
	if suite.active:
		lines.append("Active: any ship-sized contact within %d px, identified" % roundi(suite.active_range_for(1.0)))
	elif suite.has_active_sensors():
		lines.append("Active (off): would hold ship-sized contacts at %d px and add %.0f to your signature" % [
			roundi(suite.active_strength * suite.get_condition()), suite.active_signature])
	if suite.get_condition() < 1.0:
		lines.append("Sensors damaged: %d%% strength" % roundi(suite.get_condition() * 100.0))
	_stats.text = "\n".join(lines)

#endregion


#region Contact list

func _rebuild_tree() -> void:
	_tree.clear()
	var root := _tree.create_item()
	var now := _network.get_time()
	var origin := _network.get_player_position()
	var selected_item: TreeItem
	for track in _network.get_tracks():
		var item := _tree.create_item(root)
		item.set_metadata(0, track)
		item.set_text(0, track.designation)
		var label := track.get_display_name()
		if track.identified and track.get_classification() != track.get_display_name():
			label += " (%s)" % track.get_classification()
		item.set_text(1, label)
		item.set_text(2, _format_distance(_position_of(track, now).distance_to(origin)))
		item.set_text(3, _status_text(track, now))
		var color := Color(_color_hex(track))
		for column in 4:
			item.set_custom_color(column, color)
		if track == _network.selected_track:
			selected_item = item
	if selected_item:
		selected_item.select(0)
	if root.get_child_count() == 0:
		var empty := _tree.create_item(root)
		empty.set_text(1, "No contacts")
		empty.set_selectable(0, false)
		empty.set_selectable(1, false)
		empty.set_selectable(2, false)
		empty.set_selectable(3, false)


func _on_item_selected() -> void:
	var item := _tree.get_selected()
	if item and _network:
		_network.selected_track = item.get_metadata(0) as SensorTrack


func _status_text(track: SensorTrack, now: float) -> String:
	if track.is_held():
		return "ACTIVE" if track.lock == SensorTrack.Lock.ACTIVE else "passive"
	return "ghost %s" % ShipConsole.format_time(now - track.last_seen)


func _color_hex(track: SensorTrack) -> String:
	if track.is_ghost():
		return GHOST_HEX
	if not track.identified:
		return UNKNOWN_HEX
	return HOSTILE_HEX if CombatHull.factions_hostile(track.get_faction(), _network.player_faction) else FRIENDLY_HEX

#endregion


#region Details

func _update_details() -> void:
	var track := _network.selected_track
	var hull: CombatHull = track.get_hull() if track else null
	var manager := SpaceCombatManager.find(get_tree())
	_target_button.disabled = not (track and track.is_held() and hull and manager
		and hull.is_hostile_to(manager.player_faction) and manager.is_detected_by(manager.player_faction, hull))
	_target_button.text = "Weapons target (T)" if not (manager and hull and manager.selected_contact == hull) \
		else "Targeted"
	_forget_button.disabled = not (track and track.is_ghost())
	if track == null:
		_details.text = "[color=%s]Select a contact for details. Lost contacts stay on as ghosts with a projected course.[/color]" % GHOST_HEX
		return
	var now := _network.get_time()
	var origin := _network.get_player_position()
	var lines: PackedStringArray = []
	lines.append("[b]%s  %s[/b]  [color=%s]%s[/color]" % [track.designation, track.get_display_name(), _color_hex(track),
		_iff_text(track)])
	if track.identified:
		lines.append("Class: %s" % track.get_classification())
	if track.is_held():
		var at := _position_of(track, now)
		var relative := at - origin
		var player_velocity := _player_suite().get_world_velocity() if _player_suite() else Vector2.ZERO
		var relative_velocity := track.last_velocity - player_velocity
		var closing := -relative.dot(relative_velocity) / maxf(relative.length(), 1e-6)
		lines.append("%s lock   range %s   bearing %03d°   closing %.0f px/s" % [
			"Active" if track.lock == SensorTrack.Lock.ACTIVE else "Passive", _format_distance(relative.length()),
			_bearing(relative), closing])
		lines.append("Speed %.0f px/s   signature %.1f   tracked %s" % [track.last_velocity.length(), track.last_signature,
			ShipConsole.format_time(now - track.first_seen)])
		if hull and track.identified:
			lines.append_array(_hull_lines(hull, track.lock == SensorTrack.Lock.ACTIVE))
		elif not track.identified:
			lines.append("[color=%s]Unidentified: ping it with active sensors or close in to identify.[/color]" % UNKNOWN_HEX)
	else:
		var since := now - track.last_seen
		lines.append("Lost %s ago at %s" % [ShipConsole.format_time(since), _format_distance(track.last_position.distance_to(origin))])
		if track.is_projection_expired(now):
			lines.append("Projection expired: it could be anywhere by now.")
		else:
			lines.append("Projected now: %s   in 1:00: %s" % [_format_distance(track.get_position_at(now).distance_to(origin)),
				_format_distance(track.get_position_at(now + 60.0).distance_to(origin))])
			lines.append("[color=%s]Assumes it has coasted since contact was lost.[/color]" % GHOST_HEX)
	_details.text = "\n".join(lines)


func _iff_text(track: SensorTrack) -> String:
	if not track.identified:
		return "UNKNOWN"
	var faction := track.get_faction()
	if faction == _network.player_faction:
		return "FRIENDLY"
	if faction == &"":
		return "CIVILIAN"
	return "HOSTILE"


## What an identified hull shows: an active lock reads its armor and damage, passive only what it carries.
func _hull_lines(hull: CombatHull, active_lock: bool) -> PackedStringArray:
	var lines: PackedStringArray = []
	var weapons: PackedStringArray = []
	for weapon in hull.get_weapons():
		weapons.append(weapon.component_name)
	lines.append("Weapons: %s" % (", ".join(weapons) if not weapons.is_empty() else "none seen"))
	if active_lock:
		var lost: PackedStringArray = []
		for i in hull.components.size():
			if not hull.is_component_operational(i):
				lost.append(hull.components[i].name)
		lines.append("Armor %d%%   structure %d/%d%s" % [roundi(hull.grid.get_integrity() * 100.0), maxi(hull.structure_left, 0),
			hull.structure, "   DESTROYED" if hull.is_destroyed else ""])
		if not lost.is_empty():
			lines.append("Knocked out: %s" % ", ".join(lost))
	else:
		lines.append("[color=%s]Armor and damage readings need an active lock.[/color]" % GHOST_HEX)
	return lines


func _on_target_pressed() -> void:
	var track: SensorTrack = _network.selected_track if _network else null
	var manager := SpaceCombatManager.find(get_tree())
	if track and manager and track.get_hull():
		manager.selected_contact = track.get_hull()


func _on_forget_pressed() -> void:
	if _network and _network.selected_track:
		_network.forget(_network.selected_track)
		_tree_dirty = true

#endregion


func _position_of(track: SensorTrack, now: float) -> Vector2:
	if track.is_held() and track.has_target():
		return track.target.get_world_position()
	return track.get_position_at(now)


static func _bearing(relative: Vector2) -> int:
	# 0° is up the screen, clockwise.
	return posmod(roundi(rad_to_deg(atan2(relative.x, -relative.y))), 360)


static func _format_distance(px: float) -> String:
	return "%.1fk px" % (px / 1000.0) if px >= 10000.0 else "%d px" % roundi(px)
