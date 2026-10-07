class_name PlanetField
extends Node2D
## Scatters generated planets across an area.

const PLANET_SCENE:PackedScene = preload("res://world/planets/planet.tscn")

@export var planet_count:int = 12
@export var field_size:Vector2 = Vector2(4096, 4096)
## Planets keep at least this much space between their low orbits.
@export var spacing:float = 64.0
## 0 picks a random seed.
@export var field_seed:int = 0

var generator:PlanetGenerator


func _ready() -> void:
	generator = PlanetGenerator.new(field_seed if field_seed else randi())
	var placed:Array[Planet] = []
	for i:int in planet_count:
		var data:PlanetData = generator.generate()
		var orbit:float = data.radius * Planet.LOW_ORBIT_FACTOR
		# Try a handful of spots, give up on this planet if the field is too crowded.
		for attempt:int in 32:
			var spot := Vector2(generator.rng.randf_range(orbit, field_size.x - orbit),
				generator.rng.randf_range(orbit, field_size.y - orbit))
			if _is_clear(spot, orbit, placed):
				var planet:Planet = PLANET_SCENE.instantiate()
				planet.setup(data, generator)
				planet.position = spot
				add_child(planet)
				placed.append(planet)
				break


func _is_clear(spot:Vector2, orbit:float, placed:Array[Planet]) -> bool:
	for other:Planet in placed:
		if spot.distance_to(other.position) < orbit + other.data.radius * Planet.LOW_ORBIT_FACTOR + spacing:
			return false
	return true
