class_name PlayerShipController
extends Node
## Player flight: maneuver nodes are the primary way to navigate (see ManeuverEditor); direct thrust and turning
## are an emergency override that aborts any burn in progress and disengages the autopilot. Also handles target
## selection, time warp and the autopilot toggle.

signal target_changed(body_index: int)

@export var navigator: OrbitalNavigator
@export var renderer: TrajectoryRenderer
@export var maneuvers: ManeuverPlanner

var ship: Spaceship
var target_index: int = -1
var orbital_system: Node


func _ready() -> void:
	ship = get_parent() as Spaceship
	orbital_system = get_tree().get_first_node_in_group(Constants.ORBITAL_SYSTEM_GROUP)
	if maneuvers and navigator:
		# Planning a maneuver by hand takes over from the autopilot.
		maneuvers.nodes_changed.connect(func() -> void:
			if not maneuvers.nodes.is_empty() and navigator.is_active():
				navigator.cancel())


func _physics_process(_delta: float) -> void:
	var thrust := Input.get_action_strength(&"ship_thrust")
	var turn := Input.get_axis(&"ship_rotate_left", &"ship_rotate_right")
	if thrust > 0.0 or turn != 0.0:
		# Emergency manual control overrides everything automatic.
		if navigator and navigator.is_active():
			navigator.cancel()
		if maneuvers:
			maneuvers.abort_current()
		if orbital_system.TimeWarp > 1:
			orbital_system.SetTimeWarpIndex(0)
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
		if maneuvers:
			maneuvers.clear()
		navigator.navigate_to(orbital_system.GetBody(target_index))
