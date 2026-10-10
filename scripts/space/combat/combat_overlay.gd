class_name CombatOverlay
extends Node2D
## World-space combat plot for the player: the target line from the player's hull to the selected contact with its
## range, brackets on the selected contact, markers on munitions locked for point defence, and (with
## `show_weapon_ranges`, the Combat view) the range bands of the selected weapons. Drawn in world px over the map (see
## SpaceScale).

const GROUP := &"combat_overlay"
## Screen distance within which a click picks a contact.
const PICK_DISTANCE := 16.0
const FONT_SIZE := 12
const TARGET_COLOR := Color(1.0, 0.35, 0.3, 0.9)
const OUT_OF_RANGE_COLOR := Color(1.0, 0.8, 0.45, 0.8)
const BAND_COLORS: Array[Color] = [Color(1.0, 0.45, 0.4, 0.07), Color(1.0, 0.7, 0.4, 0.045)]
const BAND_EDGE_COLOR := Color(1.0, 0.55, 0.45, 0.45)
const LOCK_COLOR := Color(1.0, 0.85, 0.3, 0.95)

## Draw the selected weapons' range bands (set by the ShipHud in Combat mode).
var show_weapon_ranges := false


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
	var mouse := SpaceScale.to_world(get_global_mouse_position())
	var pixel := 1.0 / SpaceScale.world_zoom(self)
	var best: CombatHull = null
	var best_distance := INF
	for contact in manager.get_contacts(manager.player_faction, player.get_world_position()):
		var distance := mouse.distance_to(contact.get_world_position())
		if distance <= PICK_DISTANCE * pixel + contact.hit_radius and distance < best_distance:
			best_distance = distance
			best = contact
	return best


## The detected hostile munition nearest the mouse, within the pick distance, or null.
func munition_under_mouse() -> Munition:
	var manager := SpaceCombatManager.find(get_tree())
	if manager == null:
		return null
	var mouse := SpaceScale.to_world(get_global_mouse_position())
	var reach := PICK_DISTANCE / SpaceScale.world_zoom(self)
	var best: Munition = null
	for munition in manager.get_detected_munitions(manager.player_faction):
		var distance := mouse.distance_to(munition.get_world_position())
		if distance <= reach:
			reach = distance
			best = munition
	return best


func _draw() -> void:
	var manager := SpaceCombatManager.find(get_tree())
	if manager == null:
		return
	var player := manager.get_player_hull()
	if player == null or player.is_destroyed:
		return
	SpaceScale.begin_world_draw(self)
	var s := SpaceScale.world_pixel(self)
	var weapons := PlayerWeapons.find_on(player)
	if weapons:
		if show_weapon_ranges:
			for weapon in weapons.get_selected_weapons():
				_draw_range_bands(player.get_world_position(), weapon, s)
		for munition in weapons.munition_locks:
			if is_instance_valid(munition):
				_draw_munition_lock(munition, weapons.assess_munition(munition), s)
	var target := manager.selected_contact
	if is_instance_valid(target):
		_draw_target(player, target, weapons, s)


## Filled bands from the ship out to the weapon's reach, each edge ringed and labelled.
func _draw_range_bands(at: Vector2, weapon: WeaponMount, s: float) -> void:
	var bands := weapon.get_range_bands()
	for i in bands.size():
		var inner: float = bands[i].inner
		var outer: float = bands[i].outer
		if outer <= inner:
			continue
		# A thick arc along the middle of the band fills it.
		draw_arc(at, (inner + outer) * 0.5, 0.0, TAU, 128, BAND_COLORS[i % BAND_COLORS.size()], outer - inner)
		draw_arc(at, outer, 0.0, TAU, 128, BAND_EDGE_COLOR, 1.5 * s)
		# Labels sit on the ring, stepping round so neighbouring bands do not overlap.
		var on_ring := at + Vector2.from_angle(-PI * 0.5 + i * 0.3) * outer
		_label(on_ring + Vector2(6.0, -4.0) * s, "%s %d px" % [bands[i].label, roundi(outer)], BAND_EDGE_COLOR, s)


func _draw_munition_lock(munition: Munition, assessment: Dictionary, s: float) -> void:
	var at := munition.get_world_position()
	var r := 7.0 * s
	draw_polyline(PackedVector2Array([at + Vector2(r, 0), at + Vector2(0, r), at + Vector2(-r, 0), at + Vector2(0, -r),
		at + Vector2(r, 0)]), LOCK_COLOR, 1.5 * s)
	_label(at + Vector2(10.0, 12.0) * s, "PD lock  strike %d%%" % roundi(assessment.strike_chance * 100.0), LOCK_COLOR, s)


func _draw_target(player: CombatHull, target: CombatHull, weapons: PlayerWeapons, s: float) -> void:
	var from := player.get_world_position()
	var to := target.get_world_position()
	var weapon: WeaponMount = weapons.get_selected_weapon() if weapons else null
	var in_range := weapon == null or weapon.in_range(target)
	var color := TARGET_COLOR if in_range else OUT_OF_RANGE_COLOR
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
	SpaceScale.draw_label(self, at, text, color, s, FONT_SIZE, SpaceScale.world_transform(self))
