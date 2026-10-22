## Autoload "Campaign": the state of the current run and the rules that tie its layers together (Development Overview).
## FTL map -> orbit around a planet -> expedition on its surface, and back. Holds the ship's stores, modules and crew,
## the star map, checks the win and lose conditions, routes Twitch chat commands to crewmembers and saves the run
## through the SaveSystem autoload.
extends Node

signal stores_changed
signal crew_changed
signal phase_changed(phase: Phase)
signal message_posted(text: String, severity: int)
## A crewmember said something in Twitch chat (shown as a speech bubble and in the communicator).
signal crew_said(record: CrewRecord, text: String)
## A chat-controlled crewmember typed !retreat.
signal retreat_requested(record: CrewRecord)
signal stance_changed(record: CrewRecord)
signal game_over(victory: bool, reason: String)

enum Phase { NONE, INTRO, FTL_MAP, ORBIT, EXPEDITION, GAME_OVER, VICTORY }
## Where the ship is in a system's orbital flow (Orbital Game Flow).
enum OrbitStage { FTL_LIMIT, IN_TRANSIT, LOW_ORBIT, FLYBY }

const PHASE_NAMES := ["None", "Intro", "FTL map", "Orbit", "Expedition", "Game over", "Victory"]
const SAVE_KEY := "campaign"
const SAVE_VERSION := 1
const CONFIG_PATH := "res://data/game_config.tres"

const SCENE_TITLE := "res://ui/title_screen/title_screen.tscn"
const SCENE_FTL_MAP := "res://ui/ftl_map/ftl_map.tscn"
const SCENE_ORBIT := "res://ui/ship_console/ship_hud.tscn"
const SCENE_EXPEDITION := "res://world/expedition/expedition.tscn"
const SCENE_PLANNER := "res://ui/expedition_planner/expedition_planner.tscn"
const SCENE_GAME_OVER := "res://ui/game_over/game_over.tscn"

const STANCE_COMMANDS := ["!explore", "!defend", "!attack", "!rescue", "!heal", "!medic"]
const RETREAT_COMMAND := "!retreat"

var config: GameConfig
var stores: ShipStores
var ship: ShipState
var crew: Array[CrewRecord] = []
var star_map: StarMap
var phase: Phase = Phase.NONE
var orbit_stage: OrbitStage = OrbitStage.FTL_LIMIT
## Seconds of orbital time since the run started.
var orbital_time: float = 0.0
var run_seed: int = 0
var next_crew_id: int = 1
## What the next expedition scene should run: see start_expedition.
var pending_expedition: Dictionary = {}
var game_over_reason: String = ""
var log_lines: PackedStringArray = []
## A run is in progress (new game started or a save loaded).
var active: bool = false
## Twitch chat routing is on (off in tests).
var listen_to_chat: bool = true

var _syncing_roster := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	config = load(CONFIG_PATH) as GameConfig if ResourceLoader.exists(CONFIG_PATH) else GameConfig.new()
	_reset_state()
	var save_system: Node = get_node_or_null("/root/SaveSystem")
	if save_system:
		save_system.save_requested.connect(_on_save_requested)
		save_system.load_requested.connect(_on_load_requested)
	var roster: Node = _roster()
	if roster:
		roster.roster_changed.connect(sync_roster)
	var twitch: Node = get_node_or_null("/root/VerySimpleTwitch")
	if twitch:
		twitch.chat_message_received.connect(_on_chat_message)


func _reset_state() -> void:
	stores = ShipStores.new(config)
	stores.changed.connect(func() -> void: stores_changed.emit())
	ship = ShipState.new(config)
	crew.clear()
	star_map = StarMap.new()
	phase = Phase.NONE
	orbit_stage = OrbitStage.FTL_LIMIT
	orbital_time = 0.0
	pending_expedition = {}
	game_over_reason = ""
	log_lines.clear()
	next_crew_id = 1
	active = false


#region New game

## Starts a new run: the main character on the starting planet, about to fight through the intro dungeon to the ship.
func new_game(game_seed: int = 0) -> void:
	_reset_state()
	run_seed = game_seed if game_seed != 0 else randi()
	var rng := RandomNumberGenerator.new()
	rng.seed = run_seed
	star_map = StarMap.generate(config.map_systems, rng.randi())
	ship = ShipState.create_starting_ship(config)
	ship.malfunction_occurred.connect(_on_malfunction)
	stores.fuel_tanks = config.start_fuel_tanks
	stores.cargo_holds = config.start_cargo_holds
	stores.fuel = config.start_fuel
	stores.metal = config.start_metal
	stores.supplies = config.start_supplies
	var hero := CrewRecord.new(config)
	hero.id = _take_crew_id()
	hero.display_name = "Captain"
	hero.is_player = true
	hero.special = true
	hero.skills[CrewRecord.COMBAT] = 1.0
	hero.loadout = [&"natural_claws", &"dash"]
	hero.color = Color(1.0, 0.85, 0.4)
	hero.rebuild_body()
	crew.append(hero)
	active = true
	set_phase(Phase.INTRO)
	# The intro dungeon is the starting planet's expedition: the crew imprisoned there are rescued on the way out.
	var start := star_map.get_current()
	start.crew = maxi(start.crew, config.intro_rescued_crew)
	pending_expedition = {"site": start.id, "members": [hero.id], "intro": true, "flyby_seconds": 0.0,
		"boarding": false}
	post("You wake on %s. Fight your way to the ship." % start.name)
	crew_changed.emit()
	stores_changed.emit()


## A prisoner freed on an expedition joins the crew as they are (injuries and all).
func add_rescued(record: CrewRecord) -> void:
	record.id = _take_crew_id()
	record.config = config
	record.status = CrewRecord.Status.HEALING if record.body.healing_needed() > 0.5 else CrewRecord.Status.ACTIVE
	if record.body.dead:
		return
	crew.append(record)
	sync_roster()
	crew_changed.emit()


func _take_crew_id() -> int:
	next_crew_id += 1
	return next_crew_id - 1


## A new generic crewmember (rescued from a dungeon, found on a planet).
func recruit(kind: int = -1, rng: RandomNumberGenerator = null) -> CrewRecord:
	if rng == null:
		rng = RandomNumberGenerator.new()
		rng.randomize()
	var record := CrewRecord.generate(config, rng, _take_crew_id())
	if kind >= 0:
		PlanetRules.apply_crew_bonus(kind as PlanetType.Kind, record)
	crew.append(record)
	sync_roster()
	crew_changed.emit()
	return record

#endregion


#region Phases and scenes

func set_phase(new_phase: Phase) -> void:
	phase = new_phase
	phase_changed.emit(phase)


func scene_for_phase() -> String:
	match phase:
		Phase.INTRO, Phase.EXPEDITION:
			return SCENE_EXPEDITION
		Phase.FTL_MAP:
			return SCENE_FTL_MAP
		Phase.ORBIT:
			return SCENE_ORBIT
		Phase.GAME_OVER, Phase.VICTORY:
			return SCENE_GAME_OVER
	return SCENE_TITLE


## Changes to the scene of the current phase (with the GameManager fade when it is there).
func go_to_phase_scene() -> void:
	change_scene(scene_for_phase())


func change_scene(path: String) -> void:
	var manager: Node = get_node_or_null("/root/GameManager")
	if manager and manager.has_method("change_scene"):
		manager.change_scene(path)
	else:
		get_tree().change_scene_to_file(path)


## Jumps to another system. Returns "" on success or why the jump can't be made.
func ftl_jump(site_id: int) -> String:
	var site := star_map.get_site(site_id)
	if site == null:
		return "No such system"
	if not star_map.in_range(star_map.current, site_id):
		return "Out of FTL range"
	if orbit_stage != OrbitStage.FTL_LIMIT and phase == Phase.ORBIT:
		return "Return to the FTL limit first"
	var cost := star_map.jump_cost(star_map.current, site_id, config, stores.mass())
	if not stores.spend(ShipStores.FUEL, cost):
		return "Not enough fuel (%.0f needed)" % cost
	star_map.current = site_id
	site.visited = true
	orbit_stage = OrbitStage.FTL_LIMIT
	post("Jumped to %s for %.0f fuel." % [site.name, cost])
	set_phase(Phase.ORBIT)
	autosave()
	check_game_over()
	return ""


## Reached the planet: orbital insertion (stays as long as wanted) or a low flyby (the expedition gets a time limit).
func reach_low_orbit(flyby: bool) -> void:
	orbit_stage = OrbitStage.FLYBY if flyby else OrbitStage.LOW_ORBIT
	post("%s %s." % ["Low flyby of" if flyby else "Entered low orbit of", star_map.get_current().name])
	check_game_over()


func leave_low_orbit() -> void:
	orbit_stage = OrbitStage.IN_TRANSIT


## Back at the FTL limit: the FTL map opens.
func reach_ftl_limit() -> void:
	orbit_stage = OrbitStage.FTL_LIMIT
	set_phase(Phase.FTL_MAP)
	autosave()
	check_game_over()


func is_in_low_orbit() -> bool:
	return orbit_stage == OrbitStage.LOW_ORBIT or orbit_stage == OrbitStage.FLYBY

#endregion


#region Expeditions

## Supplies and metal an expedition with these members and armor costs.
func expedition_cost(member_count: int, armored: int) -> Dictionary:
	var site := star_map.get_current()
	var supplies := member_count * config.supplies_per_kit
	if site and PlanetRules.get_rule(site.kind, "needs_oxygen", false):
		supplies += member_count * config.oxygen_supplies_per_member
	return {"supplies": supplies, "metal": armored * config.metal_per_armor}


func can_start_expedition() -> String:
	var site := star_map.get_current()
	if site == null:
		return "No planet here"
	if not is_in_low_orbit():
		return "Reach low orbit first"
	if site.expedition_done:
		return "This planet's expedition is done"
	if stores.supplies < expedition_cost(1, 0).supplies:
		return "Not enough supplies for expedition gear"
	return ""


## Launches an expedition with the given crew (ids, at most max_expedition_crew besides the player) and pays for the
## gear: ammunition, medical kits and oxygen cost supplies; armor costs metal.
func start_expedition(member_ids: Array, armored_ids: Array = [], boarding: bool = false) -> String:
	var reason := "" if boarding else can_start_expedition()
	if reason:
		return reason
	var members: Array = []
	for record: CrewRecord in crew:
		if record.is_player or (member_ids.has(record.id) and record.is_active()):
			members.append(record.id)
	members = members.slice(0, config.max_expedition_crew + 1)
	var armored := armored_ids.filter(func(id: int) -> bool: return members.has(id))
	var cost := expedition_cost(members.size(), armored.size())
	if not boarding:
		if stores.supplies < cost.supplies or stores.metal < cost.metal:
			return "Not enough supplies or metal for that loadout"
		stores.spend(ShipStores.SUPPLIES, cost.supplies)
		stores.spend(ShipStores.METAL, cost.metal)
	pending_expedition = {
		"site": star_map.current, "members": members, "armored": armored, "intro": false, "boarding": boarding,
		"flyby_seconds": config.flyby_expedition_seconds if orbit_stage == OrbitStage.FLYBY else 0.0,
	}
	set_phase(Phase.EXPEDITION)
	return ""


## Results of an expedition: {fuel, metal, supplies, crew_rescued, cores, cache_info, completed, members: [ids]}.
## Loot beyond capacity is left behind. Injured crew go to the medical bay.
func finish_expedition(result: Dictionary) -> Dictionary:
	var site := star_map.get_site(int(pending_expedition.get("site", star_map.current)))
	var stored := {}
	for resource: StringName in ShipStores.ALL:
		var amount := float(result.get(String(resource), 0.0))
		stored[resource] = stores.add(resource, amount)
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var rescued_records: Array = result.get("rescued_records", [])
	var rescued := rescued_records.size()
	for record: Variant in rescued_records:
		add_rescued(record)
	for i: int in maxi(0, int(result.get("crew_rescued", 0)) - rescued):
		recruit(site.kind if site else -1, rng)
		rescued += 1
	var intro := bool(pending_expedition.get("intro", false))
	if intro:
		# Survivors who hid aboard the ship make sure there is a crew to fly it.
		var hid := 0
		while rescued_crew_count() < ship.essential_crew_required() + 1:
			recruit(-1, rng)
			hid += 1
		if hid:
			post("%d survivor%s hiding aboard the ship join the crew." % [hid, "s" if hid > 1 else ""])
	if site and bool(result.get("completed", false)):
		site.expedition_done = true
	if site:
		site.fuel = maxf(0.0, site.fuel - float(result.get("fuel", 0.0)))
		site.metal = maxf(0.0, site.metal - float(result.get("metal", 0.0)))
		site.supplies = maxf(0.0, site.supplies - float(result.get("supplies", 0.0)))
		site.crew = maxi(0, site.crew - rescued)
	var info := int(result.get("cache_info", 0))
	if info > 0:
		_reveal_caches(info)
	for i: int in int(result.get("cores", 0)):
		_store_core(rng)
	for record: CrewRecord in crew:
		if record.is_alive() and record.body.dead:
			kill(record, "died on the expedition")
		elif record.is_alive() and record.body.healing_needed() > 0.5:
			record.status = CrewRecord.Status.HEALING
	pending_expedition = {}
	post("Expedition back: +%.0f fuel, +%.0f metal, +%.0f supplies, %d rescued." % [
		stored[ShipStores.FUEL], stored[ShipStores.METAL], stored[ShipStores.SUPPLIES], rescued])
	if intro:
		post("The ship is yours. Climbing to low orbit.")
		orbit_stage = OrbitStage.LOW_ORBIT
	set_phase(Phase.ORBIT)
	crew_changed.emit()
	autosave()
	check_game_over()
	return stored


## A boarding action is over: repelled, or lost (the enemy takes resources and maybe non-essential modules).
func finish_boarding(result: Dictionary) -> void:
	for record: CrewRecord in crew:
		if record.is_alive() and record.body.dead:
			kill(record, "died repelling boarders")
		elif record.is_alive() and record.body.healing_needed() > 0.5:
			record.status = CrewRecord.Status.HEALING
	if not bool(result.get("repelled", false)):
		apply_loss_penalty(true)
	else:
		post("Boarders repelled.")
	pending_expedition = {}
	set_phase(Phase.ORBIT)
	crew_changed.emit()
	check_game_over()


## Penalties of losing an engagement (Orbital Game Flow): resources lost, and in the harsher case non-essential
## modules torn out as well.
func apply_loss_penalty(harsh: bool) -> void:
	var supplies := stores.drain(ShipStores.SUPPLIES, stores.supplies * config.surrender_supplies_share)
	var metal := stores.drain(ShipStores.METAL, stores.metal * config.surrender_metal_share)
	var text := "Lost %.0f supplies and %.0f metal." % [supplies, metal]
	if harsh:
		var candidates: Array[ModuleState] = []
		for module: ModuleState in ship.modules:
			if not module.is_essential() and module.get_kind() not in [ShipModule.Kind.STRUCTURE, ShipModule.Kind.FUEL_TANK]:
				candidates.append(module)
		if not candidates.is_empty():
			var taken: ModuleState = candidates[randi() % candidates.size()]
			ship.remove(taken)
			text += " They stripped the %s." % taken.get_module_name()
	post(text, 2)


## Module cores recovered on expeditions wait in the hold until installed (see install_core).
var stored_cores: Array[Dictionary] = []


func _store_core(rng: RandomNumberGenerator) -> void:
	var options := ["res://data/components/sensors.tres", "res://data/components/torpedo_tubes.tres",
		"res://data/components/railgun.tres", "res://data/components/reactor.tres",
		"res://data/components/medical_bay.tres", "res://data/components/combat_implant_station.tres",
		"res://data/engines/ion_engine.tres", "res://data/engines/chemical_rocket.tres"]
	var path: String = options[rng.randi() % options.size()]
	var design := load(path) as ShipModule
	stored_cores.append({"design": path, "manufacturer": String(Manufacturers.random_for(design.kind, rng)),
		"military": rng.randf() < 0.15})


## Installs a stored module core for metal (its size times the storage build cost / 2).
func install_core(index: int) -> String:
	if index < 0 or index >= stored_cores.size():
		return "No such core"
	var entry := stored_cores[index]
	var design := load(entry.design) as ShipModule
	var cost := design.size * config.storage_build_cost * 0.5
	if not stores.spend(ShipStores.METAL, cost):
		return "Needs %.0f metal" % cost
	ship.install(ModuleState.create(entry.design, StringName(entry.manufacturer), config, entry.military))
	stored_cores.remove_at(index)
	post("Installed %s." % design.name)
	return ""


func _reveal_caches(count: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var candidates: Array[PlanetSite] = []
	for site: PlanetSite in star_map.sites:
		if site.caches > site.known_caches:
			candidates.append(site)
	for i: int in count:
		if candidates.is_empty():
			break
		var site: PlanetSite = candidates[rng.randi() % candidates.size()]
		site.known_caches += 1
		post("Ship log: a cache on a satellite of %s." % site.name)
		if site.known_caches >= site.caches:
			candidates.erase(site)

#endregion


#region Crew

func get_record(record_id: int) -> CrewRecord:
	for record: CrewRecord in crew:
		if record.id == record_id:
			return record
	return null


func get_player() -> CrewRecord:
	for record: CrewRecord in crew:
		if record.is_player:
			return record
	return null


func living_crew() -> Array[CrewRecord]:
	var result: Array[CrewRecord] = []
	for record: CrewRecord in crew:
		if record.is_alive():
			result.append(record)
	return result


func active_crew() -> Array[CrewRecord]:
	var result: Array[CrewRecord] = []
	for record: CrewRecord in crew:
		if record.is_active():
			result.append(record)
	return result


## Crew that count for the jump home: everyone alive but the main character.
func rescued_crew_count() -> int:
	var count := 0
	for record: CrewRecord in crew:
		if record.is_alive() and not record.is_player:
			count += 1
	return count


## A crewmember died. A chatter's slot is lost: they go to the back of the queue.
func kill(record: CrewRecord, reason: String = "") -> void:
	if not record.is_alive():
		return
	record.status = CrewRecord.Status.DEAD
	record.body.die()
	post("%s %s." % [record.get_shown_name(), reason if reason else "died"], 2)
	if record.is_chat_controlled():
		var roster := _roster()
		if roster and roster.has_method("send_to_back"):
			roster.send_to_back(record.controller_id)
		record.controller_id = ""
	sync_roster()
	crew_changed.emit()


## Matches Twitch chatters on the crew roster to crewmembers. Each generic crewmember is a slot.
func sync_roster() -> void:
	var roster := _roster()
	if roster == null or _syncing_roster:
		return
	_syncing_roster = true
	var slots := 0
	for record: CrewRecord in crew:
		if record.is_alive() and not record.special:
			slots += 1
	if roster.crew_size != slots:
		roster.crew_size = slots
	var on_crew := {}
	for member: Variant in roster.get_crew():
		on_crew[member.user_id] = member
	# Release crewmembers whose chatter left (lurked or went stale): they become NPCs again.
	for record: CrewRecord in crew:
		if record.is_chat_controlled() and (not on_crew.has(record.controller_id) or not record.is_alive()):
			record.controller_id = ""
			record.controller_name = ""
	var controlled := {}
	for record: CrewRecord in crew:
		if record.is_chat_controlled():
			controlled[record.controller_id] = record
	for user_id: String in on_crew:
		if controlled.has(user_id):
			continue
		var member: Variant = on_crew[user_id]
		for record: CrewRecord in crew:
			if record.is_alive() and not record.special and not record.is_chat_controlled():
				record.controller_id = user_id
				record.controller_name = member.display_name
				if member.color_hex:
					record.color = Color.from_string(member.color_hex, record.color)
				break
	_syncing_roster = false
	crew_changed.emit()


func _roster() -> Node:
	return get_node_or_null("/root/Crew")


func _on_chat_message(chatter: Variant) -> void:
	if not listen_to_chat:
		return
	var user_id: String = chatter.tags.user_id if chatter.tags.user_id else chatter.login
	handle_chat(user_id, chatter.login, chatter.message)


## Routes a chat message: stance commands, !retreat, special characters matched by name, and speech.
func handle_chat(user_id: String, login: String, message: String) -> void:
	var record := _record_for_chatter(user_id, login)
	if record == null:
		return
	var text := message.strip_edges()
	var words := text.split(" ", false)
	var command := words[0].to_lower() if words.size() else ""
	if command in STANCE_COMMANDS:
		record.set_stance_from_command(command, words[1] if words.size() > 1 else "")
		stance_changed.emit(record)
		return
	if command == RETREAT_COMMAND:
		retreat_requested.emit(record)
		return
	if command.begins_with("!"):
		return
	crew_said.emit(record, text)


func _record_for_chatter(user_id: String, login: String) -> CrewRecord:
	for record: CrewRecord in crew:
		if not record.is_alive():
			continue
		if record.controller_id == user_id:
			return record
		# Special characters only answer to a chatter with exactly their name.
		if record.special and not record.is_player and record.display_name.to_lower() == login.to_lower():
			return record
	return null

#endregion


#region Time and the medical bay

## Advances `seconds` of orbital time: maintenance clocks, malfunctions, reactor fuel and medical bay treatment.
func tick_orbit(seconds: float, in_combat: bool = false) -> void:
	if not active or seconds <= 0.0:
		return
	orbital_time += seconds
	var fuel_burn := ship.tick(seconds, in_combat)
	stores.drain(ShipStores.FUEL, fuel_burn)
	_treat_patients(seconds)


func _treat_patients(seconds: float) -> void:
	var medbay_online := false
	for i: int in ship.modules.size():
		var module := ship.modules[i]
		if module.get_kind() == ShipModule.Kind.MEDICAL and module.online:
			medbay_online = true
	var changed := false
	for record: CrewRecord in crew:
		if record.status != CrewRecord.Status.HEALING:
			continue
		if record.body.dead:
			kill(record, "died of their wounds")
			continue
		if not medbay_online:
			# Without a medical bay, wounds only heal naturally (and bleeding still runs its course).
			record.body.step(minf(seconds, 60.0), 0.0)
			continue
		var points := config.medbay_heal_per_hour * seconds / 3600.0
		var cost := points * config.medbay_supplies_per_heal
		if stores.supplies < cost:
			continue
		var used := record.body.medbay_heal(points)
		stores.drain(ShipStores.SUPPLIES, used * config.medbay_supplies_per_heal)
		if record.body.healing_needed() <= 0.5:
			record.status = CrewRecord.Status.ACTIVE
			changed = true
			post("%s is back on duty%s." % [record.get_shown_name(),
				" (needs bionics)" if record.body.needs_augmentation() else ""])
	if changed:
		crew_changed.emit()


## Bionic augmentation for a lost limb or brain below what the medical bay can restore. Costs metal.
func augment(record: CrewRecord) -> String:
	if not record.body.needs_augmentation():
		return "No augmentation needed"
	if not stores.spend(ShipStores.METAL, config.bionic_metal_cost):
		return "Needs %.0f metal" % config.bionic_metal_cost
	record.body.augment()
	if record.status == CrewRecord.Status.HEALING and record.body.healing_needed() <= 0.5:
		record.status = CrewRecord.Status.ACTIVE
	crew_changed.emit()
	return ""


## Maintains a module: supplies for a full service that resets its clock and clears malfunctions.
func maintain_module(module: ModuleState) -> String:
	var cost := module.maintenance_cost()
	if not stores.spend(ShipStores.SUPPLIES, cost):
		return "Needs %.1f supplies" % cost
	module.maintain()
	return ""


## Maintains everything that is due. Returns the number of modules serviced.
func maintain_all() -> int:
	var count := 0
	for module: ModuleState in ship.maintenance_due():
		if maintain_module(module).is_empty():
			count += 1
	return count


func _on_malfunction(_module: ModuleState, _malfunction: ModuleState.Malfunction, text: String) -> void:
	post(text, 1)

#endregion


#region Win and lose

func can_jump_home() -> bool:
	return stores.fuel >= config.fuel_to_win and rescued_crew_count() >= config.crew_to_win


func jump_home() -> String:
	if not can_jump_home():
		return "Need %.0f fuel and %d crew" % [config.fuel_to_win, config.crew_to_win]
	stores.drain(ShipStores.FUEL, config.fuel_to_win)
	end_game(true, "The long range FTL jump charges, and %s heads home to Earth with %d crew." % [ship.name,
		rescued_crew_count()])
	return ""


## The lose conditions (Development Overview, Lose Condition). Returns the reason, or "" while the run goes on.
func lose_reason() -> String:
	if not active or phase in [Phase.INTRO, Phase.GAME_OVER, Phase.VICTORY]:
		return ""
	var crew_count := 0
	for record: CrewRecord in crew:
		if record.is_alive() and not record.is_player:
			crew_count += 1
	if crew_count < ship.essential_crew_required():
		return "Too few crew left to run the bridge, reactor and engines."
	if stores.fuel <= 0.01:
		var site := star_map.get_current()
		if not is_in_low_orbit():
			return "Out of fuel, adrift in space."
		if site and site.expedition_done:
			return "Out of fuel, with nothing left to find on %s." % site.name
		if stores.supplies < expedition_cost(1, 0).supplies:
			return "Out of fuel, and out of supplies to mount an expedition."
	return ""


func check_game_over() -> bool:
	var reason := lose_reason()
	if reason.is_empty():
		return false
	end_game(false, reason)
	return true


func end_game(victory: bool, reason: String) -> void:
	game_over_reason = reason
	set_phase(Phase.VICTORY if victory else Phase.GAME_OVER)
	post(reason, 0 if victory else 2)
	game_over.emit(victory, reason)

#endregion


#region Messages

## Ship log line. Severity 0 info, 1 caution, 2 danger.
func post(text: String, severity: int = 0) -> void:
	log_lines.append(text)
	if log_lines.size() > 200:
		log_lines = log_lines.slice(log_lines.size() - 200)
	message_posted.emit(text, severity)

#endregion


#region Saving

func autosave() -> void:
	var save_system: Node = get_node_or_null("/root/SaveSystem")
	if save_system and active and phase not in [Phase.GAME_OVER, Phase.VICTORY]:
		save_system.save_game(save_system.get_latest_save_or_default())


func has_save() -> bool:
	var save_system: Node = get_node_or_null("/root/SaveSystem")
	if save_system == null:
		return false
	return FileAccess.file_exists(save_system.save_name_to_file_path(save_system.get_latest_save_or_default()))


## Loads the latest save and goes to its scene. Returns an error code.
func continue_game() -> Error:
	var save_system: Node = get_node_or_null("/root/SaveSystem")
	if save_system == null:
		return ERR_UNAVAILABLE
	var error: Error = save_system.load_game(save_system.get_latest_save_or_default())
	if error == OK and active:
		go_to_phase_scene()
	return error


func _on_save_requested(data: Dictionary) -> void:
	if active:
		data[SAVE_KEY] = to_dict()


func _on_load_requested(data: Dictionary) -> void:
	if data.has(SAVE_KEY) and data[SAVE_KEY] is Dictionary:
		load_dict(data[SAVE_KEY])


func to_dict() -> Dictionary:
	var crew_data: Array = []
	for record: CrewRecord in crew:
		crew_data.append(record.to_dict())
	# Saving mid-expedition resumes at the planet, before the expedition launched.
	var saved_phase := phase
	if phase == Phase.EXPEDITION:
		saved_phase = Phase.ORBIT
	return {
		"version": SAVE_VERSION, "seed": run_seed, "phase": saved_phase, "orbit_stage": orbit_stage,
		"orbital_time": orbital_time, "next_crew_id": next_crew_id, "stores": stores.to_dict(),
		"ship": ship.to_dict(), "crew": crew_data, "map": star_map.to_dict(), "cores": stored_cores.duplicate(true),
		"log": Array(log_lines.slice(maxi(0, log_lines.size() - 50))),
		"pending": pending_expedition.duplicate(true) if phase == Phase.INTRO else {},
	}


func load_dict(data: Dictionary) -> void:
	_reset_state()
	run_seed = int(data.get("seed", 0))
	orbit_stage = int(data.get("orbit_stage", OrbitStage.FTL_LIMIT)) as OrbitStage
	orbital_time = float(data.get("orbital_time", 0.0))
	next_crew_id = int(data.get("next_crew_id", 1))
	stores.load_dict(data.get("stores", {}))
	ship = ShipState.from_dict(data.get("ship", {}), config)
	ship.malfunction_occurred.connect(_on_malfunction)
	for entry: Variant in data.get("crew", []):
		if entry is Dictionary:
			crew.append(CrewRecord.from_dict(entry, config))
	star_map = StarMap.from_dict(data.get("map", {}))
	stored_cores.clear()
	for entry: Variant in data.get("cores", []):
		if entry is Dictionary:
			stored_cores.append(entry)
	for line: Variant in data.get("log", []):
		log_lines.append(str(line))
	pending_expedition = data.get("pending", {})
	active = true
	set_phase(int(data.get("phase", Phase.FTL_MAP)) as Phase)
	sync_roster()
	crew_changed.emit()
	stores_changed.emit()

#endregion
