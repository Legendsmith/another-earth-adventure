class_name PlayerShipController
extends Node
## Player flight: maneuver nodes are the primary way to navigate (see ManeuverEditor); direct thrust and turning
## are an emergency override that aborts any burn in progress. The navigation computer (N) plots a course to the
## selected target as maneuver nodes. Also handles target selection and time warp.

signal target_changed(body_index: int)

@export var navigation_computer: NavigationComputer
@export var renderer: TrajectoryRenderer
@export var maneuvers: ManeuverPlanner

var ship: Spaceship
var target_index: int = -1
var orbital_system: Node


func _ready() -> void:
	ship = get_parent() as Spaceship
	orbital_system = get_tree().get_first_node_in_group(Constants.ORBITAL_SYSTEM_GROUP)


func _physics_process(_delta: float) -> void:
	var thrust := Input.get_action_strength(&"ship_thrust")
	var turn := Input.get_axis(&"ship_rotate_left", &"ship_rotate_right")
	if thrust > 0.0 or turn != 0.0:
		# Emergency manual control overrides everything automatic.
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
		plot_course()
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


## Asks the navigation computer for a course to the selected target; the result replaces the maneuver nodes.
func plot_course() -> void:
	if not navigation_computer:
		return
	if target_index < 0:
		navigation_computer.status = "No course: select a target first (Tab)"
		return
	navigation_computer.plot_course(orbital_system.GetBody(target_index))
