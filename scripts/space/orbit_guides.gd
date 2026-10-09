@tool
class_name OrbitGuides
extends Node2D
## Draws reference orbits around the CelestialBody it is placed under: the low orbit band (the surface up to
## low_orbit_radius) and the geostationary orbit, whose radius follows from the body's Mu and its rotation period.

@export var low_orbit_radius: float = 36000.0:
	set(value):
		low_orbit_radius = value
		queue_redraw()
## Rotation period of the body (s): a geostationary orbit has the same period.
@export var rotation_period: float = 1800.0:
	set(value):
		rotation_period = value
		queue_redraw()
@export var low_orbit_color: Color = Color(0.35, 0.9, 0.6, 0.08)
@export var geostationary_color: Color = Color(0.5, 0.75, 1.0, 0.45)
@export var label_color: Color = Color(0.75, 0.85, 1.0, 0.8)

var _last_zoom := 0.0


func _process(_delta: float) -> void:
	var zoom := get_canvas_transform().get_scale().x
	if not is_equal_approx(zoom, _last_zoom):
		_last_zoom = zoom
		queue_redraw()


func get_body_mu() -> float:
	var body := get_parent()
	var mu: Variant = body.get(&"Mu") if body else null
	return mu if mu != null else 0.0


func get_body_radius() -> float:
	var body := get_parent()
	var radius: Variant = body.get(&"Radius") if body else null
	return radius if radius != null else 0.0


## Radius of the orbit whose period is the body's rotation period.
func get_geostationary_radius() -> float:
	var mu := get_body_mu()
	if mu <= 0.0 or rotation_period <= 0.0:
		return 0.0
	return pow(mu * rotation_period * rotation_period / (4.0 * PI * PI), 1.0 / 3.0)


func _draw() -> void:
	var screen := maxf(1.0, 1.0 / maxf(get_canvas_transform().get_scale().x, 1e-6))
	var surface := get_body_radius()
	if low_orbit_radius > surface:
		var mid := (low_orbit_radius + surface) * 0.5
		draw_arc(Vector2.ZERO, mid, 0.0, TAU, 256, low_orbit_color, low_orbit_radius - surface)
		draw_arc(Vector2.ZERO, low_orbit_radius, 0.0, TAU, 256, Color(low_orbit_color, 0.4), -1.0)
		_label(Vector2(0.0, -low_orbit_radius), "LOW ORBIT", screen)
	var geostationary := get_geostationary_radius()
	if geostationary > 0.0:
		draw_arc(Vector2.ZERO, geostationary, 0.0, TAU, 384, geostationary_color, -1.0)
		_label(Vector2(0.0, -geostationary), "GEOSTATIONARY ORBIT", screen)


## Text at a constant screen size, centred above `at`.
func _label(at: Vector2, text: String, screen: float) -> void:
	var font := ThemeDB.fallback_font
	var size := 14
	var width := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	draw_set_transform(at, 0.0, Vector2(screen, screen))
	draw_string(font, Vector2(-width * 0.5, -6.0), text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, label_color)
	draw_set_transform(Vector2.ZERO)
