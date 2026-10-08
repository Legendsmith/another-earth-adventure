class_name SensorOverlay
extends Node2D
## World-space sensor plot for the player's side: designations on held contacts, the active sensor reach, and ghosts
## of lost contacts: last known position, projected position now (with a ring of growing uncertainty) and the
## projected course ahead.

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

var _network: SensorNetwork


func _ready() -> void:
	z_index = 10


func _process(_delta: float) -> void:
	queue_redraw()


func _draw() -> void:
	if _network == null:
		_network = SensorNetwork.find(get_tree())
		if _network == null:
			return
	var s := maxf(1.0, 1.0 / get_canvas_transform().get_scale().x)
	var now := _network.get_time()
	var player := _network.get_player_suite()
	if player and player.active:
		var reach := player.active_range_for(1.0)
		draw_arc(player.get_world_position(), reach, 0.0, TAU, 128, ACTIVE_RING_COLOR, 2.0 * s)
	for track in _network.get_tracks():
		if track.is_held():
			_draw_held(track, s)
		else:
			_draw_ghost(track, now, s)


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
	_label(projected + Vector2(10.0, -8.0) * s, "%s ghost (%s)" % [track.designation, status], color, s)
	if selected:
		_brackets(projected, 16.0 * s, color, s)


func _live_position(track: SensorTrack) -> Vector2:
	if track.has_target():
		return track.target.get_world_position()
	return track.last_position


func _label(at: Vector2, text: String, color: Color, s: float) -> void:
	var font := ThemeDB.fallback_font
	var size := roundi(FONT_SIZE * s)
	draw_string_outline(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, maxi(roundi(3.0 * s), 1), Color(0, 0, 0, 0.7))
	draw_string(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, color)


func _brackets(at: Vector2, b: float, color: Color, s: float) -> void:
	var l := b * 0.4
	for corner: Vector2 in [Vector2(1, 1), Vector2(-1, 1), Vector2(1, -1), Vector2(-1, -1)]:
		var c := at + corner * b
		draw_line(c, c - Vector2(corner.x * l, 0), color, 1.5 * s)
		draw_line(c, c - Vector2(0, corner.y * l), color, 1.5 * s)


static func _format_time(seconds: float) -> String:
	var t := maxi(roundi(seconds), 0)
	return "%d:%02d" % [t / 60, t % 60]
