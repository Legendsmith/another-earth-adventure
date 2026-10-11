class_name ModulePlacement
extends Resource
## Where a ShipModule sits on a deck of a ShipLayout: a solid rectangle of deck cells that crew walk up to and touch to
## operate or repair. The rectangle must cover at least the module's size in cells; covering more gives the module its
## size bonus (see ShipModule.size_bonus).

@export var module: ShipModule
## Deck cells covered by the module (x along the hull from the stern, y across it).
@export var rect: Rect2i = Rect2i(0, 0, 1, 1)


func get_cell_count() -> int:
	return rect.get_area()


## Name shown on the deck plan.
func get_display_name() -> String:
	return module.name if module else "Empty"


func get_color() -> Color:
	return module.color if module else Color(0.4, 0.4, 0.4)
