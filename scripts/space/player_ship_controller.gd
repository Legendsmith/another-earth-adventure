class_name PlayerShipController
extends Node
## Player flight: maneuver nodes are the primary way to navigate (see ManeuverEditor); direct control (the ShipHud
## turns it on) flies the ship by hand and aborts any burn in progress. The navigation computer plots a course to the
## selected target as maneuver nodes. Also handles target selection, time warp and the active sensors switch.

signal target_changed(body_index: int)

const MANEUVER_EDIT_CONTEXT: GUIDEMappingContext = preload("res://ui/guide/ship_maneuver_edit.tres")
const NEXT_DESTINATION_ACTION: GUIDEAction = preload("res://ui/guide/nav_next_destination.tres")
const CYCLE_ENGINE_ACTION: GUIDEAction = preload("res://ui/guide/nav_cycle_engine.tres")
const TOGGLE_ACTIVE_SENSORS_ACTION: GUIDEAction = preload("res://ui/guide/sensors_toggle_active.tres")

@export var navigation_computer: NavigationComputer
@export var renderer: TrajectoryRenderer
@export var maneuvers: ManeuverPlanner
# Actions whose values are read are variables: GDScript would fold a constant's property at compile time.
@export var move_action: GUIDEAction = preload("res://ui/guide/ship_move.tres")
@export var rotate_action: GUIDEAction = preload("res://ui/guide/ship_rotate.tres")
@export var timewarp_action: GUIDEAction = preload("res://ui/guide/ship_timewarp.tres")

var ship: Spaceship
var target_index: int = -1
var orbital_system: Node
## Flying by hand: the ship_move and ship_rotate actions drive the ship.
var direct_control := false


func _ready() -> void:
	ship = get_parent() as Spaceship
	ship.add_to_group(Constants.PLAYER_GROUP) # Planets look for the player's ship in their low orbit.
	orbital_system = get_tree().get_first_node_in_group(Constants.ORBITAL_SYSTEM_GROUP)
	timewarp_action.just_triggered.connect(_on_timewarp)
	NEXT_DESTINATION_ACTION.just_triggered.connect(cycle_target)
	CYCLE_ENGINE_ACTION.just_triggered.connect(_on_cycle_engine)
	TOGGLE_ACTIVE_SENSORS_ACTION.just_triggered.connect(toggle_active_sensors)


func _physics_process(_delta: float) -> void:
	var thrust := 0.0
	var turn := 0.0
	if direct_control:
		# ship_move is screen-like: up (negative y) is along the nose. The ship only thrusts forward.
		thrust = clampf(-move_action.value_axis_2d.y, 0.0, 1.0)
		turn = clampf(rotate_action.value_axis_1d, -1.0, 1.0)
	if thrust > 0.0 or turn != 0.0:
		# Manual control overrides everything automatic.
		if maneuvers:
			maneuvers.abort_current()
		if orbital_system.TimeWarp > 1:
			orbital_system.SetTimeWarpIndex(0)
	ship.throttle = thrust
	ship.steer = turn


func _on_timewarp() -> void:
	if timewarp_action.value_axis_1d > 0.0:
		orbital_system.IncreaseTimeWarp()
	elif timewarp_action.value_axis_1d < 0.0:
		orbital_system.DecreaseTimeWarp()


func _on_cycle_engine() -> void:
	# While a maneuver node is being edited the same key picks that node's engines instead (ManeuverEditor).
	if navigation_computer and not GUIDE.is_mapping_context_enabled(MANEUVER_EDIT_CONTEXT):
		navigation_computer.cycle_engine_use()


func cycle_target() -> void:
	var count: int = orbital_system.BodyCount
	if count == 0:
		return
	# Every body is a valid target: the star or the planet being orbited can be chosen for Park.
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


## Switches the ship's active sensors on or off. Pinging holds contacts passive sensors miss, but lights the ship up.
func toggle_active_sensors() -> void:
	var suite := SensorSuite.find_on(ship)
	if suite:
		suite.active = not suite.active
