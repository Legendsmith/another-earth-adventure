class_name Planet
extends Node2D
## A generated planet surface and its rewards, usually attached to a CelestialBody.
## Rewards are collected with the interact action while the player's ship is in low orbit.

signal rewards_collected(planet:Planet, rewards:PlanetRewards)

const COLLECT_HINT:String = "E: Collect"
const COLLECTED_HINT:String = "Collected"

@export var data:PlanetData
## How far from the centre low orbit reaches.
@export var low_orbit_radius:float = 0.0
var planet_type:PlanetType
var surface_texture:Texture2D

@onready var body:Node2D = %Body
@onready var surface:Sprite2D = %Surface
@onready var type_label:Label = %TypeLabel
@onready var low_orbit:Area2D = %LowOrbit
@onready var orbit_shape:CollisionShape2D = %OrbitShape

var _in_orbit:Array[Node2D] = []


## Call before adding to the tree.
func setup(planet_data:PlanetData, generator:PlanetGenerator, orbit_radius:float) -> void:
	data = planet_data
	planet_type = generator.get_type(data.kind)
	surface_texture = generator.make_surface(data)
	low_orbit_radius = orbit_radius


func _ready() -> void:
	surface.texture = surface_texture
	body.draw.connect(_draw_mask)
	body.queue_redraw()
	type_label.position = Vector2(-type_label.size.x / 2.0, data.radius + 8.0)
	_update_label()
	var orbit_circle := CircleShape2D.new()
	orbit_circle.radius = low_orbit_radius
	orbit_shape.shape = orbit_circle
	low_orbit.body_entered.connect(_on_body_entered)
	low_orbit.body_exited.connect(_on_body_exited)


## The surface sprite is clipped to this circle.
func _draw_mask() -> void:
	body.draw_circle(Vector2.ZERO, data.radius, Color.WHITE)


func is_in_low_orbit() -> bool:
	return not _in_orbit.is_empty()


func can_collect() -> bool:
	return is_in_low_orbit() and not data.collected


func _on_body_entered(node:Node2D) -> void:
	if node.is_in_group(Constants.PLAYER_GROUP):
		_in_orbit.append(node)
		_update_label()


func _on_body_exited(node:Node2D) -> void:
	_in_orbit.erase(node)
	_update_label()


func _unhandled_input(event:InputEvent) -> void:
	if event.is_action_pressed(&"interact") and can_collect():
		get_viewport().set_input_as_handled()
		on_interact()


func _update_label() -> void:
	var abbreviation:String = planet_type.abbreviation if planet_type else ""
	if data.collected:
		type_label.text = "%s\n%s" % [abbreviation, COLLECTED_HINT]
	elif is_in_low_orbit():
		type_label.text = "%s\n%s" % [abbreviation, COLLECT_HINT]
	else:
		type_label.text = abbreviation


func on_interact() -> void:
	if can_collect():
		collect_rewards()


func collect_rewards() -> PlanetRewards:
	data.collected = true
	rewards_collected.emit(self, data.rewards)
	_update_label()
	return data.rewards
