class_name PlanetSite
extends RefCounted
## A system on the FTL map: one planet, its moons and orbital hazards, who is there, and what its expedition holds.
## Everything about the system is generated from its seed, so only what changed (visited, rewards taken) is saved.

enum Faction { NONE, PIRATES, DARK_LIGHT, VOID }
enum ParticleSize { TINY, SMALL, MEDIUM, LARGE }

const FACTION_NAMES := ["None", "Pirates", "Dark Light Brigade", "Void Intruders"]
const PARTICLE_NAMES := ["Tiny", "Small", "Medium", "Large"]
const SYLLABLES := ["ka", "ren", "tho", "vi", "mar", "zen", "lo", "dra", "qui", "sel", "ost", "nar", "ul", "phe",
	"tor", "ix", "an", "cer", "bel", "gos"]

var id: int = 0
var system_seed: int = 0
var name: String = ""
var kind: PlanetType.Kind = PlanetType.Kind.URBAN
## Position on the FTL map (map units).
var map_position: Vector2 = Vector2.ZERO
var moons: int = 0
## Debris fields: [{size: ParticleSize, density: 0..1, ring: bool}]
var debris_fields: Array[Dictionary] = []
var faction: Faction = Faction.NONE
## Enemy ships waiting in orbit.
var enemy_ships: int = 0
## Satellites known to hold item or resource caches (from the ship log).
var known_caches: int = 0
var caches: int = 0

var visited: bool = false
var expedition_done: bool = false
## Resources still in the expedition dungeon.
var fuel: float = 0.0
var metal: float = 0.0
var supplies: float = 0.0
var crew: int = 0
var module_cores: int = 0


static func generate(site_id: int, site_seed: int, position: Vector2, forced_kind: int = -1) -> PlanetSite:
	var site := PlanetSite.new()
	site.id = site_id
	site.system_seed = site_seed
	site.map_position = position
	var rng := RandomNumberGenerator.new()
	rng.seed = site_seed
	site.name = _make_name(rng)
	if forced_kind >= 0:
		site.kind = forced_kind as PlanetType.Kind
	else:
		var weights := PackedFloat32Array([1.2, 1.0, 0.8, 0.9, 1.0, 1.0, 0.8, 0.25])
		site.kind = rng.rand_weighted(weights) as PlanetType.Kind
	site.moons = rng.randi_range(0, 3)
	for i: int in rng.randi_range(0, 3):
		site.debris_fields.append({
			"size": rng.randi_range(0, 3),
			"density": snappedf(rng.randf_range(0.1, 1.0), 0.01),
			"ring": rng.randf() < 0.3,
		})
	var guard: Variant = PlanetRules.get_rule(site.kind, "guard")
	if guard == &"dark_light":
		site.faction = Faction.DARK_LIGHT
		site.enemy_ships = rng.randi_range(1, 2)
	else:
		var roll := rng.randf()
		if roll < 0.35:
			site.faction = Faction.PIRATES
			site.enemy_ships = rng.randi_range(1, 2)
		elif roll < 0.6:
			site.faction = Faction.VOID
			site.enemy_ships = rng.randi_range(2, 4)
		elif roll < 0.65:
			site.faction = Faction.DARK_LIGHT
			site.enemy_ships = 1
	var cache_chance: float = PlanetRules.get_rule(site.kind, "cache_chance", 0.2)
	site.caches = (1 + rng.randi_range(0, 1)) if PlanetRules.get_rule(site.kind, "always_cache", false) \
		else (1 if rng.randf() < cache_chance else 0)
	site.roll_rewards(rng)
	return site


func roll_rewards(rng: RandomNumberGenerator) -> void:
	var base := PlanetRules.BASE_REWARDS
	fuel = roundf(base.fuel * PlanetRules.multiplier(kind, "fuel") * rng.randf_range(0.6, 1.4))
	metal = roundf(base.metal * PlanetRules.multiplier(kind, "metal") * rng.randf_range(0.6, 1.4))
	metal += float(PlanetRules.get_rule(kind, "surface_metal", 0.0))
	supplies = roundf(base.supplies * PlanetRules.multiplier(kind, "supplies") * rng.randf_range(0.6, 1.4))
	crew = maxi(0, roundi(base.crew * PlanetRules.multiplier(kind, "crew") * rng.randf_range(0.5, 1.5)))
	module_cores = rng.randi_range(0, 1) + (1 if PlanetRules.get_rule(kind, "weapon_cores", false) else 0)


static func _make_name(rng: RandomNumberGenerator) -> String:
	var text := ""
	for i: int in rng.randi_range(2, 3):
		text += SYLLABLES[rng.randi() % SYLLABLES.size()]
	return text.capitalize() + (" " + ["I", "II", "III", "IV", "Prime", "b"][rng.randi() % 6] if rng.randf() < 0.4 else "")


func kind_name() -> String:
	return PlanetType.Kind.keys()[kind].capitalize()


func faction_name() -> String:
	return FACTION_NAMES[faction]


func describe() -> String:
	var lines: PackedStringArray = []
	lines.append("%s (%s)" % [name, kind_name()])
	lines.append(PlanetRules.describe(kind))
	lines.append("Moons: %d" % moons)
	if debris_fields.is_empty():
		lines.append("No debris fields")
	else:
		var fields: PackedStringArray = []
		for field: Dictionary in debris_fields:
			fields.append("%s%s" % [PARTICLE_NAMES[field.size], " ring" if field.ring else ""])
		lines.append("Debris: " + ", ".join(fields))
	if visited:
		lines.append("Contacts: %s" % (faction_name() + " x%d" % enemy_ships if faction != Faction.NONE else "none seen"))
		lines.append("Expedition: %s" % ("done" if expedition_done else "not yet"))
	else:
		lines.append("Contacts: unknown")
	if known_caches > 0:
		lines.append("Ship log: %d cache%s" % [known_caches, "s" if known_caches > 1 else ""])
	return "\n".join(lines)


func to_dict() -> Dictionary:
	return {
		"id": id, "seed": system_seed, "pos": [map_position.x, map_position.y], "kind": kind, "visited": visited,
		"expedition_done": expedition_done, "fuel": fuel, "metal": metal, "supplies": supplies, "crew": crew,
		"cores": module_cores, "enemy_ships": enemy_ships, "faction": faction, "known_caches": known_caches,
		"caches": caches,
	}


static func from_dict(data: Dictionary) -> PlanetSite:
	var pos: Array = data.get("pos", [0, 0])
	var site := PlanetSite.generate(int(data.get("id", 0)), int(data.get("seed", 0)), Vector2(pos[0], pos[1]),
		int(data.get("kind", -1)))
	site.visited = bool(data.get("visited", false))
	site.expedition_done = bool(data.get("expedition_done", false))
	site.fuel = float(data.get("fuel", site.fuel))
	site.metal = float(data.get("metal", site.metal))
	site.supplies = float(data.get("supplies", site.supplies))
	site.crew = int(data.get("crew", site.crew))
	site.module_cores = int(data.get("cores", site.module_cores))
	site.enemy_ships = int(data.get("enemy_ships", site.enemy_ships))
	site.faction = int(data.get("faction", site.faction)) as Faction
	site.known_caches = int(data.get("known_caches", 0))
	site.caches = int(data.get("caches", site.caches))
	return site
