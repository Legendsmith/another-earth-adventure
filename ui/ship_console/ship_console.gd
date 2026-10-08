class_name ShipConsole
extends CanvasLayer
## The player's ship console: one panel with three modes.
## Navigation: flight readout and navigation computer controls.
## Sensors: active/passive sensors, held contacts and ghosts of lost ones, with details on the selected contact.
## Command: collecting planet rewards, the crew, and (later) crew expeditions.
## Modes switch with the buttons along the top or 1 / 2 / 3.

enum Mode { NAVIGATION, SENSORS, COMMAND }

@export var ship: Spaceship
@export var controller: PlayerShipController
@export var navigation_computer: NavigationComputer
@export var renderer: TrajectoryRenderer
@export var maneuvers: ManeuverPlanner

var mode: Mode = Mode.NAVIGATION

@onready var _panel: PanelContainer = %Panel
@onready var _mode_buttons: Array[Button] = [%NavigationButton, %SensorsButton, %CommandButton]
@onready var _mode_panels: Array[Control] = [%NavigationPanel, %SensorsPanel, %CommandPanel]


func _ready() -> void:
	for i in _mode_buttons.size():
		_mode_buttons[i].pressed.connect(set_mode.bind(i))
	for panel in _mode_panels:
		panel.call(&"setup", self)
	set_mode(mode)


func _process(_delta: float) -> void:
	# Shrink back to the content after a mode change or a shorter readout.
	_panel.reset_size()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"console_navigation"):
		set_mode(Mode.NAVIGATION)
	elif event.is_action_pressed(&"console_sensors"):
		set_mode(Mode.SENSORS)
	elif event.is_action_pressed(&"console_command"):
		set_mode(Mode.COMMAND)
	else:
		return
	get_viewport().set_input_as_handled()


func set_mode(new_mode: Mode) -> void:
	mode = new_mode
	for i in _mode_panels.size():
		_mode_panels[i].visible = i == mode
		_mode_buttons[i].set_pressed_no_signal(i == mode)


static func format_time(seconds: float) -> String:
	var s := maxi(roundi(seconds), 0)
	if s >= 3600:
		return "%d:%02d:%02d" % [s / 3600, s / 60 % 60, s % 60]
	return "%d:%02d" % [s / 60, s % 60]
