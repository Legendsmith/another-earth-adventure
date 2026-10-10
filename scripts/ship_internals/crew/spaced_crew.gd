class_name SpacedCrew
extends RigidBody2D
## A crew member blown out of a hull breach, drifting in a space suit. Lives on the orbital map like munitions (map
## units, see SpaceScale), under the same gravity, and dies when the suit's air runs out or when it hits a planet.
## Its timer ticks once every `skip_frames + 1` physics frames.

signal died(spaced: SpacedCrew)

## Planets and moons (CelestialBody) are on the default layer 1.
const TERRAIN_MASK := 1

var member: CrewMember
## Seconds of air in the suit when spaced; -1 = indefinite.
var survival_time := -1.0
## Seconds of air left (INF when indefinite).
var time_left := INF
var is_dead := false
var skip_frames := 8
var tick_offset: int


func _init() -> void:
	collision_layer = 0
	collision_mask = TERRAIN_MASK
	gravity_scale = 1.0
	mass = 0.1
	linear_damp_mode = RigidBody2D.DAMP_MODE_REPLACE
	linear_damp = 0.0
	lock_rotation = true
	can_sleep = false
	contact_monitor = true
	max_contacts_reported = 1
	var shape := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = 0.5 * SpaceScale.MAP_SCALE
	shape.shape = circle
	add_child(shape)


func _ready() -> void:
	tick_offset = randi() % Engine.physics_ticks_per_second
	time_left = survival_time if survival_time >= 0.0 else INF
	body_entered.connect(func(_body: Node) -> void: die())


func get_display_name() -> String:
	return member.display_name if member else name


func get_world_position() -> Vector2:
	return SpaceScale.to_world(global_position)


func get_world_velocity() -> Vector2:
	return SpaceScale.to_world(linear_velocity)


func die() -> void:
	if is_dead:
		return
	is_dead = true
	died.emit(self)
	queue_free()


func _physics_process(_delta: float) -> void:
	if (Engine.get_physics_frames() + tick_offset) % (skip_frames + 1) != 0:
		return
	if not freeze:
		queue_redraw()
	if time_left == INF:
		return
	time_left -= (skip_frames + 1) / float(Engine.physics_ticks_per_second)
	if time_left <= 0.0:
		die()


func _draw() -> void:
	if freeze:
		return
	# A small suit beacon, the same size on screen at any zoom.
	var pixel := SpaceScale.draw_scale(self)
	var color := Color.from_string(member.color_hex, Color(0.9, 0.95, 1.0)) if member and member.color_hex \
		else Color(0.9, 0.95, 1.0)
	draw_circle(Vector2.ZERO, 1.5 * pixel, color)
	draw_arc(Vector2.ZERO, 3.0 * pixel, 0.0, TAU, 12, Color(color, 0.5), pixel)
