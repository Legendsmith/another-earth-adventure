@tool
class_name SpaceBattlefield
extends Node2D
## Space hazard: the debris field of an old battle. Combat hulls crossing it are struck by debris at a rate that grows
## with their speed relative to the field, so the safe way through is slowly. Some wrecks still carry automated
## torpedo racks (the derelict faction, hostile to everyone) that wake when a ship comes within their weak sensors.
## Place it as a child of a planet or moon so the field moves with that body.

@export var display_name: String = "Old battlefield"
@export var radius: float = 250.0
## Debris strikes per px of hull width per px travelled through the field: strikes per second are
## debris_density * relative speed * hull width.
@export var debris_density: float = 0.0008
## Relative speed (px/s) that adds one point to each debris strike.
@export var damage_speed: float = 60.0
@export var wreck_count: int = 7
## Wrecks with a working torpedo rack.
@export var derelict_launchers: int = 2
@export var derelict_sensor_strength: float = 150.0
@export var derelict_armor: ArmorDefinition
@export var field_seed: int = 1337

var _wrecks: Array[Dictionary] = []
var _debris := PackedVector2Array()
var _last_position := Vector2.ZERO
var _velocity := Vector2.ZERO
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_build_layout()
	_last_position = global_position
	if Engine.is_editor_hint():
		return
	_rng.randomize()
	for i in mini(derelict_launchers, _wrecks.size()):
		_add_derelict(i, _wrecks[i].position)


func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint() or delta <= 0.0:
		return
	_velocity = (global_position - _last_position) / delta
	_last_position = global_position
	for node in get_tree().get_nodes_in_group(CombatHull.GROUP):
		var hull := node as CombatHull
		if hull == null or hull.is_destroyed or hull.faction == CombatHull.DERELICT_FACTION:
			continue
		if hull.get_world_position().distance_squared_to(global_position) > radius * radius:
			continue
		var speed := (hull.get_world_velocity() - _velocity).length()
		var strikes := debris_density * speed * hull.hit_radius * 2.0 * delta
		if _rng.randf() < strikes:
			hull.take_hit(1 + floori(speed / damage_speed), 0)


## Field velocity (the body it is attached to): ships matching it are safe from debris.
func get_field_velocity() -> Vector2:
	return _velocity


func _build_layout() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = field_seed
	_wrecks.clear()
	for i in wreck_count:
		var points := PackedVector2Array()
		var size := rng.randf_range(6.0, 16.0)
		var corners := rng.randi_range(5, 8)
		for c in corners:
			var angle := TAU * c / corners + rng.randf_range(-0.3, 0.3)
			points.append(Vector2.from_angle(angle) * size * rng.randf_range(0.35, 1.0) * Vector2(1.6, 0.7))
		_wrecks.append({
			"position": Vector2.from_angle(rng.randf() * TAU) * radius * sqrt(rng.randf()) * 0.85,
			"rotation": rng.randf() * TAU,
			"points": points,
		})
	_debris.clear()
	for i in 160:
		_debris.append(Vector2.from_angle(rng.randf() * TAU) * radius * sqrt(rng.randf()))


func _add_derelict(index: int, at: Vector2) -> void:
	var wreck := Node2D.new()
	wreck.name = "Derelict%d" % (index + 1)
	wreck.position = at
	add_child(wreck)
	var hull := CombatHull.new()
	hull.name = "CombatHull"
	hull.display_name = "Derelict weapons platform"
	hull.faction = CombatHull.DERELICT_FACTION
	hull.hide_host_when_undetected = false
	hull.armor = derelict_armor
	hull.armor_mass = 1.0
	hull.armor_columns = 8
	hull.components = [_component("Torpedo rack", ShipComponent.Kind.WEAPON, 2.0, 2),
		_component("Automated sensors", ShipComponent.Kind.SENSORS, 1.0, 1),
		_component("Torpedo magazine", ShipComponent.Kind.MAGAZINE, 1.0, 1),
		_component("Wreck structure", ShipComponent.Kind.STRUCTURE, 4.0, 4)]
	hull.hit_radius = 8.0
	var launcher := TorpedoLauncher.new()
	launcher.name = "TorpedoRack"
	launcher.magazine = 2
	launcher.reload_time = 30.0
	launcher.component_name = "Torpedo rack"
	launcher.damage = 12
	launcher.max_range = 2500.0
	hull.add_child(launcher)
	var ai := CombatAI.new()
	ai.name = "CombatAI"
	hull.add_child(ai)
	wreck.add_child(hull)
	var sensors := SensorSuite.new()
	sensors.name = "SensorSuite"
	sensors.display_name = hull.display_name
	sensors.classification = "Automated weapons platform"
	sensors.base_signature = 0.2
	sensors.passive_strength = derelict_sensor_strength
	sensors.active_strength = 0.0
	sensors.cross_section = 0.6
	wreck.add_child(sensors)


static func _component(component_name: String, kind: ShipComponent.Kind, size: float, hit_to_kill: int) -> ShipComponent:
	var component := ShipComponent.new()
	component.name = component_name
	component.kind = kind
	component.size = size
	component.hit_to_kill = hit_to_kill
	return component


func _draw() -> void:
	draw_arc(Vector2.ZERO, radius, 0.0, TAU, 64, Color(1.0, 0.7, 0.3, 0.25), 2.0)
	for point in _debris:
		draw_rect(Rect2(point - Vector2.ONE, Vector2(2, 2)), Color(0.7, 0.65, 0.6, 0.6))
	for wreck in _wrecks:
		draw_set_transform(wreck.position, wreck.rotation)
		draw_colored_polygon(wreck.points, Color(0.35, 0.33, 0.32))
		var outline: PackedVector2Array = wreck.points.duplicate()
		outline.append(wreck.points[0])
		draw_polyline(outline, Color(0.6, 0.5, 0.45), 1.0)
	draw_set_transform(Vector2.ZERO)
	var font := ThemeDB.fallback_font
	draw_string(font, Vector2(-radius, -radius - 8.0), display_name, HORIZONTAL_ALIGNMENT_LEFT, -1, 14,
		Color(1.0, 0.75, 0.45, 0.8))
