class_name TrajectoryRenderer
extends Node2D
## Draws a ship's predicted path (KSP-style patched display) from the C# trajectory predictor.
## The part around the current body follows that body; encounters are drawn around a "ghost" of the
## encountered body at closest approach; apsides, burns, collisions and the closest approach to the
## selected target are marked.

@export var ship: Spaceship
## Optional: draws the autopilot's next planned burn.
@export var navigator: OrbitalNavigator
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

var prediction: RefCounted
var closest_approach: Dictionary = {}

var _orbital_system: Node
var _segments: Array = []
var _events: Array = []
var _pending := false
var _last_request_ms := -100000
var _font: Font
var _offset := Vector2.ZERO


func _ready() -> void:
	_orbital_system = get_tree().get_first_node_in_group(Constants.ORBITAL_SYSTEM_GROUP)
	_font = ThemeDB.fallback_font
	top_level = true
	z_index = 10


func _physics_process(_delta: float) -> void:
	if not is_instance_valid(ship) or not _orbital_system or not _orbital_system.IsReady or _pending:
		return
	if Time.get_ticks_msec() - _last_request_ms < refresh_interval * 1000.0:
		return
	_pending = true
	_last_request_ms = Time.get_ticks_msec()
	var options := {
		"max_time": prediction_time,
		"stop_after_orbits": stop_after_orbits,
		"watch_body": target_index,
		"sample_every": 6,
	}
	var job: RefCounted = _orbital_system.PredictAsync(ship.global_position, ship.linear_velocity, options)
	job.connect(&"Completed", _on_prediction)


func _on_prediction(result: RefCounted) -> void:
	_pending = false
	prediction = result
	_segments = result.BuildPathSegments()
	_events = result.GetEvents()
	closest_approach = result.GetClosestApproach() if target_index >= 0 else {}


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

	for i in _segments.size():
		var segment: Dictionary = _segments[i]
		var offset := _segment_offset(segment)
		var color := path_color if segment.body == prediction.InitialBody else encounter_color
		_set_offset(offset)
		var points: PackedVector2Array = segment.points
		if points.size() >= 2:
			draw_polyline(points, color, -1.0)
		if segment.ghost:
			var radius: float = _orbital_system.GetBodyRadius(segment.body)
			draw_arc(Vector2.ZERO, radius, 0.0, TAU, 48, ghost_color, -1.0)
			_draw_label(Vector2(radius, -radius), _orbital_system.GetBodyName(segment.body), ghost_color, pixel)

	for event: Dictionary in _events:
		var segment: Dictionary = _segments[event.segment]
		_set_offset(_segment_offset(segment))
		var p: Vector2 = event.local_position
		match event.type:
			"periapsis":
				_draw_marker(p, marker_color, pixel)
				_draw_label(p, "Pe %d" % roundi(event.distance - _orbital_system.GetBodyRadius(event.body)), marker_color, pixel)
			"apoapsis":
				_draw_marker(p, marker_color, pixel)
				_draw_label(p, "Ap %d" % roundi(event.distance - _orbital_system.GetBodyRadius(event.body)), marker_color, pixel)
			"collision":
				_draw_marker(p, collision_color, pixel * 1.5)
				_draw_label(p, "IMPACT", collision_color, pixel)
			"closest_approach":
				_draw_marker(p, encounter_color, pixel)
				_draw_label(p, "CA %d" % roundi(event.distance), encounter_color, pixel)
			"sphere_enter", "sphere_exit":
				draw_circle(p, 3.0 * pixel, color_with_alpha(path_color, 0.6))

	_set_offset(Vector2.ZERO)
	_draw_planned_burn(pixel)


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
