class_name ArmorDisplay
extends Control
## Draws a hull's armor grid: one column per armor column, intact boxes from the outer layer (top) down. A hull with
## ShipInternals shows its armor surface instead (see ArmorSurfaceRect), scaled up with nearest-neighbour filtering.

const BOX := 9.0
const GAP := 2.0
## Screen pixels per armor column of an armor surface (shrunk to fit the width).
const SURFACE_PIXEL := 4.0

var hull: CombatHull


func _draw() -> void:
	if hull and hull.internals and hull.internals.armor:
		_draw_surface(hull.internals.armor)
		return
	if hull == null or hull.grid == null or hull.grid.layers == 0:
		custom_minimum_size.y = 0.0
		return
	var grid := hull.grid
	var box := minf(BOX, (size.x - GAP * grid.columns) / grid.columns)
	custom_minimum_size.y = grid.layers * (box + GAP) + 4.0
	var intact := hull.armor.color if hull.armor else Color.GRAY
	for column in grid.columns:
		for layer in grid.layers:
			# remaining[column] boxes are left, lost from the outside in: the top `layers - remaining` are gone.
			var lost := layer < grid.layers - grid.remaining[column]
			var rect := Rect2(column * (box + GAP), layer * (box + GAP), box, box)
			if lost:
				draw_rect(rect, Color(1.0, 0.4, 0.3, 0.6), false, 1.0)
			else:
				draw_rect(rect, intact)


func _draw_surface(surface: HullArmorSurface) -> void:
	var pixel := minf(SURFACE_PIXEL, size.x / surface.width)
	custom_minimum_size.y = surface.height * pixel + 4.0
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	draw_texture_rect(surface.texture, Rect2(0.0, 0.0, surface.width * pixel, surface.height * pixel), false)
