class_name StarMap
extends RefCounted
## The FTL map: the systems the ship can jump to, where it is, and how much fuel a jump costs.

const MAP_SIZE := Vector2(1600.0, 900.0)
const MIN_SPACING := 150.0
## Jumps longer than this are beyond the FTL drive's short range jump.
const MAX_JUMP := 520.0

var sites: Array[PlanetSite] = []
var current: int = 0
var map_seed: int = 0


static func generate(count: int, generator_seed: int) -> StarMap:
	var map := StarMap.new()
	map.map_seed = generator_seed
	var rng := RandomNumberGenerator.new()
	rng.seed = generator_seed
	var positions: Array[Vector2] = [Vector2(120.0, MAP_SIZE.y * 0.5)]
	var attempts := 0
	while positions.size() < count and attempts < 5000:
		attempts += 1
		var candidate := Vector2(rng.randf_range(80.0, MAP_SIZE.x - 80.0), rng.randf_range(80.0, MAP_SIZE.y - 80.0))
		var ok := true
		for other: Vector2 in positions:
			if other.distance_to(candidate) < MIN_SPACING:
				ok = false
				break
		if ok:
			positions.append(candidate)
	for i: int in positions.size():
		# The start is a habitable-ish world with crew to rescue.
		var kind: int = PlanetType.Kind.URBAN if i == 0 else -1
		map.sites.append(PlanetSite.generate(i, rng.randi(), positions[i], kind))
	map.sites[0].visited = true
	map.sites[0].faction = PlanetSite.Faction.NONE
	map.sites[0].enemy_ships = 0
	map._ensure_connected()
	return map


## Makes sure every system can be reached from the start in jumps of at most MAX_JUMP by nudging stragglers closer.
func _ensure_connected() -> void:
	for pass_index: int in 4:
		var reached := reachable_from(0)
		if reached.size() == sites.size():
			return
		for site: PlanetSite in sites:
			if reached.has(site.id):
				continue
			var nearest: PlanetSite = null
			var best := INF
			for other_id: int in reached:
				var d := sites[other_id].map_position.distance_to(site.map_position)
				if d < best:
					best = d
					nearest = sites[other_id]
			if nearest:
				site.map_position = nearest.map_position + (site.map_position - nearest.map_position).normalized() * MAX_JUMP * 0.9


func reachable_from(start: int) -> Dictionary:
	var reached := {start: true}
	var frontier: Array[int] = [start]
	while not frontier.is_empty():
		var from: int = frontier.pop_back()
		for site: PlanetSite in sites:
			if not reached.has(site.id) and in_range(from, site.id):
				reached[site.id] = true
				frontier.append(site.id)
	return reached


func get_current() -> PlanetSite:
	return sites[current] if current >= 0 and current < sites.size() else null


func get_site(site_id: int) -> PlanetSite:
	return sites[site_id] if site_id >= 0 and site_id < sites.size() else null


func distance(from: int, to: int) -> float:
	return sites[from].map_position.distance_to(sites[to].map_position)


func in_range(from: int, to: int) -> bool:
	return from != to and distance(from, to) <= MAX_JUMP


## Fuel a jump costs: distance times the rate, scaled by the ship's total mass (a full hold costs more).
func jump_cost(from: int, to: int, config: GameConfig, cargo_mass: float) -> float:
	var mass_factor := (config.dry_ship_mass + cargo_mass) / config.dry_ship_mass
	return distance(from, to) * config.ftl_fuel_per_distance * mass_factor


func to_dict() -> Dictionary:
	var site_data: Array = []
	for site: PlanetSite in sites:
		site_data.append(site.to_dict())
	return {"seed": map_seed, "current": current, "sites": site_data}


static func from_dict(data: Dictionary) -> StarMap:
	var map := StarMap.new()
	map.map_seed = int(data.get("seed", 0))
	map.current = int(data.get("current", 0))
	for entry: Variant in data.get("sites", []):
		if entry is Dictionary:
			map.sites.append(PlanetSite.from_dict(entry))
	return map
