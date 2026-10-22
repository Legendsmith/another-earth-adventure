class_name PlanetRules
extends RefCounted
## How each planet type changes rewards and expedition gameplay (Design Definitions, Planets).
## Percentages from the design notes are multipliers here (+100% crew = 2.0).

const RULES := {
	PlanetType.Kind.URBAN: {
		"crew": 2.0, "supplies": 2.0, "fuel": 0.75, "metal": 1.0, "cache_chance": 0.05,
		"crew_bonus": {&"repair": 1.0}, "basic_weapons_only": true,
		"text": "Cities, intact or not. More crew and supplies, little fuel, only basic ship weapons.",
	},
	PlanetType.Kind.AQUATIC: {
		"crew": 1.0, "supplies": 1.25, "fuel": 1.0, "metal": 0.5,
		"crew_bonus": {&"resilience": 1.0, &"medical": 1.0},
		"text": "Enormous oceans. More supplies, less metal.",
	},
	PlanetType.Kind.LAVA: {
		"crew": 1.0, "supplies": 0.2, "fuel": 1.0, "metal": 3.0, "surface_metal": 20.0, "eruption": true,
		"text": "Molten surface. Plenty of metal, very few supplies. Explosions fill the eruption gauge.",
	},
	PlanetType.Kind.FROZEN: {
		"crew": 0.5, "supplies": 1.0, "fuel": 1.25, "metal": 1.0, "ice_walls": true,
		"crew_bonus": {&"resilience": 3.0},
		"text": "Cold world. More fuel, fewer crew. Ice walls block the way until broken.",
	},
	PlanetType.Kind.JUNGLE: {
		"crew": 1.5, "supplies": 1.0, "fuel": 0.6, "metal": 1.0, "wildlife": 2.0,
		"crew_bonus": {&"combat": 2.0},
		"text": "Humid jungle. More crew, less fuel, far more dangerous wildlife.",
	},
	PlanetType.Kind.WASTELAND: {
		"crew": 0.75, "supplies": 1.0, "fuel": 1.0, "metal": 1.25, "weapon_cores": true,
		"crew_bonus": {&"combat": 1.0, &"repair": 1.0},
		"text": "Deserts and harsh terrain. More metal, weapon module cores more likely, fewer crew.",
	},
	PlanetType.Kind.TOXIC: {
		"crew": 0.25, "supplies": 1.0, "fuel": 1.5, "metal": 1.0, "needs_oxygen": true,
		"crew_bonus": {&"medical": 2.0},
		"text": "Polluted atmosphere: bring oxygen. Much more fuel, very few crew.",
	},
	PlanetType.Kind.MYSTERY: {
		"crew": 1.0, "supplies": 1.0, "fuel": 1.0, "metal": 1.0, "always_cache": true, "ftl_limit": 2.0,
		"guard": &"dark_light",
		"text": "Unknown world, always guarded by the Dark Light Brigade. Always has caches.",
	},
}

## Base amounts an expedition dungeon holds before planet multipliers.
const BASE_REWARDS := {"fuel": 40.0, "metal": 18.0, "supplies": 30.0, "crew": 3.0}
const FTL_LIMIT := 1.5


static func get_rule(kind: PlanetType.Kind, key: String, default: Variant = null) -> Variant:
	return RULES.get(kind, {}).get(key, default)


static func multiplier(kind: PlanetType.Kind, resource: String) -> float:
	return float(get_rule(kind, resource, 1.0))


## FTL limit in geostationary orbit distances.
static func ftl_limit(kind: PlanetType.Kind) -> float:
	return float(get_rule(kind, "ftl_limit", FTL_LIMIT))


static func describe(kind: PlanetType.Kind) -> String:
	return str(get_rule(kind, "text", ""))


## Applies the planet's bonuses to a crewmember found there.
static func apply_crew_bonus(kind: PlanetType.Kind, record: CrewRecord) -> void:
	var bonus: Dictionary = get_rule(kind, "crew_bonus", {})
	for stat: StringName in bonus:
		if record.skills.has(stat):
			record.skills[stat] += bonus[stat]
		elif record.attributes.has(stat):
			record.attributes[stat] += bonus[stat]
	record.rebuild_body()
