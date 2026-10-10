class_name ShipDeck
extends Resource
## One level of a ShipLayout: its internal walls, doors, elevators, modules and zones. Every deck spans the whole
## length and diameter of the hull; decks are stacked from the top (deck 0) down.

@export var name: String = "Deck"
@export var walls: Array[Rect2i] = []
@export var doors: Array[Vector2i] = []
## Elevator cells. Crew ride an elevator to the deck above or below when that deck has an elevator on the same cell.
@export var elevators: Array[Vector2i] = []
@export var modules: Array[ShipModule] = []
@export var rooms: Array[ShipRoom] = []


## Wall cells as a set (Vector2i -> true), from the wall rectangles.
func get_wall_cells() -> Dictionary:
	var result := {}
	for rect in walls:
		for y in range(rect.position.y, rect.end.y):
			for x in range(rect.position.x, rect.end.x):
				result[Vector2i(x, y)] = true
	return result


## Replaces the walls with `cells` (a set of Vector2i), stored as one rectangle per horizontal run.
func set_wall_cells(cells: Dictionary) -> void:
	walls.clear()
	var sorted: Array = cells.keys()
	sorted.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return a.y < b.y or (a.y == b.y and a.x < b.x))
	for cell: Vector2i in sorted:
		if not walls.is_empty():
			var last := walls[-1]
			if last.position.y == cell.y and last.end.x == cell.x:
				walls[-1] = Rect2i(last.position, last.size + Vector2i(1, 0))
				continue
		walls.append(Rect2i(cell, Vector2i.ONE))
