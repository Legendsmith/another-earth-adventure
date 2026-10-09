class_name SpaceCamera
extends Camera2D
## Follows a target and zooms with the mouse wheel across the whole system (ship scale to star system scale).

@export var target: Node2D
@export var min_zoom: float = 0.004
@export var max_zoom: float = 4.0
@export var zoom_step: float = 1.15
@export var zoom_smoothing: float = 12.0

## Screen offset of the view the target is kept in, from the centre of the screen (the console covers part of it).
var view_offset := Vector2.ZERO

var _target_zoom: float


func _ready() -> void:
	_target_zoom = zoom.x
	process_mode = Node.PROCESS_MODE_ALWAYS # Pan and zoom while paused for planning.


func _process(delta: float) -> void:
	if is_instance_valid(target):
		global_position = target.global_position - view_offset / zoom
	var z := lerpf(zoom.x, _target_zoom, 1.0 - exp(-zoom_smoothing * delta / maxf(Engine.time_scale, 1.0)))
	zoom = Vector2(z, z)


func _unhandled_input(event: InputEvent) -> void:
	var button := event as InputEventMouseButton
	if button and button.pressed:
		if button.button_index == MOUSE_BUTTON_WHEEL_UP:
			_target_zoom = clampf(_target_zoom * zoom_step, min_zoom, max_zoom)
		elif button.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_target_zoom = clampf(_target_zoom / zoom_step, min_zoom, max_zoom)
