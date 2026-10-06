class_name TrajectoryRenderer
extends Node2D
## Draws a ship's predicted path (KSP-style patched display) from the C# trajectory predictor.
## The part around the current body follows that body; encounters are drawn around a "ghost" of the
## encountered body at closest approach; apsides, burns, collisions and the closest approach to the
## selected target are marked.

@export var ship: Spaceship
## Optional: draws the autopilot's next planned burn.
@export var navigator: OrbitalNavigator
## Optional: the player's maneuver nodes. While any are planned, the current (coasting) trajectory stays visible
## and the planned trajectory is drawn on top of it from the first maneuver onward.
@export var maneuvers: ManeuverPlanner
## Celestial body to report the closest approach to (-1 = none).
@export var target_index: int = -1
## Real seconds between prediction refreshes.
@export var refresh_interval: float = 0.2
## Simulation seconds to predict ahead.
@export var prediction_time: float = 1200.0
## Stop drawing after this many laps around a body (0 = always use prediction_time).
@export var stop_after_orbits: float = 1.0

@export_group("Colors")
@export var path_color := Color(0.4, 0.85, 1.0, 0.9)
@export var encounter_color := Color(1.0, 0.75, 0.3, 0.9)
@export var ghost_color := Color(1.0, 0.75, 0.3, 0.35)
@export var marker_color := Color(1.0, 1.0, 1.0, 0.9)
@export var collision_color := Color(1.0, 0.3, 0.3)
@export var burn_color := Color(0.4, 1.0, 0.5)
## Trajectory after the player's planned maneuvers.
@export var planned_color := Color(1.0, 0.55, 0.85, 0.95)
## Planned trajectory inside another body's sphere (encounters).
@export var planned_encounter_color := Color(1.0, 0.4, 0.6, 0.95)

## Current trajectory: the ship coasting with no planned maneuvers.
var prediction: RefCounted
## Trajectory including the player's planned maneuvers (null when none are planned).
var planned_prediction: RefCounted
## Closest approach to the target along the planned trajectory if there is one, else the current one.
var closest_approach: Dictionary = {}

var _orbital_system: Node
var _segments: Array = []
var _events: Array = []
var _planned_segments: Array = []
var _planned_events: Array = []
var _pending := 0
var _last_request_ms := -100000
var _font: Font
var _offset := Vector2.ZERO


func _ready() -> void:
	_orbital_system = get_tree().get_first_node_in_group(Constants.ORBITAL_SYSTEM_GROUP)
	_font = ThemeDB.fallback_font
	top_level = true
	z_index = 10
	# Keep predicting and drawing while the simulation is paused for maneuver planning.
	process_mode = Node.PROCESS_MODE_ALWAYS
	if maneuvers:
		maneuvers.nodes_changed.connect(request_refresh)


## Re-predict as soon as the current request finishes (e.g. while a maneuver is being edited).
func request_refresh() -> void:
	_last_request_ms = -100000


func _physics_process(_delta: float) -> void:
	if not is_instance_valid(ship) or not _orbital_system or not _orbital_system.IsReady or _pending > 0:
		return
	if Time.get_ticks_msec() - _last_request_ms < refresh_interval * 1000.0:
		return
	_last_request_ms = Time.get_ticks_msec()
	var options := {
		"max_time": prediction_time,
		"stop_after_orbits": stop_after_orbits,
		"watch_body": target_index,
		"sample_every": 6,
	}
	# Both predictions start from the same ship state, so they line up exactly before the first maneuver.
	var start_position := ship.get_state_position()
	var start_velocity := ship.get_state_velocity()
	_pending = 1
	var burns := maneuvers.get_prediction_burns() if maneuvers else []
	if not burns.is_empty():
		_pending = 2
		var planned := options.duplicate()
		planned.burns = burns
		# Always show at least one orbit past the last maneuver.
		var last_time: float = burns.back().time - _orbital_system.SimTime
		planned.max_time = maxf(prediction_time, last_time + prediction_time)
		var planned_job: RefCounted = _orbital_system.PredictAsync(start_position, start_velocity, planned)
		planned_job.connect(&"Completed", _on_planned_prediction)
	elif planned_prediction:
		planned_prediction = null
		_planned_segments = []
		_planned_events = []
	var job: RefCounted = _orbital_system.PredictAsync(start_position, start_velocity, options)
	job.connect(&"Completed", _on_prediction)


func _on_prediction(result: RefCounted) -> void:
	_pending -= 1
	prediction = result
	_segments = result.BuildPathSegments()
	_events = result.GetEvents()
	_update_closest_approach()


func _on_planned_prediction(result: RefCounted) -> void:
	_pending -= 1
	if not maneuvers or maneuvers.nodes.is_empty():
		return # All maneuvers were removed while this was computing.
	planned_prediction = result
	_planned_segments = result.BuildPathSegments()
	_planned_events = result.GetEvents()
	_update_closest_approach()


func _update_closest_approach() -> void:
	if target_index < 0:
		closest_approach = {}
		return
	var source := planned_prediction if planned_prediction else prediction
	closest_approach = source.GetClosestApproach() if source else {}


## Simulation time from which the planned trajectory differs from the current one (INF when nothing is planned).
func planned_from() -> float:
	if not planned_prediction or not maneuvers or maneuvers.nodes.is_empty():
		return INF
	return maneuvers.get_burn_start(maneuvers.nodes[0])


## Segments used for picking and placing maneuver nodes: the planned path when there is one.
func _query_segments() -> Array:
	return _planned_segments if planned_prediction else _segments


func _process(_delta: float) -> void:
	queue_redraw()


func _segment_offset(segment: Dictionary) -> Vector2:
	if segment.follows_body:
		var body: Node2D = _orbital_system.GetBody(segment.body)
		if body:
			return body.global_position
	return segment.anchor


func _draw() -> void:
	if not prediction:
		return
	var pixel := 1.0 / get_canvas_transform().get_scale().x # one screen pixel in world units
	var from_time := planned_from()
	_draw_trajectory(_segments, _events, prediction.InitialBody, -INF, path_color, encounter_color, marker_color, pixel)
	if from_time < INF:
		_draw_trajectory(_planned_segments, _planned_events, planned_prediction.InitialBody, from_time,
			planned_color, planned_encounter_color, planned_color, pixel)
	_set_offset(Vector2.ZERO)
	_draw_planned_burn(pixel)


## Draws one prediction's path, ghosts and markers, skipping everything before `from_time`.
func _draw_trajectory(segments: Array, events: Array, initial_body: int, from_time: float, color: Color,
		other_color: Color, markers: Color, pixel: float) -> void:
	for segment: Dictionary in segments:
		var times: PackedFloat64Array = segment.times
		if times.is_empty() or times[times.size() - 1] < from_time:
			continue
		var points: PackedVector2Array = segment.points
		if times[0] < from_time:
			var first := times.bsearch(from_time)
			points = points.slice(maxi(first - 1, 0))
		_set_offset(_segment_offset(segment))
		if points.size() >= 2:
			draw_polyline(points, color if segment.body == initial_body else other_color, -1.0)
		if segment.ghost:
			var radius: float = _orbital_system.GetBodyRadius(segment.body)
			var ghost := Color(other_color, ghost_color.a)
			draw_arc(Vector2.ZERO, radius, 0.0, TAU, 48, ghost, -1.0)
			_draw_label(Vector2(radius, -radius), _orbital_system.GetBodyName(segment.body), ghost, pixel)

	for event: Dictionary in events:
		if event.time < from_time:
			continue
		var segment: Dictionary = segments[event.segment]
		_set_offset(_segment_offset(segment))
		var p: Vector2 = event.local_position
		match event.type:
			"periapsis":
				_draw_marker(p, markers, pixel)
				_draw_label(p, "Pe %d" % roundi(event.distance - _orbital_system.GetBodyRadius(event.body)), markers, pixel)
			"apoapsis":
				_draw_marker(p, markers, pixel)
				_draw_label(p, "Ap %d" % roundi(event.distance - _orbital_system.GetBodyRadius(event.body)), markers, pixel)
			"collision":
				_draw_marker(p, collision_color, pixel * 1.5)
				_draw_label(p, "IMPACT", collision_color, pixel)
			"closest_approach":
				_draw_marker(p, other_color, pixel)
				_draw_label(p, "CA %d" % roundi(event.distance), other_color, pixel)
			"sphere_enter", "sphere_exit":
				draw_circle(p, 3.0 * pixel, color_with_alpha(color, 0.6))


func _draw_planned_burn(pixel: float) -> void:
	if not navigator or not is_instance_valid(ship):
		return
	var burn := navigator.get_next_burn()
	if burn.is_empty() or not burn.get("resolved", false):
		return
	var dv: Vector2 = burn.delta_v
	var arrow := dv.normalized() * 40.0 * pixel
	draw_line(ship.global_position, ship.global_position + arrow, burn_color, -1.0)
	var eta: float = burn.time - _orbital_system.SimTime
	_draw_label(ship.global_position + arrow, "burn %.1f px/s in %ds" % [dv.length(), roundi(eta)], burn_color, pixel)


#region Path queries (used by the maneuver editor)

## World position on the displayed path at `time`, with the relative velocity and the frame body there.
## Returns {} when the time is not on the predicted path.
func path_state_at(time: float) -> Dictionary:
	for segment: Dictionary in _query_segments():
		var times: PackedFloat64Array = segment.times
		if times.is_empty() or time < times[0] or time > times[times.size() - 1]:
			continue
		var i := times.bsearch(time)
		i = clampi(i, 1, times.size() - 1)
		var span := times[i] - times[i - 1]
		var f := 0.0 if span <= 0.0 else clampf((time - times[i - 1]) / span, 0.0, 1.0)
		var points: PackedVector2Array = segment.points
		var velocities: PackedVector2Array = segment.velocities
		var rel := points[i - 1].lerp(points[i], f)
		return {
			"position": rel + _segment_offset(segment),
			"relative_position": rel,
			"relative_velocity": velocities[i - 1].lerp(velocities[i], f),
			"body": segment.body,
		}
	return {}


## Time of the displayed path point nearest to `world_point`, or -1 when none is within `max_distance`.
## Only times after `not_before` are considered.
func nearest_path_time(world_point: Vector2, max_distance: float, not_before: float = -INF) -> float:
	var best_time := -1.0
	var best := max_distance * max_distance
	for segment: Dictionary in _query_segments():
		var offset := _segment_offset(segment)
		var points: PackedVector2Array = segment.points
		var times: PackedFloat64Array = segment.times
		for i in range(1, points.size()):
			if times[i] < not_before:
				continue
			var a := points[i - 1] + offset
			var b := points[i] + offset
			var closest := Geometry2D.get_closest_point_to_segment(world_point, a, b)
			var d := closest.distance_squared_to(world_point)
			if d < best:
				best = d
				var ab := a.distance_to(b)
				var f := 0.0 if ab <= 0.0 else a.distance_to(closest) / ab
				best_time = maxf(lerpf(times[i - 1], times[i], f), not_before)
	return best_time

#endregion


func _draw_marker(p: Vector2, color: Color, pixel: float) -> void:
	draw_arc(p, 5.0 * pixel, 0.0, TAU, 12, color, -1.0)


func _set_offset(offset: Vector2) -> void:
	_offset = offset
	draw_set_transform(offset)


func _draw_label(p: Vector2, text: String, color: Color, pixel: float) -> void:
	# Scale the text transform so labels keep a constant screen size at any zoom.
	draw_set_transform(_offset + p, 0.0, Vector2.ONE * pixel)
	draw_string(_font, Vector2(7, -7), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, color)
	draw_set_transform(_offset)


static func color_with_alpha(color: Color, alpha: float) -> Color:
	return Color(color, alpha)
