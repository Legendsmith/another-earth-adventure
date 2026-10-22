class_name CampaignOrbit
extends Node
## Ties the orbital scene to the campaign (Orbital Gameplay, Orbital Game Flow). Placed as the first child of the
## orbital space so it can set the system up before anything else is ready: the planet type of the current system, its
## hazards and enemies, and the player's ship (modules, fuel, cargo mass, where it arrives).
##
## While the scene runs it advances orbital time for the campaign (maintenance clocks, malfunctions, reactor fuel,
## the medical bay), keeps the ship's fuel and module states in step with the campaign, detects low orbit (insertion
## or flyby) and the FTL limit, and runs encounters: demands, combat preparation, crew casualties and repairs, the
## boarding countdown and surrender.

signal encounter_changed

enum Encounter { NONE, DEMAND, PREPARING, COMBAT }

## Campaign fuel units -> ship fuel mass units.
const FUEL_SCALE := 0.4
## World px around the ship within which hostiles count as being in the fight.
const COMBAT_MARGIN := 1.3
## Seconds with no hostile in range before the ship stands down from combat power.
const STAND_DOWN_SECONDS := 20.0
const PURSUIT_INTERVAL := 3.0
## Map units per second an attacker closes in at.
const PURSUIT_SPEED := 0.6

var campaign: Node
var site: PlanetSite
var ship: Spaceship
var hull: ShipHull
var planet_body: Node2D
var planet: Planet
var guides: OrbitGuides
var orbital_system: Node

var encounter: Encounter = Encounter.NONE
var prep_left: float = 0.0
## Hostile hull -> {state, demand, close_time, pirate}
var contacts: Dictionary = {}
var demand_hull: ShipHull
var boarding_countdown: float = -1.0
var boarding_hull: ShipHull
var undercrewed_time: float = 0.0
var casualties := {"injured": 0, "dead": 0}
var in_low_orbit := false
var outside_ftl_limit := false
var salvaging := false

var _last_sim_time: float = -1.0
var _last_ship_fuel: float = -1.0
var _syncing := false
var _sync_timer: float = 0.0
var _stand_down_timer: float = 0.0
var _pursuit_timer: float = 0.0
var _player_munitions: int = 0
var _last_fire_time: float = -100.0
var _time: float = 0.0
var _overlay: CanvasLayer
var _overlay_box: VBoxContainer
var _overlay_label: RichTextLabel
var _overlay_buttons: HBoxContainer


func _enter_tree() -> void:
	campaign = get_node_or_null("/root/Campaign")
	if campaign == null or not campaign.active:
		set_process(false)
		set_physics_process(false)
		return
	site = campaign.star_map.get_current()
	var space := get_parent()
	planet_body = space.get_node_or_null("Ferra")
	ship = space.get_node_or_null("PlayerShip")
	hull = ship.get_node_or_null("SimpleHull") if ship else null
	guides = planet_body.get_node_or_null("OrbitGuides") if planet_body else null
	_setup_planet(space)
	_setup_hazards()
	_setup_enemies(space)
	_setup_ship()


func _ready() -> void:
	if campaign == null or not campaign.active:
		return
	orbital_system = get_tree().get_first_node_in_group(Constants.ORBITAL_SYSTEM_GROUP)
	if hull:
		hull.module_offline.connect(_on_module_offline)
		hull.module_restored.connect(_on_module_restored)
		hull.module_hit.connect(_on_module_hit)
		_apply_armor()
	campaign.ship.module_changed.connect(func(_m: ModuleState) -> void: _sync_timer = 0.0)
	_build_overlay()
	campaign.ship.assign_crew(campaign.crew)
	campaign.message_posted.connect(_on_message)


#region Setup

func _setup_planet(space: Node) -> void:
	if planet_body == null:
		return
	planet_body.name = site.name.replace(" ", "_")
	var field := space.get_node_or_null("PlanetField") as PlanetField
	if field:
		field.fixed_kinds = {NodePath("../" + planet_body.name): site.kind}
		field.field_seed = site.system_seed
	var colors := {
		PlanetType.Kind.URBAN: Color(0.5, 0.5, 0.55), PlanetType.Kind.AQUATIC: Color(0.25, 0.45, 0.75),
		PlanetType.Kind.LAVA: Color(0.8, 0.35, 0.15), PlanetType.Kind.FROZEN: Color(0.75, 0.85, 0.95),
		PlanetType.Kind.JUNGLE: Color(0.25, 0.6, 0.3), PlanetType.Kind.WASTELAND: Color(0.7, 0.6, 0.4),
		PlanetType.Kind.TOXIC: Color(0.55, 0.65, 0.25), PlanetType.Kind.MYSTERY: Color(0.45, 0.3, 0.65),
	}
	planet_body.set(&"BodyColor", colors.get(site.kind, Color.GRAY))
	if guides:
		guides.ftl_limit_factor = PlanetRules.ftl_limit(site.kind)


## Debris fields from the system's data: one of the scene's fields per entry, sized by particle size.
func _setup_hazards() -> void:
	if planet_body == null:
		return
	var anchors := ["LowOrbitDebris", "RetrogradeDebris", "OldBattlefield", "ShatteredTanker"]
	for i: int in anchors.size():
		var anchor := planet_body.get_node_or_null(anchors[i])
		if anchor == null:
			continue
		if i >= site.debris_fields.size():
			anchor.queue_free()
			continue
		var data: Dictionary = site.debris_fields[i]
		var field := anchor.get_node_or_null("Field") as SpaceBattlefield
		if field == null:
			continue
		var size: int = data.size
		field.display_name = "%s debris%s (%s)" % [PlanetSite.PARTICLE_NAMES[size], " ring" if data.ring else "",
			"dense" if data.density > 0.6 else "sparse"]
		# Bigger particles hit harder at speed; denser fields more often.
		field.debris_density = 0.0002 + 0.0009 * float(data.density) * (1.3 - size * 0.2)
		field.damage_speed = [120.0, 70.0, 45.0, 30.0][size]
		field.derelict_launchers = 1 if size >= PlanetSite.ParticleSize.MEDIUM else 0
		field.set_meta(&"particle_size", size)
	var asteroid := planet_body.get_node_or_null("CapturedAsteroid")
	if asteroid and site.system_seed % 3 != 0:
		asteroid.queue_free()


## Enemies from the system's faction: pirate or Dark Light gunships, Void Intruder drones, the odd kill-sat.
func _setup_enemies(space: Node) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = site.system_seed + 5
	var gunships := site.enemy_ships if site.faction in [PlanetSite.Faction.PIRATES, PlanetSite.Faction.DARK_LIGHT] else 0
	var drones := site.enemy_ships * 2 if site.faction == PlanetSite.Faction.VOID else rng.randi_range(0, 1)
	var platforms := rng.randi_range(0, 2) if site.debris_fields.size() > 1 else 0
	for i: int in range(1, 3):
		var node := space.get_node_or_null("Gunship%d" % i)
		if node == null:
			continue
		if i > gunships:
			node.queue_free()
		else:
			var enemy_hull := node.get_node_or_null("SimpleHull") as ShipHull
			if enemy_hull:
				# They hold fire until their demands are answered.
				enemy_hull.faction = &""
				enemy_hull.display_name = "%s gunship" % ("Pirate" if site.faction == PlanetSite.Faction.PIRATES else "Dark Light")
				enemy_hull.set_meta(&"campaign_faction", site.faction)
	for i: int in range(1, 7):
		var node := space.get_node_or_null("Drone%d" % i)
		if node == null:
			continue
		if i > drones:
			node.queue_free()
		else:
			var drone_hull := node.get_node_or_null("SimpleHull") as ShipHull
			if drone_hull and site.faction == PlanetSite.Faction.VOID:
				drone_hull.display_name = "Crystal Fighter" if i % 3 else "Void Lancer"
				drone_hull.set_meta(&"campaign_faction", PlanetSite.Faction.VOID)
	for i: int in range(1, 5):
		var node := space.get_node_or_null("GunPlatform%d" % i)
		if node and i > platforms:
			node.queue_free()


func _setup_ship() -> void:
	if ship == null:
		return
	var stores: ShipStores = campaign.stores
	ship.fuel_capacity = maxf(stores.fuel_capacity() * FUEL_SCALE, 0.01)
	ship.fuel = stores.fuel * FUEL_SCALE
	_last_ship_fuel = ship.fuel
	# Stored resources are carried mass: a full hold costs more fuel on every burn.
	ship.dry_mass += (stores.metal + stores.supplies) * campaign.config.mass_per_unit
	if hull:
		var designs: Array[ShipModule] = []
		for module: ModuleState in campaign.ship.modules:
			designs.append(module.design)
		hull.modules = designs
		hull.display_name = campaign.ship.name
	var radius := _arrival_radius()
	var angle := float(site.system_seed % 628) / 100.0
	ship.position = planet_body.position + Vector2.from_angle(angle) * radius if planet_body else ship.position


func _arrival_radius() -> float:
	var geo := guides.get_geostationary_radius() if guides else 1000.0
	match campaign.orbit_stage:
		campaign.OrbitStage.LOW_ORBIT:
			return (guides.low_orbit_radius if guides else 360.0) * 0.97
		campaign.OrbitStage.FLYBY, campaign.OrbitStage.IN_TRANSIT:
			return geo * 0.6
	return geo * PlanetRules.ftl_limit(site.kind) * 1.03


func _apply_armor() -> void:
	var simple := hull as SimpleHull
	if simple == null or simple.grid == null:
		return
	var share: float = clampf(campaign.ship.armor / maxf(campaign.ship.max_armor, 1.0), 0.0, 1.0)
	for i: int in simple.grid.remaining.size():
		simple.grid.remaining[i] = roundi(simple.grid.remaining[i] * share)

#endregion


#region Per frame

func _physics_process(delta: float) -> void:
	if campaign == null or ship == null or campaign.phase != campaign.Phase.ORBIT:
		return
	_time += delta
	_advance_orbital_time()
	_sync_fuel()
	_find_planet()
	_check_orbit_zones()
	_sync_timer -= delta
	if _sync_timer <= 0.0:
		_sync_timer = 0.25
		_sync_modules()
	_update_encounters(delta)
	_update_repairs(delta)
	_update_salvage(delta)
	_check_undercrewed(delta)


func _advance_orbital_time() -> void:
	if orbital_system == null or not orbital_system.IsReady:
		return
	var now: float = orbital_system.SimTime
	if _last_sim_time < 0.0:
		_last_sim_time = now
		return
	var seconds := now - _last_sim_time
	_last_sim_time = now
	if seconds > 0.0:
		campaign.tick_orbit(seconds, encounter == Encounter.COMBAT)


## The ship burns fuel through its engines; the campaign burns it in the reactors. Both come out of the same tanks.
func _sync_fuel() -> void:
	var stores: ShipStores = campaign.stores
	if _last_ship_fuel >= 0.0 and ship.fuel < _last_ship_fuel:
		var burned: float = (_last_ship_fuel - ship.fuel) / FUEL_SCALE * campaign.ship.drive_fuel_multiplier()
		stores.drain(ShipStores.FUEL, burned)
	ship.fuel = minf(stores.fuel * FUEL_SCALE, ship.fuel_capacity)
	_last_ship_fuel = ship.fuel
	if stores.fuel <= 0.01:
		campaign.check_game_over()


func _find_planet() -> void:
	if planet != null and is_instance_valid(planet):
		return
	for node: Node in get_tree().get_nodes_in_group(Planet.GROUP):
		planet = node as Planet
		return


func _check_orbit_zones() -> void:
	if planet_body == null:
		return
	var distance := ship.global_position.distance_to(planet_body.global_position)
	var low := planet != null and planet.is_in_low_orbit()
	if low and not in_low_orbit:
		in_low_orbit = true
		campaign.reach_low_orbit(not _is_captured())
	elif not low and in_low_orbit:
		in_low_orbit = false
		campaign.leave_low_orbit()
	elif low and campaign.orbit_stage == campaign.OrbitStage.FLYBY and _is_captured():
		# Circularised inside low orbit after all: a proper insertion.
		campaign.reach_low_orbit(false)
	var limit := (guides.get_geostationary_radius() if guides else 1000.0) * PlanetRules.ftl_limit(site.kind)
	outside_ftl_limit = distance >= limit
	if not outside_ftl_limit and campaign.orbit_stage == campaign.OrbitStage.FTL_LIMIT:
		campaign.orbit_stage = campaign.OrbitStage.IN_TRANSIT


## A bound orbit that stays within low orbit: orbital insertion. Anything else passing through is a flyby.
func _is_captured() -> bool:
	if orbital_system == null or not orbital_system.IsReady or planet_body == null:
		return false
	var body: int = orbital_system.GetBodyIndex(planet_body)
	var info: Dictionary = orbital_system.GetOrbitInfo(ship.get_state_position(), ship.get_state_velocity(), body)
	if info.is_empty() or not info.get("bound", false):
		return false
	var low_radius: float = guides.low_orbit_radius if guides else 360.0
	return float(info.get("apoapsis", INF)) <= low_radius * 1.25


func can_engage_ftl() -> bool:
	return outside_ftl_limit and encounter != Encounter.COMBAT and encounter != Encounter.DEMAND


func engage_ftl() -> void:
	if can_engage_ftl():
		_store_armor()
		campaign.reach_ftl_limit()
		campaign.go_to_phase_scene()


func _store_armor() -> void:
	if hull:
		campaign.ship.armor = minf(campaign.ship.armor, campaign.ship.max_armor * hull.get_armor_integrity())

#endregion


#region Modules, crew and repairs

## A module runs when the campaign has it online, its crew requirement is met and, for weapons, it is loaded.
func _sync_modules() -> void:
	if hull == null:
		return
	var state: ShipState = campaign.ship
	state.assign_crew(campaign.crew)
	_syncing = true
	for i: int in mini(state.modules.size(), hull.get_module_count()):
		var module := state.modules[i]
		var want := module.online and state.is_manned(i, campaign.crew)
		if module.is_weapon() and not state.weapons_loaded:
			# Loading the weapons draws ammunition from Supplies.
			want = false
		if hull.get_module_bit(i) != ShipHull.NO_BIT and hull.is_module_operational(i) != want:
			hull.set_module_operational(i, want)
	_syncing = false
	var readiness := get_tree().root.find_child("CombatReadinessBar", true, false) as ProgressBar
	if readiness:
		readiness.max_value = 100.0
		readiness.value = state.combat_readiness(campaign.crew) * 100.0


func _on_module_offline(index: int) -> void:
	if _syncing or index >= campaign.ship.modules.size():
		return
	var module: ModuleState = campaign.ship.modules[index]
	module.knock_out()
	campaign.post("%s knocked offline!" % module.get_module_name(), 2)


func _on_module_restored(_index: int) -> void:
	pass


## Crew working at a module that is hit can be hurt: the easiest way to beat a ship is to put its crew out of action.
func _on_module_hit(index: int, damage: int) -> void:
	if index >= campaign.ship.modules.size():
		return
	var module: ModuleState = campaign.ship.modules[index]
	if module.online and module.is_overdue() and encounter == Encounter.COMBAT:
		if campaign.ship.rng.randf() < campaign.config.combat_malfunction_chance:
			campaign.ship.combat_malfunction(module)
	for record: CrewRecord in campaign.crew:
		if record.assigned_module != index or not record.is_active():
			continue
		if campaign.ship.rng.randf() < 0.5:
			record.body.take_damage(damage * 4.0, MedicalBody.DamageType.EXPLOSIVE)
			record.body.step(1.0)
			if record.body.dead:
				casualties.dead += 1
				campaign.kill(record, "was killed at the %s" % module.get_module_name())
			elif not record.body.is_conscious() or record.body.get_status() >= MedicalBody.Status.CRITICAL:
				casualties.injured += 1
				record.status = CrewRecord.Status.HEALING
				campaign.post("%s was wounded at the %s." % [record.get_shown_name(), module.get_module_name()], 1)
			campaign.crew_changed.emit()


## Damage control: crew not manning a station work on offline modules. In combat they bring a module straight back
## online; outside combat they maintain it first (Supplies) before it comes back.
func _update_repairs(delta: float) -> void:
	var state: ShipState = campaign.ship
	var broken: Array[ModuleState] = []
	for module: ModuleState in state.modules:
		if not module.online:
			broken.append(module)
	if broken.is_empty():
		return
	var team: Array[CrewRecord] = []
	for record: CrewRecord in campaign.crew:
		if record.is_active() and not record.is_player and record.assigned_module < 0:
			team.append(record)
	if team.is_empty():
		# Nobody spare: the station crews fix their own modules, slowly.
		for record: CrewRecord in campaign.crew:
			if record.is_active() and not record.is_player:
				team.append(record)
	team.sort_custom(func(a: CrewRecord, b: CrewRecord) -> bool: return a.skills[CrewRecord.REPAIR] > b.skills[CrewRecord.REPAIR])
	var speed := 1.25 if state.combat_power else 1.0
	for module: ModuleState in broken:
		if team.is_empty():
			break
		var work := 0.0
		for n: int in mini(module.max_repair_crew(), team.size()):
			var record: CrewRecord = team.pop_front()
			work += record.skill_speed(CrewRecord.REPAIR) * delta * speed
			record.train(CrewRecord.REPAIR, delta * 0.2)
		module.repair_progress += work
		if module.repair_progress < module.repair_time():
			continue
		if encounter == Encounter.COMBAT:
			module.online = true
			module.repair_progress = 0.0
			campaign.post("%s back online." % module.get_module_name())
		elif campaign.maintain_module(module).is_empty():
			campaign.post("%s repaired and maintained." % module.get_module_name())
		else:
			module.repair_progress = module.repair_time()
	_sync_timer = 0.0


## Too few crew to man the bridge, reactor and engines at once for too long loses the engagement.
func _check_undercrewed(delta: float) -> void:
	var state: ShipState = campaign.ship
	var manned := true
	for i: int in state.modules.size():
		if state.modules[i].is_essential() and not state.is_manned(i, campaign.crew):
			manned = false
	if manned:
		undercrewed_time = 0.0
		return
	undercrewed_time += delta
	if undercrewed_time >= campaign.config.undercrewed_loss_seconds and encounter == Encounter.COMBAT:
		undercrewed_time = 0.0
		_lose_engagement(boarding_hull if boarding_hull else _nearest_hostile(), "Too few crew to run the ship!")

#endregion


#region Encounters

func _update_encounters(delta: float) -> void:
	var player_pos := hull.get_world_position() if hull else Vector2.ZERO
	var any_in_range := false
	for node: Node in get_tree().get_nodes_in_group(ShipHull.GROUP):
		var other := node as ShipHull
		if other == null or other == hull or other.is_destroyed or other.faction == &"player":
			continue
		var info: Dictionary = contacts.get(other, {})
		if info.is_empty():
			info = {"state": &"unseen", "close_time": 0.0}
			contacts[other] = info
		if info.state == &"neutral" or info.state == &"fled":
			continue
		var reach := maxf(_max_range(other), _max_range(hull)) * COMBAT_MARGIN
		var distance := player_pos.distance_to(other.get_world_position())
		if distance > reach:
			continue
		if info.state == &"unseen":
			_first_contact(other, info)
		if info.state == &"hostile":
			any_in_range = true
			_check_disengage(other, info)
	if encounter == Encounter.PREPARING:
		prep_left -= delta
		if prep_left <= 0.0:
			_combat_ready()
	if any_in_range and encounter == Encounter.NONE:
		_start_prep()
	if encounter == Encounter.COMBAT:
		if any_in_range:
			_stand_down_timer = 0.0
		else:
			_stand_down_timer += delta
			if _stand_down_timer >= STAND_DOWN_SECONDS:
				_stand_down()
		_track_player_fire()
		_pursue(delta)
		_check_boarding(delta)
	_refresh_overlay()


func _max_range(target_hull: ShipHull) -> float:
	var best := 600.0
	for weapon: WeaponModule in target_hull.get_weapons():
		best = maxf(best, weapon.max_range)
	return best


func _first_contact(other: ShipHull, info: Dictionary) -> void:
	var faction: int = other.get_meta(&"campaign_faction", PlanetSite.Faction.NONE)
	if faction == PlanetSite.Faction.PIRATES or faction == PlanetSite.Faction.DARK_LIGHT:
		# Pirates only go after ships that look weaker than them, and only want supplies and valuables.
		var readiness: float = campaign.ship.combat_readiness(campaign.crew)
		if faction == PlanetSite.Faction.PIRATES and readiness > 0.8 and campaign.ship.firepower() >= 4.0:
			info.state = &"neutral"
			campaign.post("%s shadows us, then thinks better of it." % other.display_name)
			return
		var demand := maxf(5.0, roundf(campaign.stores.supplies * campaign.config.pirate_demand_share))
		if faction == PlanetSite.Faction.DARK_LIGHT:
			demand = maxf(10.0, roundf(campaign.stores.supplies * 0.4))
		info.state = &"demand"
		info.demand = demand
		demand_hull = other
		encounter = Encounter.DEMAND
		get_tree().paused = true
		campaign.post("%s hails us: hand over %.0f supplies or be boarded." % [other.display_name, demand], 1)
	else:
		# Void Intruders and automated defences don't talk.
		info.state = &"hostile"
		campaign.post("%s is attacking!" % other.display_name, 2)
	encounter_changed.emit()


func answer_demand(pay: bool) -> void:
	if demand_hull == null or not is_instance_valid(demand_hull):
		encounter = Encounter.NONE
		get_tree().paused = false
		return
	var info: Dictionary = contacts[demand_hull]
	get_tree().paused = false
	if pay and campaign.stores.spend(ShipStores.SUPPLIES, info.demand):
		info.state = &"neutral"
		campaign.post("Paid %.0f supplies. They let us pass." % info.demand)
		encounter = Encounter.NONE
	else:
		info.state = &"hostile"
		demand_hull.faction = Constants.ENEMY_GROUP
		campaign.post("Demand refused. All hands to combat stations!", 2)
		encounter = Encounter.NONE
		_start_prep()
	demand_hull = null
	encounter_changed.emit()


## Crew bring the engines and reactor up to combat status, and load the weapons from Supplies.
func _start_prep() -> void:
	if encounter == Encounter.PREPARING or encounter == Encounter.COMBAT:
		return
	encounter = Encounter.PREPARING
	prep_left = campaign.config.combat_prep_seconds
	casualties = {"injured": 0, "dead": 0}
	load_weapons()
	encounter_changed.emit()


func load_weapons() -> bool:
	var state: ShipState = campaign.ship
	if state.weapons_loaded:
		return true
	var cost := 0.0
	for module: ModuleState in state.modules:
		if module.is_weapon():
			cost += module.design.size
	if campaign.stores.spend(ShipStores.SUPPLIES, cost):
		state.weapons_loaded = true
		campaign.post("Weapons loaded (%.0f supplies)." % cost)
		return true
	campaign.post("Not enough supplies to load the weapons!", 2)
	return false


func _combat_ready() -> void:
	encounter = Encounter.COMBAT
	campaign.ship.enter_combat_power()
	campaign.post("Combat power. Weapons free.", 1)
	_stand_down_timer = 0.0
	_sync_timer = 0.0
	encounter_changed.emit()


func _stand_down() -> void:
	encounter = Encounter.NONE
	campaign.ship.leave_combat_power()
	boarding_countdown = -1.0
	boarding_hull = null
	campaign.post("No hostiles in range. Standing down from combat power.")
	_store_armor()
	campaign.autosave()
	encounter_changed.emit()


## Enemies that are badly hurt, or losing the exchange, break off and turn neutral.
func _check_disengage(other: ShipHull, info: Dictionary) -> void:
	var count := other.get_module_count()
	var offline := other.get_offline_modules().size()
	if count > 0 and (float(offline) / count > 0.45 or other.get_armor_integrity() < 0.25 or not other.is_in_command()):
		info.state = &"fled"
		other.faction = &""
		campaign.post("%s breaks off and disengages." % other.display_name, 1)


func _track_player_fire() -> void:
	var manager := SpaceCombatManager.find(get_tree())
	if manager == null:
		return
	var count := 0
	for munition: Munition in manager.get_munitions():
		if munition.faction == &"player":
			count += 1
	if count > _player_munitions:
		_last_fire_time = _time
	_player_munitions = count


## Gunships close in on the player to board (matching velocity, then closing).
func _pursue(delta: float) -> void:
	_pursuit_timer -= delta
	if _pursuit_timer > 0.0:
		return
	_pursuit_timer = PURSUIT_INTERVAL
	for other: Variant in contacts:
		if not is_instance_valid(other) or contacts[other].state != &"hostile":
			continue
		var enemy_ship := (other as ShipHull).host as Spaceship
		if enemy_ship == null or enemy_ship is OrbitalPlatform or enemy_ship.is_burning():
			continue
		var faction: int = other.get_meta(&"campaign_faction", PlanetSite.Faction.NONE)
		if faction != PlanetSite.Faction.PIRATES and faction != PlanetSite.Faction.DARK_LIGHT:
			continue
		var relative := ship.get_state_position() - enemy_ship.get_state_position()
		var want := ship.get_state_velocity() + relative.normalized() * minf(PURSUIT_SPEED, relative.length() * 0.05)
		var delta_v := want - enemy_ship.get_state_velocity()
		if delta_v.length() > 0.05:
			enemy_ship.execute_burn(delta_v)


## The boarding countdown (Orbital Gameplay, Loss): an attacker within boarding distance for the countdown while its
## drive and weapons work and the player's drive is out or the player is not shooting back. A healthy ship can let
## this happen on purpose (a faux surrender).
func _check_boarding(delta: float) -> void:
	var near := _nearest_hostile()
	var player_pos := hull.get_world_position()
	var ready_to_board := false
	if near and near.get_world_position().distance_to(player_pos) <= campaign.config.boarding_distance_m:
		var enemy_drive := near.get_main_drive() != null
		var enemy_armed := false
		for weapon: WeaponModule in near.get_weapons():
			if weapon.is_operational():
				enemy_armed = true
		var player_drive := hull.get_main_drive() != null
		var player_firing: bool = _time - _last_fire_time < campaign.config.boarding_countdown_seconds
		ready_to_board = enemy_drive and enemy_armed and (not player_drive or not player_firing)
	if not ready_to_board:
		boarding_countdown = -1.0
		boarding_hull = null
		return
	if boarding_countdown < 0.0:
		boarding_countdown = campaign.config.boarding_countdown_seconds
		boarding_hull = near
		campaign.post("%s is moving to board! Surrender or fight back." % near.display_name, 2)
	boarding_countdown -= delta
	if boarding_countdown <= 0.0:
		_lose_engagement(near, "")


func _nearest_hostile() -> ShipHull:
	var best: ShipHull = null
	var best_d := INF
	var player_pos := hull.get_world_position()
	for other: Variant in contacts:
		if not is_instance_valid(other) or contacts[other].state != &"hostile" or (other as ShipHull).is_destroyed:
			continue
		var d: float = (other as ShipHull).get_world_position().distance_to(player_pos)
		if d < best_d:
			best_d = d
			best = other
	return best


## Lost the engagement without surrendering: boarded. Void Intruders just pepper the ship and leave.
func _lose_engagement(attacker: ShipHull, reason: String) -> void:
	boarding_countdown = -1.0
	if reason:
		campaign.post(reason, 2)
	if attacker == null:
		return
	var faction: int = attacker.get_meta(&"campaign_faction", PlanetSite.Faction.NONE)
	if faction != PlanetSite.Faction.PIRATES and faction != PlanetSite.Faction.DARK_LIGHT:
		for i: int in 4:
			hull.take_hit(4, ArmorGrid.DamageProfile.KINETIC)
		contacts[attacker].state = &"fled"
		attacker.faction = &""
		campaign.post("%s rakes the hull with fire and veers away." % attacker.display_name, 2)
		return
	_store_armor()
	campaign.ship.leave_combat_power()
	site.enemy_ships = maxi(0, site.enemy_ships - 1)
	var boarders: int = 4 + (2 if faction == PlanetSite.Faction.DARK_LIGHT else 0) + campaign.ship.rng.randi_range(0, 3)
	campaign.pending_expedition = {"site": site.id, "boarding": true, "boarders": boarders, "members": [],
		"boarder_faction": faction}
	campaign.set_phase(campaign.Phase.EXPEDITION)
	get_tree().paused = false
	campaign.go_to_phase_scene()


## The player can surrender at any time: pirates take what they came for and leave.
func surrender() -> void:
	var attacker := demand_hull if demand_hull else _nearest_hostile()
	get_tree().paused = false
	var faction: int = attacker.get_meta(&"campaign_faction", PlanetSite.Faction.NONE) if attacker else PlanetSite.Faction.NONE
	if faction == PlanetSite.Faction.VOID or faction == PlanetSite.Faction.NONE:
		campaign.post("There is no one to surrender to.", 1)
		return
	campaign.apply_loss_penalty(faction == PlanetSite.Faction.DARK_LIGHT)
	for other: Variant in contacts:
		if is_instance_valid(other) and other.get_meta(&"campaign_faction", -1) == faction:
			contacts[other].state = &"neutral"
			other.faction = &""
	demand_hull = null
	encounter = Encounter.NONE
	campaign.ship.leave_combat_power()
	boarding_countdown = -1.0
	campaign.post("We surrendered.", 2)
	campaign.check_game_over()
	encounter_changed.emit()

#endregion


#region Salvage

## Salvaging a debris field: time spent there turns supplies into metal, better in dense fields of big pieces.
func salvage_field() -> SpaceBattlefield:
	if hull == null:
		return null
	for anchor_name: String in ["LowOrbitDebris", "RetrogradeDebris", "OldBattlefield", "ShatteredTanker"]:
		var anchor := planet_body.get_node_or_null(anchor_name) if planet_body else null
		if anchor == null or anchor.is_queued_for_deletion():
			continue
		var field := anchor.get_node_or_null("Field") as SpaceBattlefield
		if field == null:
			continue
		var centre := SpaceScale.to_world(field.global_position)
		if hull.get_world_position().distance_to(centre) <= field.radius:
			return field
	return null


func _update_salvage(delta: float) -> void:
	if not salvaging:
		return
	var field := salvage_field()
	if field == null or encounter == Encounter.COMBAT:
		salvaging = false
		campaign.post("Salvage stopped.")
		return
	var size: int = field.get_meta(&"particle_size", 1)
	var rate := 0.25 * delta * (0.5 + size * 0.35)
	if campaign.stores.cargo_free() <= 0.0 or not campaign.stores.spend(ShipStores.SUPPLIES, rate * 0.6):
		salvaging = false
		campaign.post("Salvage stopped: no supplies or no hold space.")
		return
	campaign.stores.add(ShipStores.METAL, rate)

#endregion


#region Overlay

func _build_overlay() -> void:
	_overlay = CanvasLayer.new()
	_overlay.layer = 20
	_overlay.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_overlay)
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.06, 0.05, 0.1, 0.9)
	style.border_color = Color(1.0, 0.5, 0.3)
	style.set_border_width_all(2)
	style.set_content_margin_all(10)
	style.set_corner_radius_all(6)
	panel.add_theme_stylebox_override("panel", style)
	panel.position = Vector2(700, 60)
	panel.custom_minimum_size = Vector2(520, 0)
	_overlay.add_child(panel)
	_overlay_box = VBoxContainer.new()
	panel.add_child(_overlay_box)
	_overlay_label = RichTextLabel.new()
	_overlay_label.bbcode_enabled = true
	_overlay_label.fit_content = true
	_overlay_label.custom_minimum_size = Vector2(500, 0)
	_overlay_box.add_child(_overlay_label)
	_overlay_buttons = HBoxContainer.new()
	_overlay_box.add_child(_overlay_buttons)
	panel.visible = false


func _refresh_overlay() -> void:
	if _overlay_box == null:
		return
	var panel := _overlay_box.get_parent() as Control
	var lines: PackedStringArray = []
	var buttons: Array = []
	match encounter:
		Encounter.DEMAND:
			var info: Dictionary = contacts.get(demand_hull, {})
			lines.append("[b]%s[/b] demands %.0f supplies (we have %.0f)." % [demand_hull.display_name if demand_hull else "?",
				info.get("demand", 0.0), campaign.stores.supplies])
			lines.append("Pay and they let us pass. Refuse and they attack, and try to board us.")
			buttons = [["Pay", answer_demand.bind(true)], ["Refuse", answer_demand.bind(false)]]
		Encounter.PREPARING:
			lines.append("[b]Preparing for combat[/b]: engines and reactor to combat power in %.0f s" % prep_left)
			lines.append("Weapons %s." % ("loaded" if campaign.ship.weapons_loaded else "NOT loaded"))
			buttons = [["Surrender", surrender]]
		Encounter.COMBAT:
			var readiness: float = campaign.ship.combat_readiness(campaign.crew)
			lines.append("[b]COMBAT[/b]  Readiness %d%%  Armor %d%%  Casualties: %d injured, %d dead" % [roundi(readiness * 100.0),
				roundi(hull.get_armor_integrity() * 100.0), casualties.injured, casualties.dead])
			var offline: PackedStringArray = []
			for module: ModuleState in campaign.ship.modules:
				if not module.online:
					offline.append(module.get_module_name())
			if offline.size():
				lines.append("[color=#ff8866]Offline: %s[/color]" % ", ".join(offline))
			if boarding_countdown >= 0.0:
				lines.append("[color=#ff4444][b]BOARDING IN %.1f s[/b][/color] - fire on them, burn away, or surrender." % boarding_countdown)
			if undercrewed_time > 0.0:
				lines.append("[color=#ff4444]Essential stations unmanned! %.0f s[/color]" % (campaign.config.undercrewed_loss_seconds - undercrewed_time))
			buttons = [["Surrender", surrender]]
	panel.visible = not lines.is_empty()
	if not panel.visible:
		return
	_overlay_label.text = "\n".join(lines)
	var key := ",".join(buttons.map(func(b: Array) -> String: return b[0]))
	if _overlay_buttons.get_meta(&"key", "") != key:
		_overlay_buttons.set_meta(&"key", key)
		for child: Node in _overlay_buttons.get_children():
			child.queue_free()
		for entry: Array in buttons:
			var button := Button.new()
			button.text = entry[0]
			button.focus_mode = Control.FOCUS_NONE
			button.pressed.connect(entry[1])
			_overlay_buttons.add_child(button)


func _on_message(text: String, severity: int) -> void:
	var manager := SpaceCombatManager.find(get_tree())
	if manager and severity > 0:
		manager.raise_warning(text, SpaceCombatManager.Severity.CAUTION if severity == 1 else SpaceCombatManager.Severity.DANGER)

#endregion
