class_name PlanetGenerator
extends RefCounted
## Generates planets whose surfaces are regions of one shared noise texture.
## Each planet type gets a [NoiseTexture2D] built from the same [FastNoiseLite] but with its own colour ramp,
## so every planet of every type is just an [AtlasTexture] region of one of those textures.

const PLANET_TYPES:Array[PlanetType] = [
	preload("res://world/planets/types/urban.tres"),
	preload("res://world/planets/types/aquatic.tres"),
	preload("res://world/planets/types/lava.tres"),
	preload("res://world/planets/types/frozen.tres"),
	preload("res://world/planets/types/jungle.tres"),
	preload("res://world/planets/types/wasteland.tres"),
	preload("res://world/planets/types/toxic.tres"),
	preload("res://world/planets/types/mystery.tres"),
]

const MIN_RADIUS:float = 24.0
const MAX_RADIUS:float = 64.0

var rng := RandomNumberGenerator.new()
var noise := FastNoiseLite.new()
var texture_size:int
var _types:Dictionary[PlanetType.Kind,PlanetType] = {}
var _textures:Dictionary[PlanetType.Kind,NoiseTexture2D] = {}


func _init(generator_seed:int = randi(), size:int = 2048) -> void:
	rng.seed = generator_seed
	texture_size = size
	noise.seed = generator_seed
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 0.012
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = 5
	for planet_type:PlanetType in PLANET_TYPES:
		_types[planet_type.kind] = planet_type


func get_type(kind:PlanetType.Kind) -> PlanetType:
	return _types[kind]


## Picks a type by spawn weight.
func random_kind() -> PlanetType.Kind:
	var weights := PackedFloat32Array()
	for planet_type:PlanetType in PLANET_TYPES:
		weights.append(planet_type.spawn_weight)
	return PLANET_TYPES[rng.rand_weighted(weights)].kind


## Generates a new planet. Pass a kind to force the type, or leave it at -1 for a random one.
## A radius of 0 or less picks a random size.
func generate(kind:int = -1, radius:float = 0.0) -> PlanetData:
	var data := PlanetData.new()
	data.kind = random_kind() if kind < 0 else kind as PlanetType.Kind
	data.radius = radius if radius > 0.0 else rng.randf_range(MIN_RADIUS, MAX_RADIUS)
	var diameter:float = minf(ceilf(data.radius * 2.0), texture_size)
	data.region = Rect2(
		rng.randf_range(0.0, texture_size - diameter),
		rng.randf_range(0.0, texture_size - diameter),
		diameter, diameter)
	data.rewards = get_type(data.kind).roll_rewards(rng)
	return data


## The shared, colourised noise texture for a type. Created on first use.
func get_noise_texture(kind:PlanetType.Kind) -> NoiseTexture2D:
	if not _textures.has(kind):
		var texture := NoiseTexture2D.new()
		texture.width = texture_size
		texture.height = texture_size
		texture.noise = noise
		texture.color_ramp = get_type(kind).color_ramp
		_textures[kind] = texture
	return _textures[kind]


## Cuts the planet's surface out of its type's noise texture.
func make_surface(data:PlanetData) -> AtlasTexture:
	var surface := AtlasTexture.new()
	surface.atlas = get_noise_texture(data.kind)
	surface.region = data.region
	return surface
