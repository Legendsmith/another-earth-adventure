class_name ShipState
extends RefCounted
## The player's ship between scenes: its installed modules, armor, power and combat status.
## The orbital scene builds the ship's ShipHull from these modules and reports damage back; maintenance clocks and
## malfunctions run here (tick) in orbital time.

signal malfunction_occurred(module: ModuleState, malfunction: ModuleState.Malfunction, text: String)
signal module_changed(module: ModuleState)

const STARTING_MODULES := [
	["res://data/components/bridge.tres", &"hypa_spark"],
	["res://data/components/reactor.tres", &"sunny_trv"],
	["res://data/engines/fusion_drive.tres", &"sunny_trv"],
	["res://data/engines/chemical_thrusters.tres", &"sunny_trv"],
	["res://data/components/sensors.tres", &"hypa_spark"],
	["res://data/components/torpedo_tubes.tres", &"nuke_scorp"],
	["res://data/components/torpedo_magazine.tres", &"nuke_scorp"],
	["res://data/components/crew_quarters.tres", &"nl_castle"],
	["res://data/components/medical_bay.tres", &"nl_castle"],
	["res://data/components/fuel_tank.tres", &"sunny_trv"],
	["res://data/components/structure.tres", &"matara_kan"],
]

var name: String = "AEV Wayfarer"
var modules: Array[ModuleState] = []
var armor: float = 40.0
var max_armor: float = 40.0
## Engines and reactor brought up to combat status: drastically better output, faster wear.
var combat_power: bool = false
var weapons_loaded: bool = false
var config: GameConfig
var rng := RandomNumberGenerator.new()


func _init(game_config: GameConfig = null) -> void:
	config = game_config if game_config else GameConfig.new()
	rng.randomize()


static func create_starting_ship(game_config: GameConfig) -> ShipState:
	var ship := ShipState.new(game_config)
	for entry: Array in STARTING_MODULES:
		ship.install(ModuleState.create(entry[0], entry[1], game_config))
	return ship


func install(module: ModuleState) -> void:
	modules.append(module)
	module_changed.emit(module)


func remove(module: ModuleState) -> void:
	modules.erase(module)
	module_changed.emit(module)


func find_kind(kind: ShipModule.Kind) -> Array[ModuleState]:
	var found: Array[ModuleState] = []
	for module: ModuleState in modules:
		if module.get_kind() == kind:
			found.append(module)
	return found


func has_working(kind: ShipModule.Kind) -> bool:
	for module: ModuleState in find_kind(kind):
		if module.online:
			return true
	return false


#region Crew

## Crew needed for the essential modules (Bridge, Reactor, Engine): the lose condition compares this with the crew.
func essential_crew_required() -> int:
	var total := 0
	for module: ModuleState in modules:
		if module.is_essential():
			total += module.crew_required()
	return total


func total_crew_required() -> int:
	var total := 0
	for module: ModuleState in modules:
		total += module.crew_required()
	return total


## Hands out the active crew to modules, essential ones first, then weapons and sensors, then the rest.
## Returns module index -> crew records manning it.
func assign_crew(crew: Array[CrewRecord]) -> Dictionary:
	var available: Array[CrewRecord] = []
	for record: CrewRecord in crew:
		record.assigned_module = -1
		if record.is_active() and not record.is_player:
			available.append(record)
	var order: Array[int] = []
	for i: int in modules.size():
		order.append(i)
	order.sort_custom(func(a: int, b: int) -> bool: return _crew_priority(modules[a]) < _crew_priority(modules[b]))
	var manned := {}
	for i: int in order:
		var need := modules[i].crew_required()
		var team: Array[CrewRecord] = []
		while team.size() < need and not available.is_empty():
			var record: CrewRecord = available.pop_front()
			record.assigned_module = i
			team.append(record)
		manned[i] = team
	return manned


func _crew_priority(module: ModuleState) -> int:
	if module.is_essential():
		return 0
	match module.get_kind():
		ShipModule.Kind.WEAPON, ShipModule.Kind.SENSORS:
			return 1
		ShipModule.Kind.MEDICAL:
			return 2
	return 3


## Modules whose crew requirement is met (a module without crew can't run).
func is_manned(index: int, crew: Array[CrewRecord]) -> bool:
	var need := modules[index].crew_required()
	if need == 0:
		return true
	var count := 0
	for record: CrewRecord in crew:
		if record.assigned_module == index and record.is_active():
			count += 1
	return count >= need

#endregion


#region Power

func power_capacity() -> float:
	var total := 0.0
	for module: ModuleState in modules:
		if module.online:
			total += module.power_output()
	return total


func power_demand() -> float:
	var total := 0.0
	for module: ModuleState in modules:
		if module.online and module.powered:
			total += module.power_draw()
	return total


## Reactor output 0..1 (or more at combat power) needed to run what is switched on.
func reactor_output() -> float:
	var capacity := power_capacity()
	if capacity <= 0.0:
		return 0.0
	var output := power_demand() / capacity
	return maxf(output, config.reactor_combat_output if combat_power else config.reactor_cruise_output)


## Fuel the reactors burn per orbital second: consumption goes with the square of the output.
func reactor_fuel_rate() -> float:
	var rate := 0.0
	var output := reactor_output()
	for module: ModuleState in modules:
		if module.online and module.is_reactor():
			rate += config.reactor_fuel_per_hour / 3600.0 * output * output * module.fuel_multiplier()
	return rate


## Fuel multiplier on main drive burns from drive malfunctions and manufacturers.
func drive_fuel_multiplier() -> float:
	var mult := 1.0
	var drives := 0
	var total := 0.0
	for module: ModuleState in modules:
		if module.get_kind() == ShipModule.Kind.MAIN_ENGINE:
			drives += 1
			total += module.fuel_multiplier()
	if drives > 0:
		mult = total / drives
	return mult


func drive_thrust_multiplier() -> float:
	var mult := 1.0
	for module: ModuleState in modules:
		if module.get_kind() == ShipModule.Kind.MAIN_ENGINE:
			mult = minf(mult, module.thrust_multiplier())
	return mult * (config.combat_power_bonus if combat_power else 1.0)

#endregion


#region Maintenance and malfunctions

func power_fluctuations() -> int:
	var count := 0
	for module: ModuleState in modules:
		count += module.malfunctions.count(ModuleState.Malfunction.POWER_FLUCTUATIONS)
	return count


## Runs every module's maintenance clock for `seconds` of orbital time and rolls malfunctions. Returns the fuel the
## reactors burned (the caller takes it from the stores).
func tick(seconds: float, in_combat: bool = false) -> float:
	if seconds <= 0.0:
		return 0.0
	var fluctuations := power_fluctuations()
	for module: ModuleState in modules:
		var powered_rate := module.clock_rate(fluctuations if module.power_draw() > 0.0 else 0, combat_power)
		if module.tick(seconds, powered_rate, rng):
			if in_combat:
				combat_malfunction(module)
			else:
				_noncombat_malfunction(module)
	return reactor_fuel_rate() * seconds


func _noncombat_malfunction(module: ModuleState) -> void:
	module.online = false
	module.repair_progress = 0.0
	malfunction_occurred.emit(module, ModuleState.Malfunction.NONE, "%s malfunctioned and went offline" % module.get_module_name())
	module_changed.emit(module)


## Rolls a combat malfunction on the module. Returns the malfunction (NONE if the module has none of its kind).
func combat_malfunction(module: ModuleState) -> ModuleState.Malfunction:
	var pool := module.combat_malfunction_pool()
	if pool.is_empty():
		if not (module.is_weapon() or module.is_drive() or module.is_reactor()):
			_noncombat_malfunction(module)
		return ModuleState.Malfunction.NONE
	var malfunction: ModuleState.Malfunction = pool[rng.randi() % pool.size()]
	apply_malfunction(module, malfunction)
	return malfunction


func apply_malfunction(module: ModuleState, malfunction: ModuleState.Malfunction) -> void:
	module.add_malfunction(malfunction)
	var powered: Array[ModuleState] = []
	for other: ModuleState in modules:
		if other.online and other.powered and other.power_draw() > 0.0 \
				and not other.has_modifier(Manufacturers.POWER_IMMUNE):
			powered.append(other)
	match malfunction:
		ModuleState.Malfunction.MINOR_POWER_SURGE:
			if not powered.is_empty():
				powered[rng.randi() % powered.size()].lower_clock(ModuleState.SURGE_PENALTY)
		ModuleState.Malfunction.MAJOR_POWER_SURGE:
			var penalty := ModuleState.SURGE_PENALTY
			if module.malfunctions.has(ModuleState.Malfunction.MAIN_BUS_FAULT):
				module.malfunctions.erase(ModuleState.Malfunction.MAIN_BUS_FAULT)
				penalty *= 2.0
			for other: ModuleState in powered:
				other.lower_clock(penalty)
	malfunction_occurred.emit(module, malfunction, "%s: %s" % [module.get_module_name(),
		ModuleState.MALFUNCTION_NAMES[malfunction]])
	module_changed.emit(module)


## The ship goes to combat power: every module with its maintenance clock at 0 or less makes a combat malfunction check.
func enter_combat_power() -> void:
	combat_power = true
	for module: ModuleState in modules:
		if module.online and module.is_overdue() and rng.randf() < config.combat_malfunction_chance:
			combat_malfunction(module)


func leave_combat_power() -> void:
	combat_power = false


## A hit that reached a module: knocks it out with a chance of damage / hits to kill. An active module overdue for
## maintenance that survives the hit makes a combat malfunction check. Returns true when knocked out.
func hit_module(module: ModuleState, damage: float, in_combat: bool = true) -> bool:
	if not module.online:
		return false
	var chance := clampf(damage / maxf(module.hits_to_kill(), 0.001), 0.0, 1.0)
	if rng.randf() < chance:
		module.knock_out()
		module_changed.emit(module)
		return true
	if in_combat and module.is_overdue() and rng.randf() < config.combat_malfunction_chance:
		combat_malfunction(module)
	return false


func maintenance_cost(module: ModuleState) -> float:
	return module.maintenance_cost()


## Supplies needed to maintain every module that is due (clock under a quarter, offline or malfunctioning).
func maintenance_due() -> Array[ModuleState]:
	var due: Array[ModuleState] = []
	for module: ModuleState in modules:
		if not module.online or not module.malfunctions.is_empty() \
				or module.maintenance_clock < module.maintenance_interval() * 0.25:
			due.append(module)
	return due

#endregion


#region Armor and readiness

## Repairs armor with metal. Returns the points repaired.
func repair_armor(stores: ShipStores, points: float) -> float:
	var missing := max_armor - armor
	var affordable := stores.metal / config.metal_per_armor_point
	var repaired := minf(minf(points, missing), affordable)
	if repaired <= 0.0:
		return 0.0
	stores.spend(ShipStores.METAL, repaired * config.metal_per_armor_point)
	armor += repaired
	return repaired


## How ready the ship is to fight, 0..1: the state of its modules, armor and loaded weapons (Combat Readiness).
func combat_readiness(crew: Array[CrewRecord] = []) -> float:
	if modules.is_empty():
		return 0.0
	var module_score := 0.0
	var weapons := 0
	var weapons_ready := 0
	for i: int in modules.size():
		var module := modules[i]
		var score := 0.0
		if module.online:
			score = 1.0 if module.maintenance_clock > 0.0 else 0.6
			score *= 1.0 - 0.15 * module.malfunctions.size()
			if not crew.is_empty() and not is_manned(i, crew):
				score *= 0.3
		module_score += clampf(score, 0.0, 1.0)
		if module.is_weapon():
			weapons += 1
			if module.online:
				weapons_ready += 1
	var readiness := module_score / modules.size() * 0.5
	readiness += (armor / maxf(max_armor, 1.0)) * 0.2
	if weapons > 0:
		readiness += float(weapons_ready) / weapons * (0.3 if weapons_loaded else 0.15)
	readiness *= 1.15 if combat_power else 1.0
	return clampf(readiness, 0.0, 1.0)


## Rough firepower for enemy AI decisions.
func firepower() -> float:
	var total := 0.0
	for module: ModuleState in modules:
		if module.is_weapon() and module.online:
			total += module.design.size * (1.5 if combat_power else 1.0)
	return total

#endregion


func to_dict() -> Dictionary:
	var module_data: Array = []
	for module: ModuleState in modules:
		module_data.append(module.to_dict())
	return {"name": name, "modules": module_data, "armor": armor, "max_armor": max_armor,
		"weapons_loaded": weapons_loaded}


static func from_dict(data: Dictionary, game_config: GameConfig) -> ShipState:
	var ship := ShipState.new(game_config)
	ship.name = str(data.get("name", ship.name))
	ship.armor = float(data.get("armor", ship.armor))
	ship.max_armor = float(data.get("max_armor", ship.max_armor))
	ship.weapons_loaded = bool(data.get("weapons_loaded", false))
	for entry: Variant in data.get("modules", []):
		if entry is Dictionary:
			var module := ModuleState.from_dict(entry, game_config)
			if module.design:
				ship.modules.append(module)
	return ship
