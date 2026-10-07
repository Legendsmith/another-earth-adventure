class_name ArmorGrid
extends RefCounted
## Aurora 4X style armor: a grid `columns` boxes wide (around the hull) and `layers` boxes deep.
##
## A hit lands on a random column. Each point of damage destroys the outermost intact box of the column it falls on;
## a point that falls on a column with no boxes left gets through the armor and becomes internal damage.
## `spread` shapes the crater: 0 puts every point into the struck column (kinetic penetrators dig deep), larger values
## scatter points over neighbouring columns (warheads blast a wide, shallow crater).

var columns: int
var layers: int
## Intact boxes left in each column (0..layers).
var remaining: PackedInt32Array


func _init(column_count: int = 1, layer_count: int = 0) -> void:
	columns = maxi(column_count, 1)
	layers = maxi(layer_count, 0)
	remaining = PackedInt32Array()
	remaining.resize(columns)
	remaining.fill(layers)


## Applies `damage` points to a random column (or `column` when >= 0). Returns the points that penetrated.
func apply_hit(damage: int, spread: int, rng: RandomNumberGenerator, column: int = -1) -> int:
	if column < 0:
		column = rng.randi_range(0, columns - 1)
	var penetrating := 0
	for i in damage:
		var target := column
		if spread > 0:
			# Triangular distribution centred on the struck column: the middle of the crater takes the most.
			target = wrapi(column + rng.randi_range(-spread, 0) + rng.randi_range(0, spread), 0, columns)
		if remaining[target] > 0:
			remaining[target] -= 1
		else:
			penetrating += 1
	return penetrating


func get_intact_boxes() -> int:
	var total := 0
	for value in remaining:
		total += value
	return total


func get_total_boxes() -> int:
	return columns * layers


## Fraction of armor boxes left (1 for a hull without armor, so it never reads as damaged).
func get_integrity() -> float:
	var total := get_total_boxes()
	return float(get_intact_boxes()) / total if total > 0 else 1.0


## Thinnest column: the most a single kinetic hit needs to dig through anywhere on the hull.
func get_weakest_column() -> int:
	var weakest := layers
	for value in remaining:
		weakest = mini(weakest, value)
	return weakest
