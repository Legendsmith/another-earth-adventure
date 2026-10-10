class_name SpaceScale
## Space is simulated at two scales.
##
## The ORBITAL MAP holds every position and velocity: the planet, ships, hazards and munitions are physics bodies in
## map units, MAP_SCALE of a world pixel, so even the far side of geostationary orbit stays in the low thousands.
## Orbital tools (OrbitalSystem, planners, trajectories, maneuvers) work in map units.
##
## LOCAL SPACE is the full-scale frame around the player's ship, in world pixels. It owns the ship's facing (see
## Spaceship: attitude is not simulated on the map) and the thrust, whose velocity change moves the ship on the map
## scaled by MAP_SCALE. Gameplay reasons in world pixels (weapon ranges, sensor reach, hit radii, explosion sizes), so
## combat and sensor code reads positions through world accessors (CombatHull.get_world_position() and friends),
## which convert from the map.
##
## The space view shows either the map (zoomed out, no ship facing) or local space (a camera on the ship at world
## scale); `local_view` says which, so drawings can pick their detail.

## Map units per world pixel.
const MAP_SCALE := 0.01

## True while the space view shows local space rather than the orbital map.
static var local_view := false


static func to_map(world: Vector2) -> Vector2:
	return world * MAP_SCALE


static func to_world(map: Vector2) -> Vector2:
	return map / MAP_SCALE


static func points_to_world(points: PackedVector2Array) -> PackedVector2Array:
	var world := PackedVector2Array()
	world.resize(points.size())
	for i in points.size():
		world[i] = points[i] / MAP_SCALE
	return world


## Screen pixels per world pixel for a CanvasItem on the map.
static func world_zoom(item: CanvasItem) -> float:
	return item.get_canvas_transform().get_scale().x * MAP_SCALE


## Map units to draw per world pixel of size: sizes keep their true (world) size when zoomed in, and at least the same
## number of screen pixels when zoomed out.
static func draw_scale(item: CanvasItem) -> float:
	return maxf(MAP_SCALE, 1.0 / item.get_canvas_transform().get_scale().x)


## World pixels per screen pixel, at least 1: multiply sizes given in world pixels by this when drawing in world
## coordinates (after `begin_world_draw`).
static func world_pixel(item: CanvasItem) -> float:
	return maxf(1.0, 1.0 / maxf(world_zoom(item), 1e-9))


## Draw transform of `item` that takes world pixel coordinates (positions from the world accessors).
static func world_transform(item: CanvasItem) -> Transform2D:
	return item.get_global_transform().affine_inverse() * Transform2D.IDENTITY.scaled(Vector2.ONE * MAP_SCALE)


## Sets `item`'s draw transform so it draws in world pixel coordinates.
static func begin_world_draw(item: CanvasItem) -> void:
	item.draw_set_transform_matrix(world_transform(item))


## Draws `text` at a constant screen size at `at` (in the current draw coordinates, whose screen pixel is `pixel`
## units), with an outline. Fonts are always rasterised at `size`: scaling the font size with zoom instead creates
## a glyph cache per size, some thousands of pixels tall when zoomed out.
static func draw_label(item: CanvasItem, at: Vector2, text: String, color: Color, pixel: float, size: int = 12,
		base: Transform2D = Transform2D.IDENTITY) -> void:
	var font := ThemeDB.fallback_font
	item.draw_set_transform_matrix(base * Transform2D(0.0, Vector2.ONE * pixel, 0.0, at))
	item.draw_string_outline(font, Vector2.ZERO, text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, 3, Color(0, 0, 0, 0.7))
	item.draw_string(font, Vector2.ZERO, text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, color)
	item.draw_set_transform_matrix(base)
