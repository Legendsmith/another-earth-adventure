extends CanvasLayer
## Flight readout: clock, warp, fuel, current orbit, target encounter and autopilot status.

@export var ship: Spaceship
@export var controller: PlayerShipController
@export var navigator: OrbitalNavigator
@export var renderer: TrajectoryRenderer
@export var maneuvers: ManeuverPlanner

const STATE_NAMES := ["Off", "Planning", "Waiting for burn", "Burning", "Coasting", "Arrived", "Failed"]
const HELP := "Click path: add maneuver   Drag handles: plan burn   Drag node: move   Right-click/Del: remove\n" \
	+ "Tab target  N autopilot  , . time warp  Wheel zoom   Emergency: W thrust, A/D turn"

var _orbital_system: Node
var _label: Label
var _last_failure := ""


func _ready() -> void:
	_orbital_system = get_tree().get_first_node_in_group(Constants.ORBITAL_SYSTEM_GROUP)
	_label = Label.new()
	_label.position = Vector2(16, 16)
	_label.add_theme_color_override(&"font_shadow_color", Color.BLACK)
	add_child(_label)
	if navigator:
		navigator.navigation_failed.connect(func(reason: String) -> void: _last_failure = reason)


func _process(_delta: float) -> void:
	if not is_instance_valid(ship) or not _orbital_system.IsReady:
		return
	var lines: PackedStringArray = []
	lines.append("T+%s   warp x%d" % [_format_time(_orbital_system.SimTime), _orbital_system.TimeWarp])
	lines.append("Fuel %.2f / %.2f   Δv left %.1f px/s" % [ship.fuel, ship.fuel_capacity, ship.get_delta_v_remaining()])

	var body: int = _orbital_system.FindDominantBody(ship.global_position)
	if body >= 0:
		var info: Dictionary = _orbital_system.GetOrbitInfo(ship.global_position, ship.linear_velocity, body)
		var radius: float = _orbital_system.GetBodyRadius(body)
		var apo := "escape" if not info.bound else "%d" % roundi(info.apoapsis - radius)
		lines.append("Orbiting %s   Pe %d  Ap %s  (altitude)" % [_orbital_system.GetBodyName(body), roundi(info.periapsis - radius), apo])

	var target := controller.target_index if controller else -1
	if target >= 0:
		var line := "Target %s" % _orbital_system.GetBodyName(target)
		if renderer and renderer.closest_approach.get("found", false):
			var ca := renderer.closest_approach
			line += "   closest approach %d px in %s" % [roundi(ca.distance), _format_time(ca.time - _orbital_system.SimTime)]
		lines.append(line)
	else:
		lines.append("No target")

	if maneuvers and not maneuvers.nodes.is_empty():
		var node: Dictionary = maneuvers.nodes[0]
		var status := "executing" if maneuvers.is_executing(node) else "in %s" % _format_time(maneuvers.get_burn_start(node) - _orbital_system.SimTime)
		lines.append("Maneuver %s: Δv %.2f (total %.2f over %d)" % [status, maneuvers.get_delta_v(node),
			maneuvers.get_total_delta_v(), maneuvers.nodes.size()])

	if navigator:
		var line := "Autopilot: %s" % STATE_NAMES[navigator.state]
		if navigator.state == OrbitalNavigator.State.FAILED:
			line += " (%s)" % _last_failure
		if not navigator.plan.is_empty() and navigator.is_active():
			line += "   route: %s, est. Δv %.1f" % [navigator.plan.message, navigator.plan.estimated_delta_v]
			if navigator.plan.assist_body >= 0:
				line += " via %s" % _orbital_system.GetBodyName(navigator.plan.assist_body)
		lines.append(line)
	lines.append(HELP)
	_label.text = "\n".join(lines)


static func _format_time(seconds: float) -> String:
	var s := maxi(roundi(seconds), 0)
	return "%d:%02d" % [s / 60, s % 60]
