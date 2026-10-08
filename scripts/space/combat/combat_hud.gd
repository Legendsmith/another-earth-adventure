class_name CombatHud
extends CanvasLayer
## Combat readout for the player's hull: armor grid, internals, weapons, selected contact, inbound munitions,
## railgun threats and warnings.

const WIDTH := 430.0
const HELP := "T next contact   F torpedo   R railgun"
const SEVERITY_COLORS := ["#cfe8ff", "#ffd27a", "#ff6b5e"]

var _box: VBoxContainer
var _text: RichTextLabel
var _armor: ArmorDisplay


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_box = VBoxContainer.new()
	_box.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_box.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_box.offset_left = -WIDTH - 16.0
	_box.offset_right = -16.0
	_box.offset_top = 16.0
	_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_box)
	_armor = ArmorDisplay.new()
	_armor.custom_minimum_size = Vector2(WIDTH, 0)
	_box.add_child(_armor)
	_text = RichTextLabel.new()
	_text.bbcode_enabled = true
	_text.fit_content = true
	_text.scroll_active = false
	_text.custom_minimum_size = Vector2(WIDTH, 0)
	_text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_text.add_theme_color_override(&"font_shadow_color", Color.BLACK)
	_box.add_child(_text)


func _process(_delta: float) -> void:
	var manager := SpaceCombatManager.find(get_tree())
	var hull: CombatHull = manager.get_player_hull() if manager else null
	_armor.hull = hull
	_armor.queue_redraw()
	if manager == null:
		_text.text = ""
		return
	var lines: PackedStringArray = []
	if hull:
		lines.append(_hull_line(hull))
		lines.append(_internals_line(hull))
		var weapons: PackedStringArray = []
		for weapon in hull.get_weapons():
			weapons.append(weapon.get_status())
		lines.append("Weapons: %s" % (", ".join(weapons) if not weapons.is_empty() else "none"))
		var origin := hull.get_world_position()
		lines.append(_target_line(manager, hull, origin))
		lines.append_array(_threat_lines(manager, origin))
	else:
		lines.append("[color=#ff6b5e]No combat hull[/color]")
	for warning in manager.warnings:
		var alpha := clampf(warning.time_left / 2.0, 0.25, 1.0)
		lines.append("[color=%s%02x]%s[/color]" % [SEVERITY_COLORS[warning.severity], roundi(alpha * 255.0), warning.text])
	lines.append("[color=#8899aa]%s[/color]" % HELP)
	_text.text = "\n".join(lines)


func _hull_line(hull: CombatHull) -> String:
	var armor_name := hull.armor.name if hull.armor else "no armor"
	var status := "  [color=#ff6b5e]DESTROYED[/color]" if hull.is_destroyed else ""
	return "[b]%s[/b]  structure %d/%d   %s %d%% (%d layers x %d)%s" % [hull.display_name, maxi(hull.structure_left, 0),
		hull.structure, armor_name, roundi(hull.grid.get_integrity() * 100.0), hull.grid.layers, hull.grid.columns, status]


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
	return "Target: [b]%s[/b]  %d px  closing %.0f px/s  armor %d%%" % [target.display_name, roundi(relative.length()),
		closing, roundi(target.grid.get_integrity() * 100.0)]


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


## Draws the armor grid: one column per armor column, intact boxes from the outer layer (top) down.
class ArmorDisplay:
	extends Control

	const BOX := 9.0
	const GAP := 2.0

	var hull: CombatHull

	func _draw() -> void:
		if hull == null or hull.grid == null or hull.grid.layers == 0:
			custom_minimum_size.y = 0.0
			return
		var grid := hull.grid
		var box := minf(BOX, (size.x - GAP * grid.columns) / grid.columns)
		custom_minimum_size.y = grid.layers * (box + GAP) + 4.0
		var intact := hull.armor.color if hull.armor else Color.GRAY
		for column in grid.columns:
			for layer in grid.layers:
				# remaining[column] boxes are left, lost from the outside in: the top `layers - remaining` are gone.
				var lost := layer < grid.layers - grid.remaining[column]
				var rect := Rect2(column * (box + GAP), layer * (box + GAP), box, box)
				if lost:
					draw_rect(rect, Color(1.0, 0.4, 0.3, 0.6), false, 1.0)
				else:
					draw_rect(rect, intact)
