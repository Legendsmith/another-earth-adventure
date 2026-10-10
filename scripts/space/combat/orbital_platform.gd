class_name OrbitalPlatform
extends Spaceship
## An orbital weapons platform: a station with attitude thrusters only, which spawns on a circular orbit and parks
## there. Its weapons (usually a Railgun facing away from the planet) do the work.

@export var panel_color: Color = Color(0.35, 0.45, 0.75)


func _draw() -> void:
	if not SpaceScale.local_view:
		_draw_map_marker()
		return
	var s := hull_size * SpaceScale.draw_scale(self)
	# Solar wings along the orbit, the module across it: drawn relative to "up", away from the planet.
	var up := Vector2.UP
	if orbital_system and orbital_system.IsReady:
		var body: int = orbital_system.FindDominantBody(global_position)
		if body >= 0:
			up = (global_position - orbital_system.GetBodyPosition(body, orbital_system.SimTime)).normalized()
	draw_set_transform(Vector2.ZERO, up.angle() + PI * 0.5)
	draw_rect(Rect2(-s * 1.8, -s * 0.18, s * 1.2, s * 0.36), panel_color)
	draw_rect(Rect2(s * 0.6, -s * 0.18, s * 1.2, s * 0.36), panel_color)
	draw_rect(Rect2(-s * 0.6, -s * 0.05, s * 1.2, s * 0.1), hull_color.darkened(0.3))
	draw_rect(Rect2(-s * 0.45, -s * 0.45, s * 0.9, s * 0.9), hull_color)
	# Gun barrel housing on the top.
	draw_rect(Rect2(-s * 0.12, -s * 0.9, s * 0.24, s * 0.5), hull_color.lightened(0.2))
	draw_set_transform(Vector2.ZERO)
