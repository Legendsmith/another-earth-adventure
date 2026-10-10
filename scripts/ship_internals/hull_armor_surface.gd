class_name HullArmorSurface
extends RefCounted
## The armor over a cylindrical hull, unrolled into a 2D grid of armor columns: x runs along the hull from the stern,
## y around its circumference (wrapping), and each column holds `thickness` depth steps of armor.
##
## The grid is shown as an image: white is intact armor, darker pixels are deeper pits and black is a hole right
## through. Show it in a TextureRect with nearest-neighbour filtering to keep each column a crisp block at any scale.

var width: int
var height: int
var thickness: int
## Depth steps of armor left in each column, row-major (y * width + x), 0..thickness.
var remaining: PackedByteArray
var image: Image
var texture: ImageTexture


func _init(surface_width: int = 1, surface_height: int = 1, armor_thickness: int = 1) -> void:
	width = maxi(surface_width, 1)
	height = maxi(surface_height, 1)
	thickness = clampi(armor_thickness, 0, 255)
	remaining = PackedByteArray()
	remaining.resize(width * height)
	remaining.fill(thickness)
	image = Image.create_empty(width, height, false, Image.FORMAT_L8)
	texture = ImageTexture.create_from_image(image)
	refresh()


## Armor column under (x, y). x is clamped to the hull ends, y wraps around the hull.
func get_remaining(x: int, y: int) -> int:
	return remaining[_index(x, y)]


func is_holed(x: int, y: int) -> bool:
	return thickness > 0 and get_remaining(x, y) == 0


## Digs up to `depth` steps out of a column. Returns the depth that went beyond the armor (through the hole).
func dig(x: int, y: int, depth: int) -> int:
	if depth <= 0:
		return 0
	var i := _index(x, y)
	var absorbed := mini(depth, remaining[i])
	remaining[i] -= absorbed
	_paint(i)
	return depth - absorbed


## Digs a crater of `damage` depth steps centred on (x, y) and returns the steps that went through the armor.
## Kinetic hits bore a narrow, deep pit: most of the damage in the struck column, the rest in the ring around it.
## Explosive hits blow a wide, shallow crater ArmorGrid.EXPLOSIVE_DEPTH deep. As on the armor grid, every point is
## spent on armor or goes through: none is lost.
func apply_crater(x: int, y: int, damage: int, profile: ArmorGrid.DamageProfile) -> int:
	if damage <= 0:
		return 0
	var offsets: Array[Vector2i] = []
	var depths := PackedInt32Array()
	if profile == ArmorGrid.DamageProfile.EXPLOSIVE:
		# Columns EXPLOSIVE_DEPTH deep from the centre outwards until the damage runs out.
		var reach := ceili(sqrt(damage / float(ArmorGrid.EXPLOSIVE_DEPTH) / PI)) + 1
		for offset in _disc(reach):
			if damage <= 0:
				break
			offsets.append(offset)
			depths.append(mini(ArmorGrid.EXPLOSIVE_DEPTH, damage))
			damage -= depths[-1]
	else:
		# Most of the damage in the struck column, the rest spread over the ring around it, deeper nearer the centre.
		var weights := PackedFloat32Array()
		var total_weight := 0.0
		for offset in _disc(1):
			offsets.append(offset)
			weights.append(1.0 - Vector2(offset).length() / 2.0)
			total_weight += weights[-1]
		var left := damage
		for weight in weights:
			depths.append(floori(damage * weight / total_weight))
			left -= depths[-1]
		depths[0] += left
	var penetrating := 0
	for i in offsets.size():
		# Damage off the ends of the hull digs the end column instead.
		penetrating += dig(clampi(x + offsets[i].x, 0, width - 1), y + offsets[i].y, depths[i])
	return penetrating


## Offsets within `reach` of the centre, nearest first (the centre itself first).
static func _disc(reach: int) -> Array[Vector2i]:
	var offsets: Array[Vector2i] = []
	for dy in range(-reach, reach + 1):
		for dx in range(-reach, reach + 1):
			if Vector2(dx, dy).length() <= reach + 0.5:
				offsets.append(Vector2i(dx, dy))
	offsets.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return a.length_squared() < b.length_squared())
	return offsets


## Fraction of armor left over the whole hull (1 for an unarmored hull).
func get_integrity() -> float:
	var total := width * height * thickness
	if total <= 0:
		return 1.0
	var left := 0
	for value in remaining:
		left += value
	return float(left) / total


## Columns holed right through.
func get_hole_count() -> int:
	if thickness <= 0:
		return 0
	return remaining.count(0)


## Rebuilds the whole image and texture (after changing `remaining` directly).
func refresh() -> void:
	for i in remaining.size():
		_paint(i)
	update_texture()


## Pushes painted pixels to the texture. Call once after a batch of digs.
func update_texture() -> void:
	texture.update(image)


@warning_ignore("integer_division")
func _paint(i: int) -> void:
	var level := float(remaining[i]) / thickness if thickness > 0 else 0.0
	image.set_pixel(i % width, i / width, Color(level, level, level))


func _index(x: int, y: int) -> int:
	return wrapi(y, 0, height) * width + clampi(x, 0, width - 1)
