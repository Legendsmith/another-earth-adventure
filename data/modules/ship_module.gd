class_name ShipModule
extends Resource
## An internal system of a ShipHull: reactor, bridge, sensors, an engine (EngineModule), a weapon (WeaponModule)...
##
## A module is either working or offline: damage that reaches it knocks it out with a chance of
## incoming damage / hits to kill, so a hit of at least its hits to kill always does, and a smaller one has the same
## chance every time (modules do not wear down). Crew bring it back online for its maintenance cost (see
## ShipHull.repair_module). Fuel tanks are the exception: they are never knocked out, each hit only vents fuel.
##
## `size` is the room it takes inside the hull. A SimpleHull is hit in a module with a chance of its size against the
## hull's internal size. In a ModularHull it is the fewest deck cells the module may be placed on; placing it on more
## gives a bonus (see size_bonus) that depends on its category: weapons get up to 3x the hits to kill, engineering
## (engines, reactors) up to 1.5x the hits to kill and half the maintenance cost, electronics (sensors, bridge) up to
## 1.5x the effectiveness.
##
## Module resources are designs: a hull works on its own copies (ShipHull.get_module), so state like a weapon's charge
## is per hull.

enum Kind { STRUCTURE, MAIN_ENGINE, THRUSTERS, REACTOR, FUEL_TANK, SENSORS, WEAPON, MAGAZINE, CREW, BRIDGE }
## What a bigger installation improves (see size_bonus).
enum Category { NONE, WEAPON, ENGINEERING, ELECTRONICS }

const KIND_NAMES := ["Structure", "Main engine", "Thrusters", "Reactor", "Fuel tank", "Sensors", "Weapon",
	"Magazine", "Crew quarters", "Bridge"]

## Installed size at which the size bonus is at its maximum, as a multiple of the base size.
const MAX_BONUS_SIZE := 4.0
const WEAPON_MAX_HITS_TO_KILL := 3.0
const ENGINEERING_MAX_HITS_TO_KILL := 1.5
const ENGINEERING_MAX_MAINTENANCE_CUT := 0.5
const ELECTRONICS_MAX_EFFECTIVENESS := 1.5

## Name shown on the damage readout and the deck plan.
@export var name: String = "Module"
@export var kind: Kind = Kind.STRUCTURE
## Room it takes inside the hull (deck cells in a ModularHull): larger modules are hit more often.
@export var size: float = 1.0
## Damage that is sure to knock the module out; less knocks it out with a chance of damage / hits_to_kill.
@export var hits_to_kill: int = 1
## Cost (and repair time, see ShipHull.repair_time_per_cost) to bring the module back online.
@export var maintenance_cost: float = 10.0
## Power produced by a reactor (same units as EngineModule.power_generation).
@export var power_output: float = 0.0
## Colour on the deck plan.
@export var color: Color = Color(0.45, 0.6, 0.75)


func get_category() -> Category:
	match kind:
		Kind.WEAPON:
			return Category.WEAPON
		Kind.MAIN_ENGINE, Kind.THRUSTERS, Kind.REACTOR:
			return Category.ENGINEERING
		Kind.SENSORS, Kind.BRIDGE:
			return Category.ELECTRONICS
	return Category.NONE


func is_fuel_tank() -> bool:
	return kind == Kind.FUEL_TANK


## Size bonus 0..1 for a module of `base` size installed on `installed`. A bigger module is hit more often (its area
## grows with the size), so each extra cell is worth less than the last: the bonus follows 1 - base / installed,
## scaled to reach 1 at MAX_BONUS_SIZE times the base size (2x the size gives two thirds of it, 3x nine tenths).
static func size_bonus(base: float, installed: float) -> float:
	if base <= 0.0 or installed <= base:
		return 0.0
	return clampf((1.0 - base / installed) / (1.0 - 1.0 / MAX_BONUS_SIZE), 0.0, 1.0)


## Hits to kill installed on `installed` size (its base size when < 0).
func get_hits_to_kill(installed: float = -1.0) -> float:
	var bonus := size_bonus(size, installed)
	match get_category():
		Category.WEAPON:
			return hits_to_kill * lerpf(1.0, WEAPON_MAX_HITS_TO_KILL, bonus)
		Category.ENGINEERING:
			return hits_to_kill * lerpf(1.0, ENGINEERING_MAX_HITS_TO_KILL, bonus)
	return float(hits_to_kill)


func get_maintenance_cost(installed: float = -1.0) -> float:
	if get_category() == Category.ENGINEERING:
		return maintenance_cost * (1.0 - ENGINEERING_MAX_MAINTENANCE_CUT * size_bonus(size, installed))
	return maintenance_cost


## Multiplier on what the module does (sensor strength...), 1 at its base size.
func get_effectiveness(installed: float = -1.0) -> float:
	if get_category() == Category.ELECTRONICS:
		return lerpf(1.0, ELECTRONICS_MAX_EFFECTIVENESS, size_bonus(size, installed))
	return 1.0


## Chance that `damage` knocks the module out: damage / hits to kill (1 and over is certain).
func get_kill_chance(damage: int, installed: float = -1.0) -> float:
	if damage <= 0:
		return 0.0
	return clampf(damage / maxf(get_hits_to_kill(installed), 1e-6), 0.0, 1.0)
