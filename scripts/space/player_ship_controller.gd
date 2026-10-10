class_name PlayerShipController
extends Node
## Player flight: maneuver nodes are the primary way to navigate (see ManeuverEditor); direct control (the ShipHud
## turns it on) flies the ship by hand (W thrust, A/D turn, Shift+A/D strafe on the thrusters) and aborts any burn in
## progress. In combat mode, holding right-click translates toward the mouse on the thrusters without turning and
## Shift+right-click turns the ship to face it. The navigation computer plots a course to the selected target as
## maneuver nodes. Also handles target selection, time warp and the active sensors switch.

signal target_changed(body_index: int)

const MANEUVER_EDIT_CONTEXT: GUIDEMappingContext = preload("res://ui/guide/ship_maneuver_edit.tres")
const NEXT_DESTINATION_ACTION: GUIDEAction = preload("res://ui/guide/nav_next_destination.tres")
const CYCLE_ENGINE_ACTION: GUIDEAction = preload("res://ui/guide/nav_cycle_engine.tres")
const TOGGLE_ACTIVE_SENSORS_ACTION: GUIDEAction = preload("res://ui/guide/sensors_toggle_active.tres")
const COMBAT_CONTEXT: GUIDEMappingContext = preload("res://ui/guide/mode_combat.tres")
const MOVE_TO_ACTION: GUIDEAction = preload("res://ui/guide/combat_move_to.tres")
const MOVE_TURN_ACTION: GUIDEAction = preload("res://ui/guide/combat_move_turn.tres")
const COMBAT_SHIFT_ACTION: GUIDEAction = preload("res://ui/guide/combat_shift.tres")
## Heading error (radians) and turn rate (radians/s) below which a combat turn counts as done.
const TURN_DONE_ANGLE := 0.01
const TURN_DONE_RATE := 0.02

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
## Heading being turned to by a combat turn (Shift+right-click) until the ship settles on it; zero when none.
var _combat_heading := Vector2.ZERO


func _ready() -> void:
	ship = get_parent() as Spaceship
	ship.add_to_group(Constants.PLAYER_GROUP) # Planets look for the player's ship in their low orbit.
	orbital_system = get_tree().get_first_node_in_group(Constants.ORBITAL_SYSTEM_GROUP)
	timewarp_action.just_triggered.connect(_on_timewarp)
	NEXT_DESTINATION_ACTION.just_triggered.connect(cycle_target)
	CYCLE_ENGINE_ACTION.just_triggered.connect(_on_cycle_engine)
	TOGGLE_ACTIVE_SENSORS_ACTION.just_triggered.connect(toggle_active_sensors)
	MOVE_TURN_ACTION.just_triggered.connect(_on_move_turn)


func _physics_process(_delta: float) -> void:
	var thrust := 0.0
	var turn := 0.0
	var strafe := 0.0
	if direct_control:
		# ship_move is ship-relative and screen-like: up (negative y) is along the nose, x is to the right of it.
		# The main drive only thrusts forward; sideways is a translation on the thrusters.
		var move := move_action.value_axis_2d
		thrust = clampf(-move.y, 0.0, 1.0)
		strafe = clampf(move.x, -1.0, 1.0)
		turn = clampf(rotate_action.value_axis_1d, -1.0, 1.0)
	# Right of the nose: the nose rotated a quarter turn clockwise (y is down).
	var push := Vector2.from_angle(ship.facing + PI / 2.0) * strafe
	var combat_move := _combat_move_direction()
	if combat_move != Vector2.ZERO:
		push = combat_move
	if thrust > 0.0 or turn != 0.0 or push != Vector2.ZERO:
		# Manual control overrides everything automatic.
		if maneuvers:
			maneuvers.abort_current()
		if orbital_system.TimeWarp > 1:
			orbital_system.SetTimeWarpIndex(0)
	ship.throttle = thrust
	ship.steer = turn
	ship.manual_translation = push
	if turn != 0.0:
		_end_heading_turn()
	elif _combat_heading != Vector2.ZERO:
		var nose := ship.get_nose()
		if ship.get_held_heading() != _combat_heading:
			_combat_heading = Vector2.ZERO # Something else (a maneuver) took the heading over.
		elif absf(nose.angle_to(_combat_heading)) < TURN_DONE_ANGLE and absf(ship.spin) < TURN_DONE_RATE:
			_end_heading_turn()


## Combat move: while right-click is held the thrusters push toward the mouse, without turning.
func _combat_move_direction() -> Vector2:
	# Shift+right-click is the turn instead. Checking the context too ignores a state left over from a mode change.
	if direct_control or not GUIDE.is_mapping_context_enabled(COMBAT_CONTEXT) or not MOVE_TO_ACTION.is_triggered() \
			or COMBAT_SHIFT_ACTION.is_triggered():
		return Vector2.ZERO
	var offset := ship.get_global_mouse_position() - ship.global_position
	return offset.normalized() if offset.length_squared() > 1e-6 else Vector2.ZERO


## Combat turn: points the nose at the mouse and holds it there until the ship has settled.
func _on_move_turn() -> void:
	var offset := ship.get_global_mouse_position() - ship.global_position
	if offset == Vector2.ZERO:
		return
	# A held right-click push carries on while turning: it does not care where the nose points.
	if maneuvers:
		maneuvers.abort_current()
	ship.hold_heading(offset)
	_combat_heading = ship.get_held_heading()


func _end_heading_turn() -> void:
	if _combat_heading != Vector2.ZERO:
		if ship.get_held_heading() == _combat_heading:
			ship.release_heading()
		_combat_heading = Vector2.ZERO


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
