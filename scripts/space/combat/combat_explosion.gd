class_name CombatExplosion
extends Node2D
## Expanding, fading ring for detonations and destroyed hulls. Frees itself.

@export var radius: float = 20.0
@export var duration: float = 1.0
@export var color: Color = Color(1.0, 0.75, 0.4)

var _age := 0.0


func _process(delta: float) -> void:
	_age += delta
	if _age >= duration:
		queue_free()
		return
	queue_redraw()


func _draw() -> void:
	var t := _age / duration
	var scale_factor := maxf(1.0, 1.0 / get_canvas_transform().get_scale().x)
	var r := radius * (0.3 + 0.7 * t) * scale_factor
	draw_circle(Vector2.ZERO, r * (1.0 - t), Color(1.0, 0.95, 0.8, 0.8 * (1.0 - t)))
	draw_arc(Vector2.ZERO, r, 0.0, TAU, 32, Color(color, 1.0 - t), 2.0 * scale_factor)
