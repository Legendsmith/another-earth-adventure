@tool
class_name OrbitAnchor
extends Node2D
## Carries its children around a circular orbit of the CelestialBody it is placed under (its parent), so hazards that
## are not physics bodies (debris fields, asteroid emplacements) orbit the way ships do. The orbit's radius and
## starting angle come from where the anchor is placed; it moves at circular speed, prograde (clockwise on screen)
## unless retrograde.

@export var retrograde: bool = false
## Draw the orbit in the editor.
@export var show_orbit_in_editor: bool = true

var _orbital_system: Node
var _radius := 0.0
var _angle0 := 0.0
var _rate := 0.0


func _ready() -> void:
	if Engine.is_editor_hint():
		queue_redraw()
		return
	# Run after the OrbitalSystem has advanced the clock, before the hulls riding on the anchor measure their speed.
	process_physics_priority = -900
	_orbital_system = get_tree().get_first_node_in_group(Constants.ORBITAL_SYSTEM_GROUP)
	_radius = position.length()
	_angle0 = position.angle()
	var body := get_parent()
	var mu: float = body.get(&"Mu") if body and body.get(&"Mu") != null else 0.0
	if mu > 0.0 and _radius > 0.0:
		_rate = sqrt(mu / pow(_radius, 3.0)) * (-1.0 if retrograde else 1.0)
	else:
		push_warning("%s: an OrbitAnchor must be the child of a CelestialBody, away from its centre" % name)


func _physics_process(_delta: float) -> void:
	if Engine.is_editor_hint() or _rate == 0.0:
		return
	var time: float = _orbital_system.SimTime if _orbital_system else Time.get_ticks_msec() / 1000.0
	position = Vector2.from_angle(_angle0 + _rate * time) * _radius


## Orbital velocity of the anchor relative to its body.
func get_orbit_velocity() -> Vector2:
	var angle := position.angle()
	return Vector2(-sin(angle), cos(angle)) * _rate * _radius


func _draw() -> void:
	if not Engine.is_editor_hint() or not show_orbit_in_editor:
		return
	var radius := position.length()
	draw_arc(-position, radius, 0.0, TAU, 256, Color(0.6, 0.8, 1.0, 0.3), 2.0)
	var tangent := Vector2(-position.y, position.x).normalized() * (-1.0 if retrograde else 1.0)
	draw_line(Vector2.ZERO, tangent * 600.0, Color(0.6, 0.8, 1.0, 0.6), 4.0)
