class_name Planet
extends Node2D
## A generated planet. Its rewards are collected by interacting with it while the player is in low orbit.

signal rewards_collected(planet:Planet, rewards:PlanetRewards)

## Low orbit reaches this many planet radii from the centre.
const LOW_ORBIT_FACTOR:float = 1.75

@export var data:PlanetData
var planet_type:PlanetType
var surface_texture:Texture2D

@onready var body:Node2D = %Body
@onready var surface:Sprite2D = %Surface
@onready var type_label:Label = %TypeLabel
@onready var low_orbit:Area2D = %LowOrbit
@onready var orbit_shape:CollisionShape2D = %OrbitShape

var _in_orbit:Array[Node2D] = []
var _hovered:bool = false


## Call before adding to the tree.
func setup(planet_data:PlanetData, generator:PlanetGenerator) -> void:
	data = planet_data
	planet_type = generator.get_type(data.kind)
	surface_texture = generator.make_surface(data)


func _ready() -> void:
	surface.texture = surface_texture
	body.draw.connect(_draw_mask)
	body.queue_redraw()
	type_label.text = planet_type.abbreviation if planet_type else ""
	type_label.position = Vector2(-type_label.size.x / 2.0, data.radius + 4.0)
	var orbit_circle := CircleShape2D.new()
	orbit_circle.radius = data.radius * LOW_ORBIT_FACTOR
	orbit_shape.shape = orbit_circle
	low_orbit.collision_mask = (1 << Constants.PLAYER_PHYSICS_LAYER) | Factions.faction_list[Constants.PLAYER_GROUP].physics_layer
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
		_update_cursor()


func _on_body_exited(node:Node2D) -> void:
	_in_orbit.erase(node)
	_update_cursor()


func _unhandled_input(event:InputEvent) -> void:
	if event is InputEventMouseMotion:
		var hovered:bool = get_local_mouse_position().length() <= data.radius
		if hovered != _hovered:
			_hovered = hovered
			if hovered:
				_update_cursor()
			else:
				Cursor.set_cursor(Cursor.Type.DEFAULT)
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT and _hovered:
		get_viewport().set_input_as_handled()
		on_interact()


## Only touches the cursor while hovered, so planets don't fight over it.
func _update_cursor() -> void:
	if not _hovered:
		return
	if can_collect():
		Cursor.set_cursor(Cursor.Type.INTERACT)
	else:
		Cursor.set_cursor(Cursor.Type.CANT_INTERACT)


func on_interact() -> void:
	if can_collect():
		collect_rewards()


func collect_rewards() -> PlanetRewards:
	data.collected = true
	rewards_collected.emit(self, data.rewards)
	_update_cursor()
	return data.rewards
