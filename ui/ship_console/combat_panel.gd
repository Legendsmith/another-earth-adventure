extends VBoxContainer
## Combat mode of the ShipHud: the player's armor grid and internals, weapons (pick the one that fires), the selected
## contact, inbound munitions, railgun threats and warnings. The target line and brackets are drawn in the world by
## the CombatOverlay.

const SEVERITY_COLORS := ["#cfe8ff", "#ffd27a", "#ff6b5e"]

var console: ShipHud
var _weapons_group := ButtonGroup.new()
var _weapon_buttons: Array[Button] = []

@onready var _armor: ArmorDisplay = %ArmorDisplay
@onready var _hull_readout: RichTextLabel = %HullReadout
@onready var _weapon_list: VBoxContainer = %WeaponList
@onready var _target_readout: RichTextLabel = %TargetReadout


func setup(owner_console: ShipHud) -> void:
	console = owner_console
	%NextContactButton.pressed.connect(_with_weapons.bind(&"cycle_contact"))
	%FireButton.pressed.connect(_with_weapons.bind(&"fire_selected"))


func _process(_delta: float) -> void:
	if not is_visible_in_tree():
		return
	var manager := SpaceCombatManager.find(get_tree())
	var hull: CombatHull = manager.get_player_hull() if manager else null
	_armor.hull = hull
	_armor.queue_redraw()
	if manager == null or hull == null:
		_hull_readout.text = "[color=#ff6b5e]No combat hull[/color]"
		_target_readout.text = ""
		_update_weapons(null)
		return
	_hull_readout.text = "\n".join([_hull_line(hull), _internals_line(hull)])
	_update_weapons(hull)
	var lines: PackedStringArray = []
	var origin := hull.get_world_position()
	lines.append(_target_line(manager, hull, origin))
	lines.append_array(_threat_lines(manager, origin))
	for warning in manager.warnings:
		var alpha := clampf(warning.time_left / 2.0, 0.25, 1.0)
		lines.append("[color=%s%02x]%s[/color]" % [SEVERITY_COLORS[warning.severity], roundi(alpha * 255.0), warning.text])
	_target_readout.text = "\n".join(lines)


func _player_weapons() -> PlayerWeapons:
	var manager := SpaceCombatManager.find(get_tree())
	return PlayerWeapons.find_on(manager.get_player_hull()) if manager else null


func _with_weapons(method: StringName) -> void:
	var weapons := _player_weapons()
	if weapons:
		weapons.call(method)


#region Weapons

## One toggle button per weapon, numbered by its select key; the pressed one fires.
func _update_weapons(hull: CombatHull) -> void:
	var weapons: Array[WeaponMount] = []
	if hull:
		weapons = hull.get_weapons()
	while _weapon_buttons.size() < weapons.size():
		var button := Button.new()
		button.toggle_mode = true
		button.button_group = _weapons_group
		button.focus_mode = Control.FOCUS_NONE
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.pressed.connect(_on_weapon_pressed.bind(_weapon_buttons.size()))
		_weapon_list.add_child(button)
		_weapon_buttons.append(button)
	while _weapon_buttons.size() > weapons.size():
		_weapon_buttons.pop_back().queue_free()
	var player_weapons := PlayerWeapons.find_on(hull)
	var selected := player_weapons.selected_weapon if player_weapons else -1
	for i in weapons.size():
		var key := "%d  " % (i + 1) if i < PlayerWeapons.WEAPON_ACTIONS.size() else ""
		_weapon_buttons[i].text = key + weapons[i].get_status()
		_weapon_buttons[i].set_pressed_no_signal(i == selected)


func _on_weapon_pressed(index: int) -> void:
	var weapons := _player_weapons()
	if weapons:
		weapons.select_weapon(index)

#endregion


#region Readout

func _hull_line(hull: CombatHull) -> String:
	var armor_name := hull.armor.name if hull.armor else "no armor"
	var status := "  [color=#ff6b5e]DESTROYED[/color]" if hull.is_destroyed else ""
	return "[b]%s[/b]  structure %d/%d   %s %d%% (%d layers x %d)%s" % [hull.display_name, maxi(hull.structure_left, 0),
		hull.structure, armor_name, roundi(hull.get_armor_integrity() * 100.0), hull.grid.layers, hull.grid.columns, status]


func _internals_line(hull: CombatHull) -> String:
	var parts: PackedStringArray = []
	for i in hull.components.size():
		var component := hull.components[i]
		if hull.is_component_operational(i):
			var damaged := hull.component_damage[i] > 0
			parts.append("[color=%s]%s[/color]" % ["#ffd27a" if damaged else "#9fdf9f", component.name])
		else:
			parts.append("[color=#ff6b5e][s]%s[/s][/color]" % component.name)
	return "Internals: " + ", ".join(parts)


func _target_line(manager: SpaceCombatManager, hull: CombatHull, origin: Vector2) -> String:
	var target := manager.selected_contact
	if not is_instance_valid(target):
		var count := manager.get_contacts(hull.faction, origin).size()
		return "Target: none (%d hostile contact%s)" % [count, "" if count == 1 else "s"]
	var relative := target.get_world_position() - origin
	var closing := -relative.dot(target.get_world_velocity() - hull.get_world_velocity()) / maxf(relative.length(), 1e-6)
	var line := "Target: [b]%s[/b]  %d px  closing %.0f px/s" % [_contact_name(target), roundi(relative.length()), closing]
	var network := SensorNetwork.find(get_tree())
	if network and network.get_lock(manager.player_faction, target.get_sensor_suite()) == SensorTrack.Lock.ACTIVE:
		line += "  armor %d%%" % roundi(target.get_armor_integrity() * 100.0)
	return line


## The contact's sensor designation, plus its name once identified.
func _contact_name(target: CombatHull) -> String:
	var network := SensorNetwork.find(get_tree())
	var track: SensorTrack = network.get_track_for(target.get_sensor_suite()) if network else null
	if track == null:
		return target.display_name
	return "%s %s" % [track.designation, track.get_display_name()]


func _threat_lines(manager: SpaceCombatManager, origin: Vector2) -> PackedStringArray:
	var lines: PackedStringArray = []
	for munition in manager.get_detected_munitions(manager.player_faction):
		var detail := ""
		if munition is Torpedo:
			detail = " (%s)" % Torpedo.PHASE_NAMES[(munition as Torpedo).phase]
		lines.append("[color=#ff6b5e]INBOUND %s %d px%s[/color]" % [munition.munition_name,
			roundi(munition.get_world_position().distance_to(origin)), detail])
	for contact in manager.get_contacts(manager.player_faction, origin):
		if contact.has_railgun():
			lines.append("[color=#ff6b5e]RAILGUN THREAT: %s at %d px[/color]" % [contact.display_name,
				roundi(contact.get_world_position().distance_to(origin))])
	return lines

#endregion
