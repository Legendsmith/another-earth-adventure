class_name DressingMinigame
extends Control
## Applying a wound dressing: circle the mouse around the limb (a cylinder) to wrap the bandage around it
## (Expedition Gameplay, Medical). Three wraps finish it; Medical skill makes each wrap count for more.
## The world keeps running meanwhile, so treating someone under fire is risky.

signal completed(quality: float)
signal cancelled

const WRAPS := 3.0

var part_label: String = ""
var skill_speed: float = 1.0
var progress: float = 0.0
var _last_angle: float = NAN
var _started: float = 0.0


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_started = Time.get_ticks_msec() / 1000.0


func _process(_delta: float) -> void:
	var center := size / 2.0
	var offset := get_local_mouse_position() - center
	if offset.length() > 40.0:
		var angle := offset.angle()
		if not is_nan(_last_angle):
			var step := wrapf(angle - _last_angle, -PI, PI)
			# Only one direction counts: a dressing is wrapped, not rubbed back and forth.
			if step > 0.0:
				progress += step / TAU * skill_speed
		_last_angle = angle
	queue_redraw()
	if progress >= WRAPS:
		var seconds := Time.get_ticks_msec() / 1000.0 - _started
		# A quick, clean wrap holds better.
		var quality := clampf(1.3 - seconds / 20.0, 0.7, 1.3)
		completed.emit(quality)
		queue_free()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT:
		cancelled.emit()
		queue_free()
		accept_event()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		cancelled.emit()
		queue_free()
		get_viewport().set_input_as_handled()


func _draw() -> void:
	var center := size / 2.0
	draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0, 0, 0.45))
	# The limb: a cylinder seen from the side.
	var body_rect := Rect2(center - Vector2(150, 60), Vector2(300, 120))
	draw_rect(body_rect, Color(0.85, 0.65, 0.55))
	draw_circle(Vector2(body_rect.position.x, center.y), 60, Color(0.75, 0.55, 0.47))
	draw_circle(Vector2(body_rect.end.x, center.y), 60, Color(0.9, 0.7, 0.6))
	# Bandage wraps so far.
	var wraps := int(progress * 6.0)
	for i: int in wraps:
		var x := body_rect.position.x + 30.0 + i * (240.0 / (WRAPS * 6.0))
		draw_line(Vector2(x, center.y - 62), Vector2(x + 18, center.y + 62), Color(0.95, 0.95, 0.92), 14.0)
	draw_arc(center, 180, 0, TAU, 64, Color(1, 1, 1, 0.25), 2.0)
	draw_arc(center, 180, -PI / 2.0, -PI / 2.0 + TAU * fmod(progress, 1.0), 64, Color(0.5, 1.0, 0.6), 6.0)
	var font := ThemeDB.fallback_font
	var text := "Dressing the %s: circle the mouse around it (%d/%d). Right click to stop." % [part_label,
		mini(int(progress), int(WRAPS)), int(WRAPS)]
	var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 20).x
	draw_string(font, center + Vector2(-w / 2.0, -210), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 20, Color.WHITE)
