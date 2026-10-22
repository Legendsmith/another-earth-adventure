class_name ModuleState
extends RefCounted
## A module installed on the player's ship, with everything that persists between scenes: who made it, its maintenance
## clock, whether it is online and the malfunctions it suffers (Orbital Gameplay, Maintenance and Malfunctions).
##
## The maintenance clock starts at the maintenance interval and runs down while the module is active. At 0 a
## malfunction check is made, then again every orbital second. Outside combat a malfunction just knocks the module
## offline; in combat the module suffers one of its kind's combat malfunctions. Maintenance (costs Supplies) resets the
## clock and clears malfunctions.

enum Malfunction {
	NONE,
	# Reactor
	MINOR_POWER_SURGE, POWER_FLUCTUATIONS, MAIN_BUS_FAULT, MAJOR_POWER_SURGE,
	# Weapon
	FAILURE_TO_FEED, MISFIRE, JAM, DEGRADED_SENSOR_LINK, GIMBAL_MISALIGNMENT,
	# Drive
	FUEL_SENSOR_ERROR, FUEL_LEAK, FUEL_PUMP_FAILURE,
}

const MALFUNCTION_NAMES := ["None", "Minor power surge", "Power fluctuations", "Main bus fault", "Major power surge",
	"Failure to feed", "Misfire", "Jam", "Degraded sensor link", "Gimbal misalignment", "Fuel sensor error",
	"Fuel leak", "Fuel pump failure"]
const REACTOR_MALFUNCTIONS: Array[Malfunction] = [Malfunction.MINOR_POWER_SURGE, Malfunction.POWER_FLUCTUATIONS,
	Malfunction.MAIN_BUS_FAULT, Malfunction.MAJOR_POWER_SURGE]
const WEAPON_MALFUNCTIONS: Array[Malfunction] = [Malfunction.FAILURE_TO_FEED, Malfunction.MISFIRE, Malfunction.JAM,
	Malfunction.DEGRADED_SENSOR_LINK, Malfunction.GIMBAL_MISALIGNMENT]
const DRIVE_MALFUNCTIONS: Array[Malfunction] = [Malfunction.FUEL_SENSOR_ERROR, Malfunction.FUEL_LEAK,
	Malfunction.FUEL_PUMP_FAILURE]
## Malfunctions that stay on the module until maintenance clears them. The others happen once.
const PERSISTENT: Array[Malfunction] = [Malfunction.POWER_FLUCTUATIONS, Malfunction.MAIN_BUS_FAULT, Malfunction.MISFIRE,
	Malfunction.DEGRADED_SENSOR_LINK, Malfunction.GIMBAL_MISALIGNMENT, Malfunction.FUEL_SENSOR_ERROR,
	Malfunction.FUEL_LEAK, Malfunction.FUEL_PUMP_FAILURE]
## Malfunctions that can stack.
const STACKING: Array[Malfunction] = [Malfunction.POWER_FLUCTUATIONS, Malfunction.GIMBAL_MISALIGNMENT]
## Share of the maintenance interval a power surge takes off a module's clock.
const SURGE_PENALTY := 0.2
const PUMP_FAILURE_THRUST := 0.6
const GIMBAL_ACCURACY_LOSS := 0.05
const SENSOR_LINK_ACCURACY := 0.6

## The design (a ShipModule resource path).
var design_path: String = ""
var design: ShipModule
var manufacturer: StringName = &"hypa_spark"
var military: bool = false
var maintenance_clock: float = 0.0
var online: bool = true
## Crew have it switched off (to save power): its clock does not run.
var powered: bool = true
var malfunctions: Array[Malfunction] = []
## Seconds of repair work done towards bringing it back online.
var repair_progress: float = 0.0
var config: GameConfig


func _init(game_config: GameConfig = null) -> void:
	config = game_config if game_config else GameConfig.new()


static func create(path: String, maker: StringName, game_config: GameConfig, is_military: bool = false) -> ModuleState:
	var state := ModuleState.new(game_config)
	state.design_path = path
	state.design = load(path) as ShipModule
	state.manufacturer = maker
	state.military = is_military
	state.maintenance_clock = state.maintenance_interval()
	return state


func get_kind() -> ShipModule.Kind:
	return design.kind if design else ShipModule.Kind.STRUCTURE


func get_module_name() -> String:
	return design.name if design else "Module"


func has_modifier(modifier: StringName) -> bool:
	return Manufacturers.modifiers_for(manufacturer, get_kind()).has(modifier)


#region Derived stats

func maintenance_interval() -> float:
	var interval := design.maintenance_interval if design and design.maintenance_interval > 0.0 \
		else config.default_maintenance_interval
	if has_modifier(Manufacturers.LONGER_MAINTENANCE):
		interval *= Manufacturers.MAINTENANCE_MULT
	return interval


func hits_to_kill() -> float:
	var htk := design.get_hits_to_kill() if design else 1.0
	if has_modifier(Manufacturers.INCREASED_HTK):
		htk *= Manufacturers.HTK_MULT
	if military:
		htk *= Manufacturers.MILITARY_HTK_MULT
	return htk


func crew_required() -> int:
	var crew := design.crew_required if design else 0
	if has_modifier(Manufacturers.REDUCED_CREW):
		crew = maxi(crew - 1, mini(crew, 1))
	return crew


## Seconds of one crewmember's work to bring it back online. Several crew (up to its size) can work at once.
func repair_time() -> float:
	var seconds := config.repair_seconds_per_size * (design.size if design else 1.0)
	if has_modifier(Manufacturers.SHORTER_REPAIR):
		seconds *= Manufacturers.REPAIR_MULT
	if military:
		seconds *= Manufacturers.MILITARY_REPAIR_MULT
	return seconds


func max_repair_crew() -> int:
	return maxi(1, ceili(design.size if design else 1.0))


func maintenance_cost() -> float:
	return config.maintenance_supplies_per_size * (design.size if design else 1.0)


func power_draw() -> float:
	if design == null or has_modifier(Manufacturers.SELF_POWERED):
		return 0.0
	return design.power_draw


func is_essential() -> bool:
	return get_kind() in [ShipModule.Kind.BRIDGE, ShipModule.Kind.REACTOR, ShipModule.Kind.MAIN_ENGINE]


func is_reactor() -> bool:
	var kind := get_kind()
	if kind == ShipModule.Kind.REACTOR:
		return true
	return kind == ShipModule.Kind.MAIN_ENGINE and design is EngineModule and (design as EngineModule).power_generation > 0.0


func is_drive() -> bool:
	return get_kind() in [ShipModule.Kind.MAIN_ENGINE, ShipModule.Kind.THRUSTERS]


func is_weapon() -> bool:
	return get_kind() == ShipModule.Kind.WEAPON


## Power this module adds to the ship when online.
func power_output() -> float:
	if design == null:
		return 0.0
	var output := design.power_output
	if design is EngineModule:
		output += maxf(0.0, (design as EngineModule).power_generation)
	if has_modifier(Manufacturers.SELF_POWERED) and is_reactor():
		output *= 1.25
	if malfunctions.has(Malfunction.MAIN_BUS_FAULT):
		output *= 0.75
	return output


## Fuel consumption multiplier from malfunctions and the manufacturer.
func fuel_multiplier() -> float:
	var mult := 1.0
	if has_modifier(Manufacturers.FUEL_EFFICIENCY):
		mult *= Manufacturers.FUEL_MULT
	if malfunctions.has(Malfunction.FUEL_SENSOR_ERROR):
		mult *= 1.25
	if malfunctions.has(Malfunction.FUEL_LEAK):
		mult *= 2.0
	return mult


func thrust_multiplier() -> float:
	return PUMP_FAILURE_THRUST if malfunctions.has(Malfunction.FUEL_PUMP_FAILURE) else 1.0


## Weapon accuracy multiplier from malfunctions.
func accuracy_multiplier() -> float:
	var mult := 1.0
	if malfunctions.has(Malfunction.DEGRADED_SENSOR_LINK):
		mult *= SENSOR_LINK_ACCURACY
	mult *= 1.0 - GIMBAL_ACCURACY_LOSS * malfunctions.count(Malfunction.GIMBAL_MISALIGNMENT)
	return maxf(mult, 0.1)


## Maintenance clock rate multiplier: power fluctuations on the ship double it per stack.
func clock_rate(fluctuations: int, combat_power: bool) -> float:
	var rate := 1.0 + fluctuations
	if combat_power:
		rate *= config.combat_maintenance_rate
	return rate

#endregion


#region Maintenance and malfunctions

func is_overdue() -> bool:
	return maintenance_clock <= 0.0


## Malfunction chance of one check: rises the longer maintenance is overdue.
func malfunction_chance() -> float:
	if maintenance_clock > 0.0:
		return 0.0
	var overdue := -maintenance_clock / maxf(maintenance_interval(), 1.0)
	return clampf(config.malfunction_base_chance + config.malfunction_overdue_chance * overdue, 0.0, 1.0)


## Runs the clock for `seconds` of orbital time. Returns true if a malfunction check failed (the caller decides which
## malfunction, see ShipState).
func tick(seconds: float, rate: float, rng: RandomNumberGenerator) -> bool:
	if not online or not powered or seconds <= 0.0:
		return false
	var was_overdue := is_overdue()
	maintenance_clock -= seconds * rate
	if not is_overdue():
		return false
	# One check when the clock reaches 0, then one per orbital second. Many seconds at once (time warp) are rolled
	# together: the chance that at least one of n checks fails.
	var checks := seconds if was_overdue else 1.0 + maxf(0.0, -maintenance_clock / rate)
	var chance := malfunction_chance()
	var fail_chance := 1.0 - pow(1.0 - chance, checks)
	return rng.randf() < fail_chance


## Combat malfunctions this module can suffer (Fusion drives can suffer drive and reactor ones).
func combat_malfunction_pool() -> Array[Malfunction]:
	var pool: Array[Malfunction] = []
	if is_weapon():
		pool.append_array(WEAPON_MALFUNCTIONS)
	if is_drive():
		pool.append_array(DRIVE_MALFUNCTIONS)
	if is_reactor():
		pool.append_array(REACTOR_MALFUNCTIONS)
	if has_modifier(Manufacturers.NO_FEED_JAM):
		pool.erase(Malfunction.FAILURE_TO_FEED)
		pool.erase(Malfunction.JAM)
	if has_modifier(Manufacturers.POWER_IMMUNE):
		for surge: Malfunction in [Malfunction.MINOR_POWER_SURGE, Malfunction.POWER_FLUCTUATIONS, Malfunction.MAJOR_POWER_SURGE]:
			pool.erase(surge)
	return pool


func add_malfunction(malfunction: Malfunction) -> void:
	if malfunction == Malfunction.NONE:
		return
	if PERSISTENT.has(malfunction) and (STACKING.has(malfunction) or not malfunctions.has(malfunction)):
		malfunctions.append(malfunction)
	match malfunction:
		Malfunction.JAM:
			online = false
		Malfunction.FAILURE_TO_FEED:
			# Fires one more burst (the weapon handles it) then goes offline.
			online = false


func lower_clock(share: float) -> void:
	maintenance_clock -= maintenance_interval() * share


## Knocked offline by damage: its maintenance clock is reduced.
func knock_out() -> void:
	if not online:
		return
	online = false
	repair_progress = 0.0
	lower_clock(config.knockout_clock_penalty)


## Adds repair work; returns true once it is back online. In combat crews bring a module back without maintaining it.
func add_repair_work(seconds: float) -> bool:
	if online:
		return true
	repair_progress += seconds
	if repair_progress >= repair_time():
		online = true
		repair_progress = 0.0
		return true
	return false


## Full maintenance: resets the clock, clears malfunctions and brings the module online.
func maintain() -> void:
	maintenance_clock = maintenance_interval()
	malfunctions.clear()
	online = true
	repair_progress = 0.0

#endregion


func status_text() -> String:
	var parts: PackedStringArray = []
	parts.append("ONLINE" if online else "OFFLINE")
	if not powered:
		parts.append("unpowered")
	var interval := maintenance_interval()
	parts.append("maint %d%%" % roundi(100.0 * maintenance_clock / interval) if maintenance_clock > 0.0 else "MAINT OVERDUE")
	for malfunction: Malfunction in malfunctions:
		parts.append(MALFUNCTION_NAMES[malfunction])
	return ", ".join(parts)


func to_dict() -> Dictionary:
	return {
		"design": design_path, "manufacturer": String(manufacturer), "military": military,
		"clock": maintenance_clock, "online": online, "powered": powered,
		"malfunctions": Array(malfunctions), "repair": repair_progress,
	}


static func from_dict(data: Dictionary, game_config: GameConfig) -> ModuleState:
	var state := ModuleState.create(str(data.get("design", "")), StringName(data.get("manufacturer", "hypa_spark")),
		game_config, bool(data.get("military", false)))
	state.maintenance_clock = float(data.get("clock", state.maintenance_clock))
	state.online = bool(data.get("online", true))
	state.powered = bool(data.get("powered", true))
	state.repair_progress = float(data.get("repair", 0.0))
	for value: Variant in data.get("malfunctions", []):
		state.malfunctions.append(int(value) as Malfunction)
	return state
