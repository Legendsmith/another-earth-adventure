class_name Munition
extends RigidBody2D
## Base for anything fired in space combat. Munitions fly under the same point gravity as ships, crash into planets,
## and pass through ships physically: hits are decided by their own fuses (see closest_approach).

const GROUP := &"combat_munitions"
## Physics layer of munitions (layer 20): inside every gravity well's mask, outside every ship's mask.
const MUNITION_LAYER := 1 << 19
## Planets and moons (CelestialBody) are on the default layer 1.
const TERRAIN_MASK := 1

var faction: StringName
var munition_name: String = "Munition"
## Hull that fired this munition (never hit by it).
var launcher: CombatHull
var target: CombatHull
## Size seen by active sensors (see SensorSuite).
var cross_section: float = 0.05
## Seconds before the munition is lost (out of fuel and drifting).
var lifetime: float = 600.0

var _age := 0.0


func _init() -> void:
	collision_layer = MUNITION_LAYER
	collision_mask = TERRAIN_MASK
	gravity_scale = 1.0
	mass = 1.0
	linear_damp_mode = RigidBody2D.DAMP_MODE_REPLACE
	linear_damp = 0.0
	angular_damp_mode = RigidBody2D.DAMP_MODE_REPLACE
	angular_damp = 0.0
	lock_rotation = true
	can_sleep = false
	continuous_cd = RigidBody2D.CCD_MODE_CAST_SHAPE
	contact_monitor = true
	max_contacts_reported = 1
	var shape := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = 0.5
	shape.shape = circle
	add_child(shape)


func _ready() -> void:
	add_to_group(GROUP)
	body_entered.connect(_on_body_entered)


func _physics_process(delta: float) -> void:
	_age += delta
	if _age >= lifetime:
		expire()
		return
	queue_redraw()


## Signature seen by passive sensors (see SensorSuite).
func get_signature() -> float:
	return 0.0


func get_world_position() -> Vector2:
	return global_position


func has_valid_target() -> bool:
	return is_instance_valid(target) and not target.is_destroyed


## Removes the munition without effect.
func expire() -> void:
	queue_free()


## Damage the warhead carries: it sets how bright the explosion is to sensors.
func get_warhead_damage() -> float:
	return 0.0


## Explosion at the munition. A `final` one ends the munition, and with it any sensor track of it.
func spawn_explosion(radius: float, color: Color = Color(1.0, 0.75, 0.4), final: bool = true,
		damage: float = -1.0) -> void:
	CombatExplosion.spawn(get_parent(), global_position, radius, get_warhead_damage() if damage < 0.0 else damage,
		"%s detonation" % munition_name, self if final else null, color)


func _on_body_entered(_body: Node) -> void:
	spawn_explosion(6.0)
	expire()


## Smallest distance between two points moving apart at constant relative velocity `relative_velocity` over the next
## `duration` seconds, starting `relative_position` apart. Used by fuses so fast munitions cannot skip past a target
## between physics ticks.
static func closest_approach(relative_position: Vector2, relative_velocity: Vector2, duration: float) -> float:
	var speed_squared := relative_velocity.length_squared()
	var t := 0.0
	if speed_squared > 1e-9:
		t = clampf(-relative_position.dot(relative_velocity) / speed_squared, 0.0, duration)
	return (relative_position + relative_velocity * t).length()


## Scale that keeps a drawing the same size on screen when the camera zooms out.
func get_zoom_scale() -> float:
	return maxf(1.0, 1.0 / get_canvas_transform().get_scale().x)


## Spawns a munition into the world (the current scene, so it does not move with the launcher's parent).
static func launch(munition: Munition, from: Node, at: Vector2, velocity: Vector2) -> void:
	var world: Node = from.get_tree().current_scene if from.get_tree().current_scene else from.get_parent()
	munition.position = at
	munition.linear_velocity = velocity
	world.add_child(munition)
	munition.global_position = at
