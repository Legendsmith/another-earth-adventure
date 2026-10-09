class_name CombatOverlay
extends Node2D
## World-space combat plot for the player: the target line from the player's hull to the selected contact with its
## range, brackets on the selected contact, and the selected weapon's reach.

const GROUP := &"combat_overlay"
## Screen distance within which a click picks a contact.
const PICK_DISTANCE := 16.0
const FONT_SIZE := 12
const TARGET_COLOR := Color(1.0, 0.35, 0.3, 0.9)
const OUT_OF_RANGE_COLOR := Color(1.0, 0.8, 0.45, 0.8)
const RANGE_RING_COLOR := Color(1.0, 0.45, 0.4, 0.15)


static func find(tree: SceneTree) -> CombatOverlay:
	return tree.get_first_node_in_group(GROUP) as CombatOverlay if tree else null


func _enter_tree() -> void:
	add_to_group(GROUP)


func _ready() -> void:
	z_index = 11
	process_mode = Node.PROCESS_MODE_ALWAYS


func _process(_delta: float) -> void:
	queue_redraw()


## The detected hostile contact nearest the mouse, within the pick distance, or null.
func contact_under_mouse() -> CombatHull:
	var manager := SpaceCombatManager.find(get_tree())
	var player: CombatHull = manager.get_player_hull() if manager else null
	if player == null:
		return null
	var mouse := get_global_mouse_position()
	var pixel := 1.0 / get_canvas_transform().get_scale().x
	var best: CombatHull = null
	var best_distance := INF
	for contact in manager.get_contacts(manager.player_faction, player.get_world_position()):
		var distance := mouse.distance_to(contact.get_world_position())
		if distance <= PICK_DISTANCE * pixel + contact.hit_radius and distance < best_distance:
			best_distance = distance
			best = contact
	return best


func _draw() -> void:
	var manager := SpaceCombatManager.find(get_tree())
	if manager == null:
		return
	var player := manager.get_player_hull()
	var target := manager.selected_contact
	if player == null or player.is_destroyed or not is_instance_valid(target):
		return
	var s := maxf(1.0, 1.0 / get_canvas_transform().get_scale().x)
	var from := player.get_world_position()
	var to := target.get_world_position()
	var weapons := PlayerWeapons.find_on(player)
	var weapon: WeaponMount = weapons.get_selected_weapon() if weapons else null
	var in_range := weapon == null or weapon.in_range(target)
	var color := TARGET_COLOR if in_range else OUT_OF_RANGE_COLOR
	if weapon:
		draw_arc(from, weapon.max_range, 0.0, TAU, 128, RANGE_RING_COLOR, 1.5 * s)
	# Target line, stopping short of both hulls.
	var direction := (to - from).normalized()
	draw_dashed_line(from + direction * (player.hit_radius + 6.0) * s, to - direction * (target.hit_radius + 10.0) * s,
		color, 1.0 * s, 8.0 * s)
	_brackets(to, (target.hit_radius + 4.0) * 1.6 * s, color, s)
	var label := "%d px" % roundi(from.distance_to(to))
	if not in_range:
		label += " (out of range)"
	_label((from + to) * 0.5 + Vector2(8.0, -6.0) * s, label, color, s)


func _brackets(at: Vector2, b: float, color: Color, s: float) -> void:
	var l := b * 0.4
	for corner: Vector2 in [Vector2(1, 1), Vector2(-1, 1), Vector2(1, -1), Vector2(-1, -1)]:
		var c := at + corner * b
		draw_line(c, c - Vector2(corner.x * l, 0), color, 1.5 * s)
		draw_line(c, c - Vector2(0, corner.y * l), color, 1.5 * s)


func _label(at: Vector2, text: String, color: Color, s: float) -> void:
	var font := ThemeDB.fallback_font
	var size := roundi(FONT_SIZE * s)
	draw_string_outline(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, maxi(roundi(3.0 * s), 1), Color(0, 0, 0, 0.7))
	draw_string(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, color)
