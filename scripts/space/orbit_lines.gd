extends Node2D
## Draws the orbit of every celestial body around its parent's current position, plus sphere-of-influence rings.

@export var segments: int = 192
@export var alpha: float = 0.35

var _orbital_system: Node
var _orbits: Dictionary[int, PackedVector2Array] = {}


func _ready() -> void:
	z_index = -1
	_orbital_system = get_tree().get_first_node_in_group(Constants.ORBITAL_SYSTEM_GROUP)
	if _orbital_system:
		_orbital_system.connect(&"EphemerisRebuilt", _rebuild)
		if _orbital_system.IsReady:
			_rebuild()


func _rebuild() -> void:
	_orbits.clear()
	for i in _orbital_system.BodyCount:
		if _orbital_system.GetBodyParent(i) >= 0:
			_orbits[i] = _orbital_system.GetOrbitPolyline(i, segments)


func _process(_delta: float) -> void:
	queue_redraw()


func _draw() -> void:
	for i: int in _orbits:
		var parent: Node2D = _orbital_system.GetBody(_orbital_system.GetBodyParent(i))
		var body: Node2D = _orbital_system.GetBody(i)
		if not parent or not body:
			continue
		var color: Color = body.get(&"BodyColor")
		draw_set_transform(parent.global_position)
		draw_polyline(_orbits[i], Color(color, alpha), -1.0)
	draw_set_transform(Vector2.ZERO)
