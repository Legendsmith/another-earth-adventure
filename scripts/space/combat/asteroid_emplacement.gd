@tool
class_name AsteroidEmplacement
extends Node2D
## Space hazard: an asteroid hollowed out into a weapons emplacement. The rock itself is in plain sight, but the
## emplacement inside (its CombatHull child) runs cold and is only picked up by sensors at short range, or when its
## railgun fires. Place it as a child of a planet or moon so it moves with that body.

@export var rock_radius: float = 40.0:
	set(value):
		rock_radius = value
		_build_outline()
@export var rock_seed: int = 7:
	set(value):
		rock_seed = value
		_build_outline()
@export var rock_color: Color = Color(0.42, 0.38, 0.34)

var _outline := PackedVector2Array()


func _ready() -> void:
	_build_outline()


func _build_outline() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = rock_seed
	_outline.clear()
	var corners := 14
	for i in corners:
		var angle := TAU * i / corners
		_outline.append(Vector2.from_angle(angle) * rock_radius * rng.randf_range(0.7, 1.05))
	queue_redraw()


func _draw() -> void:
	if _outline.is_empty():
		return
	draw_colored_polygon(_outline, rock_color)
	var edge := _outline.duplicate()
	edge.append(_outline[0])
	draw_polyline(edge, rock_color.lightened(0.25), 1.5)
