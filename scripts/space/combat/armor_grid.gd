class_name ArmorGrid
extends RefCounted
## Aurora 4X style armor: a grid `columns` boxes wide (around the hull) and `layers` boxes deep.
##
## A hit lands on a random column and digs a crater of a fixed shape set by its damage profile (see crater()).
## Each point of the crater destroys the outermost intact box of its column; a point that falls on a column with no
## boxes left gets through the armor and becomes internal damage.

## How a hit's damage is laid out over the armor columns.
enum DamageProfile {
	## Penetrators: a wedge as deep as it is wide (16 damage = 1,2,3,4,3,2,1).
	KINETIC,
	## Warheads: a wide, shallow crater two boxes deep (16 damage = 1,2,2,2,2,2,2,2,1).
	EXPLOSIVE,
}

## Depth of an explosive crater in boxes.
const EXPLOSIVE_DEPTH := 2

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


## Applies a hit of `damage` points with `profile` centred on a random column (or `column` when >= 0).
## Returns the points that penetrated.
func apply_hit(damage: int, profile: DamageProfile, rng: RandomNumberGenerator, column: int = -1) -> int:
	if column < 0:
		column = rng.randi_range(0, columns - 1)
	var shape := ArmorGrid.crater(damage, profile)
	var first := column - floori(shape.size() / 2.0)
	var penetrating := 0
	for i in shape.size():
		# Craters wider than the hull wrap around it and dig the same columns again.
		var target := wrapi(first + i, 0, columns)
		var absorbed := mini(shape[i], remaining[target])
		remaining[target] -= absorbed
		penetrating += shape[i] - absorbed
	return penetrating


## Points per column of a `damage`-point crater, left to right, centred on the struck column.
@warning_ignore("integer_division")
static func crater(damage: int, profile: DamageProfile) -> PackedInt32Array:
	var shape := PackedInt32Array()
	if damage <= 0:
		return shape
	match profile:
		DamageProfile.EXPLOSIVE:
			# Columns EXPLOSIVE_DEPTH deep, kept an odd width so the crater is centred: when an odd count of full
			# columns does not fit, the edges taper to one box. An odd damage point deepens the centre.
			var full := damage / EXPLOSIVE_DEPTH
			if full == 0:
				shape.append(damage)
				return shape
			if full % 2 == 1:
				shape.resize(full)
				shape.fill(EXPLOSIVE_DEPTH)
			else:
				shape.resize(full + 1)
				shape.fill(EXPLOSIVE_DEPTH)
				shape[0] = EXPLOSIVE_DEPTH / 2
				shape[full] = EXPLOSIVE_DEPTH / 2
			shape[shape.size() / 2] += damage % EXPLOSIVE_DEPTH
		_:
			# Wedge of height h holds h * h points: 1, 2 .. h .. 2, 1.
			var height := ceili(sqrt(float(damage)))
			shape.resize(2 * height - 1)
			var left := damage
			# Fill the middle first, then the next columns out in pairs, until the damage runs out.
			for ring in height:
				var depth := height - ring
				for side in ([0] if ring == 0 else [-1, 1]):
					var points := mini(depth, left)
					shape[height - 1 + side * ring] = points
					left -= points
			# Trim empty edge columns so the wedge stays centred.
			while shape.size() > 1 and shape[0] == 0 and shape[shape.size() - 1] == 0:
				shape = shape.slice(1, shape.size() - 1)
	return shape


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
