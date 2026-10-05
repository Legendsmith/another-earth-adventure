class_name PlayerShipController
extends Node
## Manual flight controls for the parent Spaceship, target selection, time warp and the autopilot toggle.
## Any manual input disengages the autopilot.

signal target_changed(body_index: int)

@export var navigator: OrbitalNavigator
@export var renderer: TrajectoryRenderer

var ship: Spaceship
var target_index: int = -1
var orbital_system: Node


func _ready() -> void:
	ship = get_parent() as Spaceship
	orbital_system = get_tree().get_first_node_in_group(Constants.ORBITAL_SYSTEM_GROUP)


func _physics_process(_delta: float) -> void:
	var thrust := Input.get_action_strength(&"ship_thrust")
	var turn := Input.get_axis(&"ship_rotate_left", &"ship_rotate_right")
	if navigator and navigator.is_active() and (thrust > 0.0 or turn != 0.0):
		navigator.cancel()
	ship.throttle = thrust
	ship.steer = turn


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"time_warp_up"):
		orbital_system.IncreaseTimeWarp()
	elif event.is_action_pressed(&"time_warp_down"):
		orbital_system.DecreaseTimeWarp()
	elif event.is_action_pressed(&"cycle_target"):
		cycle_target()
	elif event.is_action_pressed(&"toggle_autopilot"):
		toggle_autopilot()
	else:
		return
	get_viewport().set_input_as_handled()


func cycle_target() -> void:
	var count: int = orbital_system.BodyCount
	if count == 0:
		return
	# Skip the root body (the star): there is nothing to travel to.
	target_index = wrapi(target_index + 1, -1, count)
	if target_index >= 0 and orbital_system.GetBodyParent(target_index) < 0:
		target_index = wrapi(target_index + 1, -1, count)
	if renderer:
		renderer.target_index = target_index
	target_changed.emit(target_index)


func toggle_autopilot() -> void:
	if not navigator:
		return
	if navigator.is_active():
		navigator.cancel()
		# Drop out of time warp when taking manual control.
		orbital_system.SetTimeWarpIndex(0)
	elif target_index >= 0:
		navigator.navigate_to(orbital_system.GetBody(target_index))
