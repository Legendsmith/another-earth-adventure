class_name ShipHud
extends CanvasLayer
## The player's ship console: a mode panel beside the space view and a bar along the bottom.
## Navigation: flight readout, navigation computer and maneuver editing.
## Sensors: active/passive sensors, held contacts and ghosts of lost ones, with details on the selected contact.
## Combat: the hull's state, weapons, the selected contact and threats.
## Command: collecting planet rewards, the crew, and (later) crew expeditions.
##
## Input comes from G.U.I.D.E: the HUD context is always on, plus the context of the current mode. Direct control
## (Ctrl) swaps the mode context for the direct control one; editing a maneuver node adds the maneuver edit context.
## Keyboard input belongs to G.U.I.D.E, so only editable text fields may hold GUI focus (focus would otherwise use up
## Tab and other keys moving between controls).

signal mode_changed(mode: Mode)
signal direct_control_changed(active: bool)

enum Mode { NAVIGATION, SENSORS, COMBAT, COMMAND }

const HUD_CONTEXT: GUIDEMappingContext = preload("res://ui/guide/ship_hud.tres")
const DIRECT_CONTROL_CONTEXT: GUIDEMappingContext = preload("res://ui/guide/ship_direct_control.tres")
const MANEUVER_EDIT_CONTEXT: GUIDEMappingContext = preload("res://ui/guide/ship_maneuver_edit.tres")
const MODE_CONTEXTS := {
	Mode.NAVIGATION: preload("res://ui/guide/mode_navigation.tres"),
	Mode.SENSORS: preload("res://ui/guide/mode_sensors.tres"),
	Mode.COMBAT: preload("res://ui/guide/mode_combat.tres"),
}

const MODE_NAVIGATION_ACTION: GUIDEAction = preload("res://ui/guide/hud_mode_navigation.tres")
const MODE_SENSORS_ACTION: GUIDEAction = preload("res://ui/guide/hud_mode_sensors.tres")
const MODE_COMBAT_ACTION: GUIDEAction = preload("res://ui/guide/hud_mode_combat.tres")
const SHOW_COMMAND_ACTION: GUIDEAction = preload("res://ui/guide/hud_show_command.tres")
const DIRECT_CONTROL_ACTION: GUIDEAction = preload("res://ui/guide/direct_control.tres")
const CANCEL_ACTION: GUIDEAction = preload("res://ui/guide/cancel.tres")
const PAUSE_ACTION: GUIDEAction = preload("res://ui/guide/pause.tres")

@export var ship: Spaceship
@export var controller: PlayerShipController
@export var navigation_computer: NavigationComputer
@export var renderer: TrajectoryRenderer
@export var maneuvers: ManeuverPlanner
@export var maneuver_editor: ManeuverEditor
## Kept centred on the space view rather than on the whole screen.
@export var camera: SpaceCamera

var mode: Mode = Mode.NAVIGATION
## Flying the ship by hand: the direct control context replaces the mode's context.
var direct_control := false
## Paused by the player (P) to plan. Editing a maneuver node also pauses; the game runs when neither does.
var player_paused := false

## The primary mode to go back to when the command view is closed again.
var _last_primary_mode: Mode = Mode.NAVIGATION
## Actions held down when the contexts changed. They only count again once released, so the key that switched
## contexts does not also fire in the new ones (Ctrl both takes and releases direct control).
var _await_release: Array[GUIDEAction] = []
var _contexts_dirty := false
var _orbital_system: Node
## The fuel readout shows the fuel left as a percentage instead of the delta-v it is worth.
var _fuel_as_percent := false

@onready var _tabs: TabContainer = %HudTabContainer
@onready var _space_view: Control = %SpaceView
@onready var _velocity_display: LineEdit = %VelocityDisplay
@onready var _fuel_bar: ProgressBar = %FuelBar
@onready var _fuel_total: LineEdit = %FuelTotalDisplay
@onready var _fuel_unit: Label = %FuelUnitLabel
@onready var _pause_label: Label = %PauseLabel
@onready var _mode_buttons := {
	Mode.NAVIGATION: %NavigationModeButton as Button,
	Mode.SENSORS: %SensorsModeButton as Button,
	Mode.COMBAT: %CombatModeButtoin as Button,
	Mode.COMMAND: %CommandViewButton as Button,
}
@onready var _mode_panels := {
	Mode.NAVIGATION: %NavigationPanel as Control,
	Mode.SENSORS: %SensorsPanel as Control,
	Mode.COMBAT: %CombatPanel as Control,
	Mode.COMMAND: %CommandPanel as Control,
}


func _ready() -> void:
	_orbital_system = get_tree().get_first_node_in_group(Constants.ORBITAL_SYSTEM_GROUP)
	for m: Mode in _mode_buttons:
		(_mode_buttons[m] as Button).pressed.connect(set_mode.bind(m))
	for panel: Control in _mode_panels.values():
		panel.call(&"setup", self)
	%FuelBarButton.pressed.connect(_toggle_fuel_readout)
	MODE_NAVIGATION_ACTION.just_triggered.connect(set_mode.bind(Mode.NAVIGATION))
	MODE_SENSORS_ACTION.just_triggered.connect(set_mode.bind(Mode.SENSORS))
	MODE_COMBAT_ACTION.just_triggered.connect(set_mode.bind(Mode.COMBAT))
	SHOW_COMMAND_ACTION.just_triggered.connect(_on_show_command)
	DIRECT_CONTROL_ACTION.just_triggered.connect(_on_direct_control)
	CANCEL_ACTION.just_triggered.connect(_on_cancel)
	PAUSE_ACTION.just_triggered.connect(toggle_pause)
	if maneuver_editor:
		maneuver_editor.planning_changed.connect(_on_planning_changed)
	get_viewport().gui_focus_changed.connect(_on_gui_focus_changed)
	set_mode(mode)
	_refresh_contexts()
	_update_overlays()
	_apply_pause()


func _exit_tree() -> void:
	GUIDE.set_enabled_mapping_contexts([])


func _process(_delta: float) -> void:
	# Only once G.U.I.D.E has run with the new contexts does an action's state say whether its key is still down.
	if not _contexts_dirty:
		for action in _await_release.duplicate():
			if not action.is_triggered():
				_await_release.erase(action)
	_update_bar()


## Speed relative to the body the ship orbits, and fuel as a bar with the delta-v it is worth.
func _update_bar() -> void:
	if not is_instance_valid(ship) or _orbital_system == null or not _orbital_system.IsReady:
		return
	var velocity := ship.get_state_velocity()
	var body: int = _orbital_system.FindDominantBody(ship.get_state_position())
	if body >= 0:
		velocity -= _orbital_system.GetBodyVelocity(body, _orbital_system.SimTime)
	_velocity_display.text = "%.1f" % velocity.length()
	_fuel_bar.max_value = ship.fuel_capacity
	_fuel_bar.value = ship.fuel
	if _fuel_as_percent:
		_fuel_total.text = "%d" % roundi(100.0 * ship.fuel / maxf(ship.fuel_capacity, 1e-6))
	else:
		_fuel_total.text = "%.1f" % ship.get_delta_v_remaining(Spaceship.Drive.MAIN)


func _toggle_fuel_readout() -> void:
	_fuel_as_percent = not _fuel_as_percent
	_fuel_unit.text = "%" if _fuel_as_percent else "m/s ∆v"
	_update_bar()
	# Let the readout move with the new text width.
	_fuel_bar.call_deferred(&"_on_value_changed", _fuel_bar.value)


## Switches mode and shows its panel; `show_panel` false hides the sidebar instead.
func set_mode(new_mode: Mode, show_panel := true) -> void:
	if new_mode != Mode.COMMAND:
		_last_primary_mode = new_mode
	if new_mode != Mode.NAVIGATION and maneuver_editor:
		# Maneuvers are only edited in Navigation: put the edit widget away.
		maneuver_editor.deselect()
	var changed := new_mode != mode
	if not changed:		
		_tabs.visible = !_tabs.visible
	elif changed:
		mode = new_mode
		for m: Mode in _mode_buttons:
			(_mode_buttons[m] as Button).set_pressed_no_signal(m == mode)
		_tabs.visible = show_panel
		_tabs.current_tab = (_mode_panels[mode] as Control).get_index()
		_queue_refresh()
		_update_overlays()
		mode_changed.emit(mode)


## Shows the full crew manifest (from the Command view).
func show_crew_manifest() -> void:
	_tabs.current_tab = (%CrewManifest as Control).get_index()


func set_direct_control(active: bool) -> void:
	if active == direct_control:
		return
	direct_control = active
	if active and maneuver_editor:
		maneuver_editor.deselect()
	if controller:
		controller.direct_control = active
	_await_release.append_array([DIRECT_CONTROL_ACTION, CANCEL_ACTION])
	_queue_refresh()
	direct_control_changed.emit(active)


func _on_show_command() -> void:
	# The command key toggles the command view; closing it goes back to the last primary mode with the sidebar hidden.
	if mode == Mode.COMMAND:
		set_mode(_last_primary_mode, false)
	else:
		set_mode(Mode.COMMAND)


func _on_direct_control() -> void:
	if not _await_release.has(DIRECT_CONTROL_ACTION):
		set_direct_control(true)


func _on_cancel() -> void:
	if direct_control and not _await_release.has(CANCEL_ACTION):
		set_direct_control(false)


func _on_planning_changed(_planning: bool) -> void:
	_queue_refresh()
	# The editor pauses and resumes the game for planning; a pause the player asked for outlasts it.
	_apply_pause()


func toggle_pause() -> void:
	player_paused = not player_paused
	_apply_pause()


func _apply_pause() -> void:
	var planning := maneuver_editor != null and maneuver_editor.pause_while_planning and maneuver_editor.is_planning()
	get_tree().paused = player_paused or planning
	_pause_label.visible = get_tree().paused
	_pause_label.text = "PAUSED (P)" if player_paused else "PAUSED: planning"


## Range rings belong to their mode: sensor reach in Sensors, weapon bands in Combat.
func _update_overlays() -> void:
	var sensor_overlay := SensorOverlay.find(get_tree())
	if sensor_overlay:
		sensor_overlay.show_ranges = mode == Mode.SENSORS
	var combat_overlay := CombatOverlay.find(get_tree())
	if combat_overlay:
		combat_overlay.show_weapon_ranges = mode == Mode.COMBAT


func _on_gui_focus_changed(control: Control) -> void:
	if not _takes_text(control):
		control.release_focus.call_deferred()


static func _takes_text(control: Control) -> bool:
	if control is LineEdit:
		return (control as LineEdit).editable
	if control is TextEdit:
		return (control as TextEdit).editable
	return control is SpinBox


## Context changes wait for the end of the frame: actions signal from inside G.U.I.D.E's own update.
func _queue_refresh() -> void:
	if not _contexts_dirty:
		_contexts_dirty = true
		_refresh_contexts.call_deferred()


func _refresh_contexts() -> void:
	_contexts_dirty = false
	var contexts: Array[GUIDEMappingContext] = [HUD_CONTEXT]
	if direct_control:
		contexts.append(DIRECT_CONTROL_CONTEXT)
	elif MODE_CONTEXTS.has(mode):
		contexts.append(MODE_CONTEXTS[mode])
		if mode == Mode.NAVIGATION and maneuver_editor and maneuver_editor.is_planning():
			contexts.append(MANEUVER_EDIT_CONTEXT)
	GUIDE.set_enabled_mapping_contexts(contexts)


static func format_time(seconds: float) -> String:
	var s := maxi(roundi(seconds), 0)
	if s >= 3600:
		return "%d:%02d:%02d" % [s / 3600, s / 60 % 60, s % 60]
	return "%d:%02d" % [s / 60, s % 60]
