class_name ShipRoom
extends Resource
## A named area of a ShipLayout's deck (shown on the internals view). Rooms hold no systems: rounds through them only
## hole the deck and walls.

@export var name: String = "Room"
@export var rect: Rect2i = Rect2i(0, 0, 1, 1)
