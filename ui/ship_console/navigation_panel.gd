extends VBoxContainer
## Navigation mode of the ShipConsole: clock and warp, fuel, current orbit, target encounter, next maneuver and the
## navigation computer, with buttons for the flight keys.

var console: ShipConsole
var _orbital_system: Node

@onready var _readout: Label = %Readout


func setup(owner_console: ShipConsole) -> void:
	console = owner_console
	_orbital_system = get_tree().get_first_node_in_group(Constants.ORBITAL_SYSTEM_GROUP)
	%NextTargetButton.pressed.connect(func() -> void:
		if console.controller:
			console.controller.cycle_target())
	%PlotCourseButton.pressed.connect(func() -> void:
		if console.controller:
			console.controller.plot_course())
	%NavModeButton.pressed.connect(func() -> void:
		if console.navigation_computer:
			console.navigation_computer.cycle_mode())
	%NavEnginesButton.pressed.connect(func() -> void:
		if console.navigation_computer:
			console.navigation_computer.cycle_engine_use())
	%WarpDownButton.pressed.connect(func() -> void:
		if _orbital_system:
			_orbital_system.DecreaseTimeWarp())
	%WarpUpButton.pressed.connect(func() -> void:
		if _orbital_system:
			_orbital_system.IncreaseTimeWarp())


func _process(_delta: float) -> void:
	if not is_visible_in_tree() or console == null:
		return
	var ship := console.ship
	if not is_instance_valid(ship) or _orbital_system == null or not _orbital_system.IsReady:
		_readout.text = "No ship"
		return
	var lines: PackedStringArray = []
	var clock := "T+%s   warp x%d" % [ShipConsole.format_time(_orbital_system.SimTime), _orbital_system.TimeWarp]
	if _orbital_system.IsWarpCapped:
		clock += " (max x%d, burn ahead)" % _orbital_system.WarpLevels[_orbital_system.WarpCapIndex]
	if get_tree().paused:
		clock += "   PAUSED (planning: Esc or click empty space to resume)"
	lines.append(clock)
	lines.append("Fuel %.2f / %.2f   Δv left %.1f px/s (thrusters %.1f)" % [ship.fuel, ship.fuel_capacity,
		ship.get_delta_v_remaining(Spaceship.Drive.MAIN), ship.get_delta_v_remaining(Spaceship.Drive.THRUSTERS)])
	lines.append("Engines: %s / %s" % [ship.main_engine.name if ship.main_engine else "none",
		ship.thrusters.name if ship.thrusters else "none"])

	var body: int = _orbital_system.FindDominantBody(ship.get_state_position())
	if body >= 0:
		var info: Dictionary = _orbital_system.GetOrbitInfo(ship.get_state_position(), ship.get_state_velocity(), body)
		var radius: float = _orbital_system.GetBodyRadius(body)
		var apo := "escape" if not info.bound else "%d" % roundi(info.apoapsis - radius)
		lines.append("Orbiting %s   Pe %d  Ap %s  (altitude)" % [_orbital_system.GetBodyName(body),
			roundi(info.periapsis - radius), apo])

	var target := console.controller.target_index if console.controller else -1
	if target >= 0:
		var line := "Target %s" % _orbital_system.GetBodyName(target)
		var renderer := console.renderer
		if renderer and renderer.closest_approach.get("found", false):
			var ca := renderer.closest_approach
			line += "   closest approach %d px in %s" % [roundi(ca.distance),
				ShipConsole.format_time(ca.time - _orbital_system.SimTime)]
		lines.append(line)
	else:
		lines.append("No target")

	var maneuvers := console.maneuvers
	if maneuvers and not maneuvers.nodes.is_empty():
		var node: Dictionary = maneuvers.nodes[0]
		var status := "executing" if maneuvers.is_executing(node) \
			else "in %s" % ShipConsole.format_time(maneuvers.get_burn_start(node) - _orbital_system.SimTime)
		var how: String = "translate" if maneuvers.is_translation(node) else Spaceship.DRIVE_NAMES[maneuvers.get_drive(node)]
		lines.append("Maneuver %s (%s): Δv %.2f (total %.2f over %d)" % [status, how, maneuvers.get_delta_v(node),
			maneuvers.get_total_delta_v(), maneuvers.nodes.size()])

	var computer := console.navigation_computer
	if computer:
		var parked := "   [parked]" if ship.is_parked() else ""
		lines.append("Nav computer [%s, %s]: %s%s" % [NavigationComputer.MODE_NAMES[computer.mode],
			NavigationComputer.ENGINE_USE_NAMES[computer.engine_use], computer.status, parked])
	_readout.text = "\n".join(lines)
