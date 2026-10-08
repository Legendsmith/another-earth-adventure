class_name PlanetType
extends Resource
## Defines how a kind of planet looks and what it yields when its rewards are collected.

enum Kind {URBAN, AQUATIC, LAVA, FROZEN, JUNGLE, WASTELAND, TOXIC, MYSTERY}

const ABBREVIATIONS:Dictionary[Kind,String] = {
	Kind.URBAN: "URBN",
	Kind.AQUATIC: "AQUA",
	Kind.LAVA: "LAVA",
	Kind.FROZEN: "FROZ",
	Kind.JUNGLE: "JNGL",
	Kind.WASTELAND: "WAST",
	Kind.TOXIC: "TOXC",
	Kind.MYSTERY: "????",
}

@export var kind:Kind
@export var display_name:String
## Colourises the shared noise texture for every planet of this type.
@export var color_ramp:Gradient
## Relative chance of this type being picked when a planet is generated.
@export_range(0.0, 10.0, 0.05) var spawn_weight:float = 1.0

@export_group("Rewards")
## Relative chance each reward roll yields a crewmember, an item or a resource.
@export_range(0.0, 10.0, 0.1) var crew_weight:float = 1.0
@export_range(0.0, 10.0, 0.1) var item_weight:float = 1.0
@export_range(0.0, 10.0, 0.1) var resource_weight:float = 1.0
## Number of reward rolls a planet of this type gets.
@export var min_rolls:int = 3
@export var max_rolls:int = 6
## Resource rolls hand out this many units at once.
@export var resource_amount_min:int = 5
@export var resource_amount_max:int = 20
@export var item_pool:Array[StringName] = []
@export var resource_pool:Array[StringName] = []

var abbreviation:String:
	get: return ABBREVIATIONS[kind]


func roll_rewards(rng:RandomNumberGenerator) -> PlanetRewards:
	var rewards := PlanetRewards.new()
	var weights := PackedFloat32Array([crew_weight, item_weight, resource_weight])
	for i:int in rng.randi_range(min_rolls, max_rolls):
		match rng.rand_weighted(weights):
			0:
				rewards.crew += 1
			1:
				if item_pool.size():
					rewards.add_item(item_pool[rng.randi() % item_pool.size()])
			2:
				if resource_pool.size():
					rewards.add_resource(resource_pool[rng.randi() % resource_pool.size()],
						rng.randi_range(resource_amount_min, resource_amount_max))
	return rewards
