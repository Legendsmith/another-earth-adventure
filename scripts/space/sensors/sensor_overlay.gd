class_name SensorOverlay
extends Node2D
## World-space sensor plot for the player's side: designations on held contacts, the active sensor reach, and ghosts
## of lost contacts: last known position, projected position now (with a ring of growing uncertainty) and the
## projected course ahead. With `show_ranges` (the Sensors view) it also rings the player's detection ranges and how
## far away the player's ship can itself be seen.

## Seconds of projected course drawn ahead of a ghost's projected position.
const FUTURE_WINDOW := 120.0
## A tick on the projected course this many seconds ahead.
const FUTURE_MARK := 60.0
## Uncertainty ring growth (px per second since the contact was lost): it may have burned since.
const UNCERTAINTY_RATE := 1.5
const FONT_SIZE := 12
const HELD_COLOR := Color(0.55, 0.95, 1.0, 0.9)
const HOSTILE_COLOR := Color(1.0, 0.45, 0.4, 0.95)
const UNKNOWN_COLOR := Color(1.0, 0.85, 0.45, 0.9)
const GHOST_COLOR := Color(0.7, 0.75, 0.85, 0.55)
const ACTIVE_RING_COLOR := Color(0.4, 0.9, 1.0, 0.18)
const EXPLOSION_COLOR := Color(1.0, 0.65, 0.3, 0.9)
const GROUP := &"sensor_overlay"
## Signatures the range rings are drawn for: a ship coasting quietly and one burning its drive.
const QUIET_SIGNATURE := 1.0
const BURNING_SIGNATURE := 40.0
## Passive sensor strength of a typical warship, for the "you can be seen at" ring.
const REFERENCE_SENSOR := 600.0
const PASSIVE_RING_COLOR := Color(0.55, 0.95, 1.0, 0.35)
const SEEN_RING_COLOR := Color(1.0, 0.45, 0.4, 0.4)
## Screen distance within which a click picks a contact.
const PICK_DISTANCE := 16.0

## Draw the detection range rings (set by the ShipHud in Sensors mode).
var show_ranges := false

var _network: SensorNetwork
# Labels drawn this frame, so the next one can step clear of them.
var _label_rects: Array[Rect2] = []


static func find(tree: SceneTree) -> SensorOverlay:
	return tree.get_first_node_in_group(GROUP) as SensorOverlay if tree else null


func _enter_tree() -> void:
	add_to_group(GROUP)


func _ready() -> void:
	z_index = 10


## The track drawn nearest the mouse, within the pick distance, or null.
func track_under_mouse() -> SensorTrack:
	if _network == null:
		return null
	var mouse := SpaceScale.to_world(get_global_mouse_position())
	var reach := PICK_DISTANCE / SpaceScale.world_zoom(self)
	var now := _network.get_time()
	var best: SensorTrack = null
	for track in _network.get_tracks():
		var distance := mouse.distance_to(plotted_position(track, now))
		if distance <= reach:
			reach = distance
			best = track
	return best


## Where a track is drawn: live for held contacts, the projection for ghosts, the flash for explosions.
func plotted_position(track: SensorTrack, now: float) -> Vector2:
	if track.is_explosion():
		return track.last_position
	if track.is_held():
		return _live_position(track)
	return track.get_position_at(now)


func _process(_delta: float) -> void:
	queue_redraw()


func _draw() -> void:
	if _network == null:
		_network = SensorNetwork.find(get_tree())
		if _network == null:
			return
	# Tracks are in world px: draw in world coordinates over the map (see SpaceScale).
	SpaceScale.begin_world_draw(self)
	var s := SpaceScale.world_pixel(self)
	_label_rects.clear()
	var now := _network.get_time()
	var player := _network.get_player_suite()
	if player and player.active:
		var reach := player.active_range_for(1.0)
		draw_arc(player.get_world_position(), reach, 0.0, TAU, 128, ACTIVE_RING_COLOR, 2.0 * s)
	if player and show_ranges:
		_draw_range_rings(player, s)
	for track in _network.get_tracks():
		if track.is_explosion():
			_draw_explosion(track, now, s)
		elif track.is_held():
			_draw_held(track, s)
		else:
			_draw_ghost(track, now, s)


## Passive reach against a quiet and a burning ship, active reach (dashed while off), and the range at which a warship's
## passive sensors pick the player up.
func _draw_range_rings(player: SensorSuite, s: float) -> void:
	var at := player.get_world_position()
	_range_ring(at, player.passive_range_for(QUIET_SIGNATURE), "Passive: quiet ship", PASSIVE_RING_COLOR, s, false, 0.0)
	_range_ring(at, player.passive_range_for(BURNING_SIGNATURE), "Passive: burning drive", PASSIVE_RING_COLOR, s, false, 0.0)
	if player.has_active_sensors():
		var active_reach := player.active_range_for(1.0) if player.active \
			else player.active_strength * player.get_condition()
		_range_ring(at, active_reach, "Active" if player.active else "Active (off)", Color(ACTIVE_RING_COLOR, 0.5), s,
			not player.active, PI * 0.25)
	_range_ring(at, REFERENCE_SENSOR * sqrt(player.get_signature()), "Warships see you", SEEN_RING_COLOR, s, true, PI)


## A range ring with its label on the ring at `label_angle` (0 is to the right, clockwise).
func _range_ring(at: Vector2, radius: float, label: String, color: Color, s: float, dashed: bool, label_angle: float) -> void:
	if radius <= 0.0:
		return
	if dashed:
		var segments := 96
		for i in segments:
			if i % 2 == 0:
				draw_arc(at, radius, TAU * i / segments, TAU * (i + 1) / segments, 4, color, 1.5 * s)
	else:
		draw_arc(at, radius, 0.0, TAU, 128, color, 1.5 * s)
	var on_ring := at + Vector2.from_angle(label_angle - PI * 0.5) * radius
	_label(on_ring + Vector2(6.0, -4.0) * s, "%s %d px" % [label, roundi(radius)], Color(color, 0.9), s)


static func color_for(track: SensorTrack, player_faction: StringName) -> Color:
	if track.is_ghost():
		return GHOST_COLOR
	if not track.identified:
		return UNKNOWN_COLOR
	return HOSTILE_COLOR if CombatHull.factions_hostile(track.get_faction(), player_faction) else HELD_COLOR


func _draw_held(track: SensorTrack, s: float) -> void:
	var at := _live_position(track)
	var color := color_for(track, _network.player_faction)
	var label := track.designation
	if track.identified:
		label += " " + track.get_display_name()
	if track.lock == SensorTrack.Lock.ACTIVE:
		label += " [A]"
	_label(at + Vector2(12.0, -10.0) * s, label, color, s)
	if track == _network.selected_track:
		_brackets(at, 16.0 * s, color, s)


func _draw_ghost(track: SensorTrack, now: float, s: float) -> void:
	var last := track.last_position
	var projected := track.get_position_at(now)
	var since := now - track.last_seen
	var selected := track == _network.selected_track
	var color := GHOST_COLOR
	if selected:
		color.a = 0.9
	# Last known position.
	draw_arc(last, 5.0 * s, 0.0, TAU, 16, color, 1.0 * s)
	draw_dashed_line(last, projected, color, 1.0 * s, 6.0 * s)
	# Projected now, with the area it could have reached by manoeuvring.
	var r := 4.0 * s
	draw_polyline(PackedVector2Array([projected + Vector2(r, 0), projected + Vector2(0, r), projected + Vector2(-r, 0),
		projected + Vector2(0, -r), projected + Vector2(r, 0)]), color, 1.0 * s)
	draw_arc(projected, maxf(since * UNCERTAINTY_RATE, 8.0 * s), 0.0, TAU, 48, Color(color, color.a * 0.5), 1.0 * s)
	# Projected course ahead.
	var ahead := track.get_path_between(now, now + FUTURE_WINDOW)
	if ahead.size() >= 2:
		draw_polyline(ahead, Color(color, color.a * 0.6), 1.0 * s)
		var mark := track.get_position_at(now + FUTURE_MARK)
		draw_circle(mark, 2.5 * s, color)
	var status := "lost %s ago" % _format_time(since)
	if track.is_projection_expired(now):
		status = "projection expired"
	if track.retained:
		status += ", kept"
	_label(projected + Vector2(10.0, -8.0) * s, "%s ghost (%s)" % [track.designation, status], color, s)
	if selected:
		_brackets(projected, 16.0 * s, color, s)


## Explosions sit where they flashed: a starburst, fading to the ghost colour once the flash is over.
func _draw_explosion(track: SensorTrack, now: float, s: float) -> void:
	var at := track.last_position
	var color := EXPLOSION_COLOR if track.is_held() else GHOST_COLOR
	if track == _network.selected_track:
		color.a = 0.95
		_brackets(at, 16.0 * s, color, s)
	for i in 8:
		var ray := Vector2.from_angle(i * TAU / 8.0)
		draw_line(at + ray * 3.0 * s, at + ray * (i % 2 + 1) * 5.0 * s, color, 1.0 * s)
	var label := "%s %s" % [track.designation, track.get_display_name()]
	if track.is_ghost():
		label += " (%s ago%s)" % [_format_time(now - track.last_seen), ", kept" if track.retained else ""]
	_label(at + Vector2(10.0, -8.0) * s, label, color, s)


func _live_position(track: SensorTrack) -> Vector2:
	if track.has_target():
		return track.target.get_world_position()
	return track.last_position


func _label(at: Vector2, text: String, color: Color, s: float) -> void:
	var font := ThemeDB.fallback_font
	var size := FONT_SIZE * s
	# Contacts lost at the same spot would print on top of each other: stack their labels instead.
	var line := size * 1.25
	var rect := Rect2(at - Vector2(0.0, size), Vector2(font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE).x * s, line))
	var moved := true
	while moved:
		moved = false
		for other in _label_rects:
			if other.intersects(rect):
				rect.position.y = other.end.y
				moved = true
	_label_rects.append(rect)
	at.y = rect.position.y + size
	SpaceScale.draw_label(self, at, text, color, s, FONT_SIZE, SpaceScale.world_transform(self))


func _brackets(at: Vector2, b: float, color: Color, s: float) -> void:
	var l := b * 0.4
	for corner: Vector2 in [Vector2(1, 1), Vector2(-1, 1), Vector2(1, -1), Vector2(-1, -1)]:
		var c := at + corner * b
		draw_line(c, c - Vector2(corner.x * l, 0), color, 1.5 * s)
		draw_line(c, c - Vector2(0, corner.y * l), color, 1.5 * s)


static func _format_time(seconds: float) -> String:
	var t := maxi(roundi(seconds), 0)
	return "%d:%02d" % [t / 60, t % 60]
