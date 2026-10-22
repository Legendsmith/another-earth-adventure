class_name Manufacturers
extends RefCounted
## Ship module manufacturers (Manufacturers.md). Every module comes from one; a manufacturer gives its modules the
## same set of modifiers, as long as at least one of them is valid on the module. Military grade hardware always has
## a repair time and hits to kill bonus.

## Modifier ids and the module categories they apply to ("any" for every module).
const REDUCED_SIGNATURE := &"reduced_signature"
const INCREASED_HTK := &"increased_htk"
const LONGER_MAINTENANCE := &"longer_maintenance"
const REDUCED_WEIGHT := &"reduced_weight"
const REDUCED_CREW := &"reduced_crew"
const FIRE_CONTROL := &"integrated_fire_control"
const SELF_POWERED := &"self_powered"
const TORPEDO_DAMAGE := &"torpedo_damage"
const SHORTER_REPAIR := &"shorter_repair"
const NO_FEED_JAM := &"no_feed_jam"
const POWER_IMMUNE := &"power_immune"
const FIRE_RATE := &"fire_rate"
const FUEL_EFFICIENCY := &"fuel_efficiency"

## Which module kinds (ShipModule.Kind) a modifier is valid on. Empty = any module.
const VALID_KINDS := {
	REDUCED_SIGNATURE: [ShipModule.Kind.MAIN_ENGINE, ShipModule.Kind.THRUSTERS, ShipModule.Kind.REACTOR],
	INCREASED_HTK: [],
	LONGER_MAINTENANCE: [],
	REDUCED_WEIGHT: [ShipModule.Kind.MAIN_ENGINE, ShipModule.Kind.THRUSTERS, ShipModule.Kind.REACTOR,
		ShipModule.Kind.WEAPON, ShipModule.Kind.SENSORS],
	REDUCED_CREW: [],
	FIRE_CONTROL: [ShipModule.Kind.WEAPON],
	SELF_POWERED: [ShipModule.Kind.WEAPON, ShipModule.Kind.SENSORS, ShipModule.Kind.REACTOR, ShipModule.Kind.MEDICAL,
		ShipModule.Kind.IMPLANT_STATION],
	TORPEDO_DAMAGE: [ShipModule.Kind.WEAPON, ShipModule.Kind.MAGAZINE],
	SHORTER_REPAIR: [],
	NO_FEED_JAM: [ShipModule.Kind.WEAPON],
	POWER_IMMUNE: [],
	FIRE_RATE: [ShipModule.Kind.WEAPON],
	FUEL_EFFICIENCY: [ShipModule.Kind.MAIN_ENGINE, ShipModule.Kind.THRUSTERS, ShipModule.Kind.REACTOR],
}

## Manufacturer id -> {name, modifiers, secondary, kinds (what they mostly make)}.
const LIST := {
	&"lightwaves": {"name": "Lightwaves Ltd", "modifiers": [REDUCED_SIGNATURE, INCREASED_HTK]},
	&"wastrel": {"name": "W. Wastrel LLC.", "modifiers": [LONGER_MAINTENANCE]},
	&"future_legends": {"name": "Future Legends GmbH", "modifiers": [REDUCED_WEIGHT]},
	&"beepers": {"name": "Beepers Workshop LLC", "modifiers": [REDUCED_CREW, FIRE_CONTROL]},
	&"hypa_spark": {"name": "Hypa Spark Pty Ltd", "modifiers": [], "generic": [ShipModule.Kind.SENSORS,
		ShipModule.Kind.BRIDGE]},
	&"nuke_scorp": {"name": "Nuke Scorp LLC", "modifiers": [SELF_POWERED, TORPEDO_DAMAGE]},
	&"nostro": {"name": "Nostro Mechanics", "modifiers": [SHORTER_REPAIR], "secondary": [NO_FEED_JAM]},
	&"matara_kan": {"name": "Matara Kan Industries", "modifiers": [INCREASED_HTK]},
	&"nyanotek": {"name": "Nyanotek Pty Ltd", "modifiers": [POWER_IMMUNE]},
	&"bgg": {"name": "BGG Databank Ltd", "modifiers": [FIRE_RATE]},
	&"m_observatory": {"name": "M. Observatory Industries", "modifiers": [FIRE_CONTROL]},
	&"mimosa": {"name": "MIMOSA Interstellar", "modifiers": [FUEL_EFFICIENCY]},
	&"nl_castle": {"name": "NL Castle CCPC", "modifiers": [], "generic": [ShipModule.Kind.CREW,
		ShipModule.Kind.MEDICAL, ShipModule.Kind.IMPLANT_STATION]},
	&"sunny_trv": {"name": "Sunny TRV LLC", "modifiers": [], "generic": [ShipModule.Kind.REACTOR,
		ShipModule.Kind.MAIN_ENGINE, ShipModule.Kind.THRUSTERS]},
}

## Size of each modifier's effect.
const HTK_MULT := 1.5
const MILITARY_HTK_MULT := 1.25
const MILITARY_REPAIR_MULT := 0.75
const MAINTENANCE_MULT := 1.6
const REPAIR_MULT := 0.6
const WEIGHT_MULT := 0.75
const SIGNATURE_MULT := 0.6
const FIRE_RATE_MULT := 1.25
const FUEL_MULT := 0.8
const TORPEDO_DAMAGE_MULT := 1.4


static func display_name_of(manufacturer: StringName) -> String:
	return LIST.get(manufacturer, {}).get("name", "Unknown")


static func is_valid_modifier(modifier: StringName, kind: ShipModule.Kind) -> bool:
	var kinds: Array = VALID_KINDS.get(modifier, [])
	return kinds.is_empty() or kinds.has(kind)


## Modifiers a manufacturer's module of `kind` gets.
static func modifiers_for(manufacturer: StringName, kind: ShipModule.Kind) -> Array[StringName]:
	var result: Array[StringName] = []
	var entry: Dictionary = LIST.get(manufacturer, {})
	for modifier: StringName in entry.get("modifiers", []) + entry.get("secondary", []):
		if is_valid_modifier(modifier, kind):
			result.append(modifier)
	return result


## Whether a manufacturer can make a module of this kind: one of its modifiers must be valid on it, or it is a generic
## maker of that kind of module.
static func makes(manufacturer: StringName, kind: ShipModule.Kind) -> bool:
	var entry: Dictionary = LIST.get(manufacturer, {})
	if entry.get("generic", []).has(kind):
		return true
	for modifier: StringName in entry.get("modifiers", []):
		if is_valid_modifier(modifier, kind):
			return true
	return false


static func random_for(kind: ShipModule.Kind, rng: RandomNumberGenerator) -> StringName:
	var options: Array[StringName] = []
	for manufacturer: StringName in LIST:
		if makes(manufacturer, kind):
			options.append(manufacturer)
	if options.is_empty():
		return &"hypa_spark"
	return options[rng.randi() % options.size()]


static func describe(manufacturer: StringName, kind: ShipModule.Kind, military: bool) -> String:
	var parts: PackedStringArray = []
	for modifier: StringName in modifiers_for(manufacturer, kind):
		parts.append(String(modifier).capitalize())
	if military:
		parts.append("Military grade")
	return "%s%s" % [display_name_of(manufacturer), (" (" + ", ".join(parts) + ")") if parts.size() else ""]
