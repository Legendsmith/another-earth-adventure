class_name ManeuverEditor
extends Node2D
## Mouse editing of the player's maneuver nodes on the predicted path.
##
## - Click the orbital path to create a maneuver node there (and select it). Click and hold (on the path or on a node)
##   to pick the engines that fly it: Main drive, Thrusters or both; release over the choice. New nodes use the last
##   choice. A thrusters-only node with only radial/anti-radial delta-v is a translation: the ship does not turn.
## - Drag a handle (Prograde, Retrograde, Radial, Anti-radial) to add delta-v in that direction. The further
##   the handle is pulled, the faster delta-v changes; hold Shift for fine control. Pushing back reduces it.
##   Several handles can be used one after another to combine directions.
## - Drag the node itself to slide it along the path.
## - Right-click a node or its part of the planned trajectory, or press Delete, to remove it.
##
## While a node is selected the player is planning: the simulation is paused (if `pause_while_planning`).
## Deselecting (clicking empty space, Escape, or removing the node) leaves planning, deleting any empty nodes.

signal selection_changed(node: Dictionary)
signal planning_changed(planning: bool)

enum Handle { NONE = -1, PROGRADE, RETROGRADE, RADIAL, ANTI_RADIAL }

const HANDLE_NAMES := ["Prograde", "Retrograde", "Radial", "Anti-radial"]

@export var renderer: TrajectoryRenderer
@export var planner: ManeuverPlanner
## Screen distance from the node to its handles.
@export var handle_distance: float = 60.0
@export var handle_radius: float = 9.0
@export var node_radius: float = 7.0
## Screen distance within which a click picks the path.
@export var pick_distance: float = 10.0
## Delta-v change per real second at full pull (px/s per s).
@export var drag_rate: float = 6.0
## Screen pull (px) that gives the full rate.
@export var full_pull: float = 90.0
## New nodes must be at least this far ahead, in simulation seconds.
@export var min_lead_time: float = 3.0
## Pause the simulation while a maneuver node is selected for editing.
@export var pause_while_planning: bool = true
## Real seconds a click must be held on a node to open the engine picker.
@export var hold_time: float = 0.35
## Screen distance from the node to the engine picker's options.
@export var picker_distance: float = 55.0
## Engines used by new nodes (the last one picked).
@export var new_node_drive: Spaceship.Drive = Spaceship.Drive.MAIN

@export_group("Colors")
@export var prograde_color := Color(1.0, 0.85, 0.25)
@export var radial_color := Color(0.35, 0.85, 1.0)
@export var node_color := Color(0.4, 1.0, 0.5)
@export var executing_color := Color(1.0, 0.45, 0.3)

var selected: Dictionary = {}

var _orbital_system: Node
var _font: Font
var _drag_handle: int = Handle.NONE
var _dragging_node := false
# Engine picker: pending while the click is held still, open once held for hold_time.
var _pick_pending := false
var _pick_open := false
var _pick_elapsed := 0.0
var _pick_press_screen := Vector2.ZERO

const PICK_MOVE_TOLERANCE := 6.0
## Screen directions of the picker options, indexed by Spaceship.Drive.
const PICK_DIRECTIONS := [Vector2(0.0, -1.0), Vector2(-0.866, 0.5), Vector2(0.866, 0.5)]


func _ready() -> void:
	_orbital_system = get_tree().get_first_node_in_group(Constants.ORBITAL_SYSTEM_GROUP)
	_font = ThemeDB.fallback_font
	top_level = true
	z_index = 20
	# Editing must keep working while the tree is paused for planning.
	process_mode = Node.PROCESS_MODE_ALWAYS
	planner.nodes_changed.connect(_on_nodes_changed)


func _exit_tree() -> void:
	if is_planning() and pause_while_planning:
		get_tree().paused = false


func is_planning() -> bool:
	return not selected.is_empty()


func _on_nodes_changed() -> void:
	if not selected.is_empty() and not planner.nodes.any(func(n: Dictionary) -> bool: return is_same(n, selected)):
		_select({})


func _select(node: Dictionary) -> void:
	var was_planning := is_planning()
	selected = node
	_drag_handle = Handle.NONE
	_dragging_node = false
	_pick_pending = false
	_pick_open = false
	selection_changed.emit(node)
	if is_planning() != was_planning:
		if not is_planning():
			planner.remove_empty_nodes() # Leaving the planner: drop nodes that change nothing.
		if pause_while_planning:
			get_tree().paused = is_planning()
		planning_changed.emit(is_planning())


#region Geometry

func _pixel() -> float:
	return 1.0 / get_canvas_transform().get_scale().x


## {position, prograde, radial} of a node on the displayed path, or {} if it is off the path.
func _node_frame(node: Dictionary) -> Dictionary:
	var state := renderer.path_state_at(node.time)
	if state.is_empty():
		return {}
	var axes := ManeuverPlanner.orbital_axes(state.relative_position, state.relative_velocity)
	return {"position": state.position, "prograde": axes[0], "radial": axes[1]}


func _handle_direction(frame: Dictionary, handle: int) -> Vector2:
	match handle:
		Handle.PROGRADE: return frame.prograde
		Handle.RETROGRADE: return -frame.prograde
		Handle.RADIAL: return frame.radial
		_: return -frame.radial


func _handle_position(frame: Dictionary, handle: int) -> Vector2:
	return frame.position + _handle_direction(frame, handle) * handle_distance * _pixel()


func _node_at(world: Vector2) -> Dictionary:
	var reach := (node_radius + 4.0) * _pixel()
	for node in planner.nodes:
		var frame := _node_frame(node)
		if not frame.is_empty() and world.distance_to(frame.position) <= reach:
			return node
	return {}


func _handle_at(world: Vector2) -> int:
	if selected.is_empty():
		return Handle.NONE
	var frame := _node_frame(selected)
	if frame.is_empty():
		return Handle.NONE
	for handle in 4:
		if world.distance_to(_handle_position(frame, handle)) <= (handle_radius + 4.0) * _pixel():
			return handle
	return Handle.NONE

#endregion


#region Input

func _unhandled_input(event: InputEvent) -> void:
	if not _orbital_system or not _orbital_system.IsReady:
		return
	var button := event as InputEventMouseButton
	if button:
		var world := get_global_mouse_position()
		if button.button_index == MOUSE_BUTTON_LEFT:
			if button.pressed:
				_on_left_press(world)
			else:
				_on_left_release()
			get_viewport().set_input_as_handled()
		elif button.button_index == MOUSE_BUTTON_RIGHT and button.pressed:
			var node := _node_at(world)
			if node.is_empty():
				node = _maneuver_for_planned_path(world)
			if not node.is_empty():
				planner.remove_node(node)
				get_viewport().set_input_as_handled()
	elif event.is_action_pressed(&"maneuver_delete") and not selected.is_empty():
		planner.remove_node(selected)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed(&"ui_cancel") and is_planning():
		_select({})
		get_viewport().set_input_as_handled()


## The maneuver whose effect is drawn at `world` on the planned trajectory: the last node before that point.
func _maneuver_for_planned_path(world: Vector2) -> Dictionary:
	if not renderer.planned_prediction:
		return {}
	var time := renderer.nearest_path_time(world, pick_distance * _pixel(), renderer.planned_from())
	if time < 0.0:
		return {}
	var found: Dictionary = {}
	for node in planner.nodes:
		if planner.get_burn_start(node) <= time:
			found = node
	return found


func _on_left_press(world: Vector2) -> void:
	var handle := _handle_at(world)
	if handle != Handle.NONE:
		_drag_handle = handle
		return
	var node := _node_at(world)
	if not node.is_empty():
		_select(node)
		_dragging_node = not planner.is_executing(node)
		_start_pick()
		return
	var time := renderer.nearest_path_time(world, pick_distance * _pixel(), _orbital_system.SimTime + min_lead_time)
	if time >= 0.0:
		_select(planner.add_node(time, 0.0, 0.0, new_node_drive))
		_start_pick()
		return
	_select({})


func _on_left_release() -> void:
	if _pick_open:
		var drive := _hovered_drive()
		if drive >= 0 and drive != planner.get_drive(selected):
			selected.drive = drive
			new_node_drive = drive as Spaceship.Drive
			_take_over(selected)
			planner.node_edited(selected)
	_pick_pending = false
	_pick_open = false
	_drag_handle = Handle.NONE
	_dragging_node = false


func _start_pick() -> void:
	if planner.is_executing(selected):
		return
	_pick_pending = true
	_pick_open = false
	_pick_elapsed = 0.0
	_pick_press_screen = get_viewport().get_mouse_position()


## Picker option under the mouse (a Spaceship.Drive), or -1.
func _hovered_drive() -> int:
	var frame := _node_frame(selected)
	if frame.is_empty():
		return -1
	var offset: Vector2 = (get_global_mouse_position() - frame.position) / _pixel()
	if offset.length() < node_radius + 8.0:
		return -1
	var best := -1
	var best_dot := -INF
	for drive in PICK_DIRECTIONS.size():
		if not ship_has_drive(drive):
			continue
		var d: float = offset.normalized().dot(PICK_DIRECTIONS[drive])
		if d > best_dot:
			best_dot = d
			best = drive
	return best


func ship_has_drive(drive: int) -> bool:
	if drive == Spaceship.Drive.BOTH:
		return planner.ship.main_engine != null and planner.ship.thrusters != null
	return planner.ship.has_drive(drive)


func _process(delta: float) -> void:
	queue_redraw()
	if selected.is_empty() or planner.is_executing(selected):
		return
	var real_delta := delta / maxf(Engine.time_scale, 1e-6)
	var world := get_global_mouse_position()

	if _pick_pending:
		# Held still: open the engine picker. Moved: it is a drag instead.
		if get_viewport().get_mouse_position().distance_to(_pick_press_screen) > PICK_MOVE_TOLERANCE:
			_pick_pending = false
		else:
			_pick_elapsed += real_delta
			if _pick_elapsed >= hold_time:
				_pick_pending = false
				_pick_open = true
				_dragging_node = false
			return
	if _pick_open:
		return

	if _drag_handle != Handle.NONE:
		var frame := _node_frame(selected)
		if frame.is_empty():
			return
		var direction := _handle_direction(frame, _drag_handle)
		# Signed pull along the handle axis, in screen pixels, measured from the handle's rest position.
		var pull := (world - _handle_position(frame, _drag_handle)).dot(direction) / _pixel()
		var strength := clampf(pull / full_pull, -1.0, 1.0)
		var rate := signf(strength) * strength * strength * drag_rate
		if Input.is_key_pressed(KEY_SHIFT):
			rate *= 0.1
		var change := rate * real_delta
		match _drag_handle:
			Handle.PROGRADE: selected.prograde += change
			Handle.RETROGRADE: selected.prograde -= change
			Handle.RADIAL: selected.radial += change
			Handle.ANTI_RADIAL: selected.radial -= change
		_take_over(selected)
		planner.node_edited(selected)
	elif _dragging_node:
		var time := renderer.nearest_path_time(world, INF, _orbital_system.SimTime + min_lead_time)
		if time >= 0.0 and absf(time - selected.time) > 1e-3:
			selected.time = time
			_take_over(selected)
			planner.node_edited(selected)

## A node edited by hand belongs to the player: the navigation computer no longer maintains it.
func _take_over(node: Dictionary) -> void:
	node.erase("course")

#endregion


#region Drawing

func _draw() -> void:
	if not planner or not renderer.prediction:
		return
	var pixel := _pixel()
	var now: float = _orbital_system.SimTime
	for node in planner.nodes:
		var frame := _node_frame(node)
		if frame.is_empty():
			continue
		var executing := planner.is_executing(node)
		var color := executing_color if executing else node_color
		var p: Vector2 = frame.position
		if is_same(node, selected):
			draw_circle(p, node_radius * pixel, color)
		draw_arc(p, node_radius * pixel, 0.0, TAU, 20, color, 2.0 * pixel)
		var engines: String = "Thrusters (translate)" if planner.is_translation(node) 			else Spaceship.DRIVE_NAMES[planner.get_drive(node)]
		var lines := PackedStringArray([
			"Δv %.2f px/s" % planner.get_delta_v(node),
			engines,
			"T-%s   burn %.1fs" % [_format_time(node.time - now), planner.get_burn_duration(node)],
		])
		# Put the readout on a diagonal, between the handle axes, so it never sits under a handle.
		var diagonal: Vector2 = (frame.prograde + frame.radial).normalized()
		_draw_text(p + diagonal * (handle_distance * 0.8) * pixel, lines, color, pixel, diagonal.x < 0.0)
		if is_same(node, selected) and not executing:
			if _pick_open:
				_draw_picker(node, frame, pixel)
			else:
				_draw_handles(node, frame, pixel)


func _draw_picker(node: Dictionary, frame: Dictionary, pixel: float) -> void:
	var hovered := _hovered_drive()
	var current := planner.get_drive(node)
	for drive in PICK_DIRECTIONS.size():
		var available := ship_has_drive(drive)
		var at: Vector2 = frame.position + PICK_DIRECTIONS[drive] * picker_distance * pixel
		var color := node_color if drive == current else Color(0.85, 0.85, 0.85)
		if not available:
			color = Color(0.5, 0.5, 0.5, 0.5)
		draw_line(frame.position, at, Color(color, 0.4), 1.5 * pixel)
		if drive == hovered:
			draw_circle(at, handle_radius * 1.3 * pixel, Color(color, 0.35))
		draw_arc(at, handle_radius * pixel, 0.0, TAU, 20, color, 2.0 * pixel)
		var label: String = Spaceship.DRIVE_NAMES[drive]
		var direction: Vector2 = PICK_DIRECTIONS[drive]
		_draw_text(at + direction * (handle_radius + 6.0) * pixel, PackedStringArray([label]), color, pixel, direction.x < 0.0)


func _draw_handles(node: Dictionary, frame: Dictionary, pixel: float) -> void:
	for handle in 4:
		var color := prograde_color if handle <= Handle.RETROGRADE else radial_color
		var direction := _handle_direction(frame, handle)
		var rest := _handle_position(frame, handle)
		var at := rest
		if handle == _drag_handle:
			# Show the pull: the handle follows the mouse along its axis.
			at = rest + direction * (get_global_mouse_position() - rest).dot(direction)
			draw_line(rest, at, Color(color, 0.5), 2.0 * pixel)
		draw_line(frame.position + direction * node_radius * pixel, rest, Color(color, 0.6), 1.5 * pixel)
		var filled := handle == Handle.PROGRADE or handle == Handle.RADIAL
		if filled:
			draw_circle(at, handle_radius * pixel, color)
		else:
			draw_arc(at, handle_radius * pixel, 0.0, TAU, 20, color, 2.0 * pixel)
		# Arrowhead pointing along the handle direction.
		var tip := at + direction * handle_radius * 0.8 * pixel
		var side := Vector2(-direction.y, direction.x) * handle_radius * 0.5 * pixel
		var back := at - direction * handle_radius * 0.3 * pixel
		draw_colored_polygon(PackedVector2Array([tip, back + side, back - side]),
			Color(0.1, 0.1, 0.1) if filled else color)
		var value: float = node.prograde if handle <= Handle.RETROGRADE else node.radial
		var label: String = HANDLE_NAMES[handle]
		if (handle == Handle.PROGRADE and value > 0.0) or (handle == Handle.RETROGRADE and value < 0.0) \
				or (handle == Handle.RADIAL and value > 0.0) or (handle == Handle.ANTI_RADIAL and value < 0.0):
			label += " %.2f" % absf(value)
		_draw_text(at + direction * (handle_radius + 6.0) * pixel, PackedStringArray([label]), color, pixel, direction.x < 0.0)


## Draws lines of text at constant screen size; `right_aligned` makes the text end at `p` (for labels left of a point).
func _draw_text(p: Vector2, lines: PackedStringArray, color: Color, pixel: float, right_aligned := false) -> void:
	draw_set_transform(p, 0.0, Vector2.ONE * pixel)
	var top := -7.0 * lines.size()
	for i in lines.size():
		var x := -_font.get_string_size(lines[i], HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x if right_aligned else 0.0
		draw_string(_font, Vector2(x, top + 12 + 14 * i), lines[i], HORIZONTAL_ALIGNMENT_LEFT, -1, 12, color)
	draw_set_transform(Vector2.ZERO)


static func _format_time(seconds: float) -> String:
	var s := maxi(roundi(seconds), 0)
	return "%d:%02d" % [s / 60, s % 60]

#endregion
