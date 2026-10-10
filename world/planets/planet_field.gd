class_name PlanetField
extends Node
## Gives every orbiting CelestialBody a generated planet surface and rewards.
## Bodies without an orbit parent (stars) are left alone, unless listed in fixed_kinds (a lone planet at the centre of
## its scene).

const PLANET_SCENE:PackedScene = preload("res://world/planets/planet.tscn")

## 0 picks a random seed.
@export var field_seed:int = 0
## Low orbit reaches this many body radii from the centre, capped at the body's sphere of influence.
@export var low_orbit_factor:float = 2.5
## Bodies listed here always get this type; the rest are rolled by spawn weight.
@export var fixed_kinds:Dictionary[NodePath,PlanetType.Kind] = {}

var generator:PlanetGenerator
var planets:Array[Planet] = []


func _ready() -> void:
	generator = PlanetGenerator.new(field_seed if field_seed else randi())
	# Sphere of influence is only known once the orbital system has built its ephemeris.
	var orbital_system:Node = get_tree().get_first_node_in_group(Constants.ORBITAL_SYSTEM_GROUP)
	while orbital_system and not orbital_system.IsReady:
		await get_tree().physics_frame
	var kinds:Dictionary[Node,PlanetType.Kind] = {}
	for path:NodePath in fixed_kinds:
		var fixed_body:Node = get_node_or_null(path)
		if fixed_body:
			kinds[fixed_body] = fixed_kinds[path]
	for celestial_body:Node2D in get_tree().get_nodes_in_group(Constants.CELESTIAL_BODY_GROUP):
		if celestial_body.ResolveOrbitParent() == null and not kinds.has(celestial_body):
			continue
		var radius:float = celestial_body.Radius
		var orbit_radius:float = radius * low_orbit_factor
		var influence:float = celestial_body.EffectiveSphereOfInfluence
		if influence > radius:
			orbit_radius = minf(orbit_radius, influence)
		var planet:Planet = PLANET_SCENE.instantiate()
		planet.setup(generator.generate(kinds.get(celestial_body, -1), radius), generator, orbit_radius)
		celestial_body.add_child(planet)
		planets.append(planet)
