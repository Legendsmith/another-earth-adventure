class_name LootPile
extends Node2D
## Something to find on an expedition: a crate of resources, a ship module core, a data terminal with the locations
## of caches, or a locked prison cell.

enum Kind { RESOURCE, CORE, TERMINAL, CELL }

const COLORS := {"fuel": Color(0.95, 0.6, 0.2), "metal": Color(0.7, 0.75, 0.85), "supplies": Color(0.45, 0.85, 0.5)}

var kind: Kind = Kind.RESOURCE
## For resources: "fuel", "metal" or "supplies".
var resource: String = ""
var amount: float = 0.0
var used: bool = false
## For prison cells: the prisoners behind the door.
var prisoners: Array = []


func label() -> String:
	match kind:
		Kind.RESOURCE:
			return "%s x%.0f" % [resource.capitalize(), amount]
		Kind.CORE:
			return "Module core"
		Kind.TERMINAL:
			return "Data terminal" if not used else "Terminal (downloaded)"
		Kind.CELL:
			return "Prison cell (%d)" % prisoners.size() if not used else "Open cell"
	return ""


func weight() -> float:
	match kind:
		Kind.RESOURCE:
			return amount * ExpeditionActor.LOOT_WEIGHT
		Kind.CORE:
			return ExpeditionActor.CORE_WEIGHT
	return 0.0


func is_pickup() -> bool:
	return kind == Kind.RESOURCE or kind == Kind.CORE


func _draw() -> void:
	match kind:
		Kind.RESOURCE:
			var c: Color = COLORS.get(resource, Color.WHITE)
			draw_rect(Rect2(-14, -12, 28, 24), c.darkened(0.3))
			draw_rect(Rect2(-14, -12, 28, 24), c, false, 2.0)
			draw_line(Vector2(-14, 0), Vector2(14, 0), c, 1.5)
		Kind.CORE:
			draw_circle(Vector2.ZERO, 16, Color(0.25, 0.3, 0.45))
			draw_arc(Vector2.ZERO, 16, 0, TAU, 20, Color(0.5, 0.85, 1.0), 2.5)
			draw_circle(Vector2.ZERO, 6, Color(0.6, 0.95, 1.0))
		Kind.TERMINAL:
			draw_rect(Rect2(-16, -20, 32, 28), Color(0.15, 0.2, 0.25))
			draw_rect(Rect2(-12, -16, 24, 16), Color(0.2, 0.9, 0.6) if not used else Color(0.2, 0.3, 0.3))
		Kind.CELL:
			draw_rect(Rect2(-40, -40, 80, 80), Color(0.2, 0.2, 0.22, 0.6))
			if not used:
				for i: int in 6:
					var x := -36.0 + i * 14.4
					draw_line(Vector2(x, -40), Vector2(x, 40), Color(0.6, 0.6, 0.65), 3.0)
	var font := ThemeDB.fallback_font
	var text := label()
	var size := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 12)
	draw_string(font, Vector2(-size.x / 2.0, 34), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(1, 1, 1, 0.8))
