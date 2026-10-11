class_name SimpleHull
extends ShipHull
## A hull with no walkable interior. Damage follows Aurora 4X: hits strike a random column of the ArmorGrid and dig
## down through its layers; damage that gets through wears down the hull's structure and may strike a module, picked
## by its size against the hull's internal size (the rest is empty hull), which takes the whole hit at once. The hull
## is destroyed when its structure reaches zero. Its modules are the `modules` array itself and always count at their
## base size (no size bonus).

## Room inside the hull, against which each module's size sets its chance of being hit. 0 = the modules' total size,
## so every hit that gets through strikes one of them.
@export var internal_size: float = 0.0
## Internal damage the hull can take before it breaks up. 0 = its internal size, rounded up.
@export var structure: int = 0

var grid: ArmorGrid
var structure_left: int


func _setup_damage_model() -> void:
	var columns := maxi(armor_columns, 1)
	grid = ArmorGrid.new(columns, armor.layers_for(armor_mass, columns) if armor else 0)
	if internal_size <= 0.0:
		for i in get_module_count():
			if get_module(i):
				internal_size += get_module(i).size
	if structure <= 0:
		structure = maxi(ceili(internal_size), 1)
	structure_left = structure


func _resolve_hit(damage: int, profile: ArmorGrid.DamageProfile, _direction: Vector2) -> int:
	var penetrating := grid.apply_hit(damage, profile, rng)
	if penetrating > 0:
		apply_internal_damage(penetrating)
	return penetrating


## `points` of damage inside the hull: they come off the structure, and may strike one module with all of them.
func apply_internal_damage(points: int, _origin: int = -1) -> void:
	if is_destroyed or points <= 0:
		return
	structure_left -= points
	var index := pick_module()
	if index >= 0:
		damage_module(index, points)
	if structure_left <= 0:
		_destroy()


## A module picked by its size against the internal size, or -1 when the hit only finds empty hull. Offline modules
## still take up room and can be hit again (to no effect).
func pick_module() -> int:
	var roll := rng.randf() * maxf(internal_size, 1e-6)
	for i in get_module_count():
		var module := get_module(i)
		if module == null:
			continue
		roll -= module.size
		if roll < 0.0:
			return i
	return -1


func get_armor_integrity() -> float:
	return grid.get_integrity()


func _get_wreck_size() -> int:
	return structure
