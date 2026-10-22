class_name ShipStores
extends RefCounted
## The ship's three resources and the storage that limits them (Design Definitions, Resources).
## Fuel moves the ship and gets it home, Metal builds and repairs permanent things, Supplies get spent.
## Fuel lives in fuel tanks; Metal and Supplies share the cargo holds. Anything beyond capacity is left behind.

signal changed

const FUEL := &"fuel"
const METAL := &"metal"
const SUPPLIES := &"supplies"
const ALL: Array[StringName] = [FUEL, METAL, SUPPLIES]

var fuel: float = 0.0
var metal: float = 0.0
var supplies: float = 0.0
var fuel_tanks: int = 0
var cargo_holds: int = 0

var config: GameConfig


func _init(game_config: GameConfig = null) -> void:
	config = game_config if game_config else GameConfig.new()


func fuel_capacity() -> float:
	return fuel_tanks * config.fuel_per_tank


func cargo_capacity() -> float:
	return cargo_holds * config.cargo_per_hold


func cargo_used() -> float:
	return metal + supplies


func cargo_free() -> float:
	return maxf(0.0, cargo_capacity() - cargo_used())


func fuel_free() -> float:
	return maxf(0.0, fuel_capacity() - fuel)


## Mass the stored resources add to the ship: a full hold costs more fuel on every burn.
func mass() -> float:
	return (fuel + metal + supplies) * config.mass_per_unit


func get_amount(resource: StringName) -> float:
	match resource:
		FUEL: return fuel
		METAL: return metal
		SUPPLIES: return supplies
	push_warning("Unknown resource %s" % resource)
	return 0.0


func has(resource: StringName, amount: float) -> bool:
	return get_amount(resource) >= amount - 0.0001


## Space left for a resource: the tanks for fuel, the shared cargo holds for metal and supplies.
func free_space(resource: StringName) -> float:
	return fuel_free() if resource == FUEL else cargo_free()


## Stores up to `amount`; returns what fit. The rest is left behind.
func add(resource: StringName, amount: float) -> float:
	if amount <= 0.0:
		return 0.0
	var stored := minf(amount, free_space(resource))
	_set_amount(resource, get_amount(resource) + stored)
	return stored


## Takes `amount` if there is that much; returns whether it was taken.
func spend(resource: StringName, amount: float) -> bool:
	if amount <= 0.0:
		return true
	if not has(resource, amount):
		return false
	_set_amount(resource, maxf(0.0, get_amount(resource) - amount))
	return true


## Takes up to `amount`; returns what was taken.
func drain(resource: StringName, amount: float) -> float:
	var taken := clampf(amount, 0.0, get_amount(resource))
	_set_amount(resource, get_amount(resource) - taken)
	return taken


## Dumps resources overboard to save mass.
func dump(resource: StringName, amount: float) -> float:
	return drain(resource, amount)


## Builds a fuel tank or cargo hold for metal. Returns whether it was built.
func build_storage(fuel_tank: bool) -> bool:
	# The metal for the build may sit in the hold being paid from, so it is spent first.
	if not spend(METAL, config.storage_build_cost):
		return false
	if fuel_tank:
		fuel_tanks += 1
	else:
		cargo_holds += 1
	changed.emit()
	return true


## Losing storage (a module destroyed, a harsh surrender) spills whatever no longer fits.
func remove_storage(fuel_tank: bool) -> void:
	if fuel_tank:
		fuel_tanks = maxi(0, fuel_tanks - 1)
		fuel = minf(fuel, fuel_capacity())
	else:
		cargo_holds = maxi(0, cargo_holds - 1)
		var over := cargo_used() - cargo_capacity()
		if over > 0.0:
			var from_supplies := minf(over, supplies)
			supplies -= from_supplies
			metal = maxf(0.0, metal - (over - from_supplies))
	changed.emit()


func _set_amount(resource: StringName, value: float) -> void:
	match resource:
		FUEL: fuel = value
		METAL: metal = value
		SUPPLIES: supplies = value
	changed.emit()


func to_dict() -> Dictionary:
	return {"fuel": fuel, "metal": metal, "supplies": supplies, "fuel_tanks": fuel_tanks, "cargo_holds": cargo_holds}


func load_dict(data: Dictionary) -> void:
	fuel = float(data.get("fuel", 0.0))
	metal = float(data.get("metal", 0.0))
	supplies = float(data.get("supplies", 0.0))
	fuel_tanks = int(data.get("fuel_tanks", 0))
	cargo_holds = int(data.get("cargo_holds", 0))
	changed.emit()


func summary() -> String:
	return "Fuel %.0f/%.0f  Metal %.0f  Supplies %.0f  (cargo %.0f/%.0f)" % [
		fuel, fuel_capacity(), metal, supplies, cargo_used(), cargo_capacity()]
