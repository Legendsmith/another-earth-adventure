class_name ShipHull
extends Node2D
## Makes its parent (a Spaceship, an asteroid emplacement or any Node2D) a combatant: armor, internal modules, engines
## and weapons. This is the one source of truth for what a ship carries and what state it is in; SimpleHull and
## ModularHull decide how hits reach the modules. Sensors and the sensor signature live in a SensorSuite on the same
## parent; the hull gives it its faction, adds weapon flashes to its signature and degrades it as sensors are lost.
##
## Modules (ShipModule) are working or offline, one bit each in `offline_mask`: damage that reaches a module knocks it
## out with a chance of damage / hits to kill (see damage_module), and crew bring it back for its maintenance cost
## (add_repair_work). Fuel tanks are never knocked out: each hit vents a little fuel instead.
##
## Engines are EngineModules: the ship flies on the sum of its working main engines and thrusters (get_main_drive,
## get_thrusters), which the hull keeps up to date on its Spaceship. Weapons are WeaponModules the hull ticks and draws;
## the player fires them in WeaponGroups (see PlayerWeapons).

signal hit_taken(damage: int, penetrating: int)
## `damage` points reached module `index` at once (before the roll to knock it out).
signal module_hit(index: int, damage: int)
signal module_offline(index: int)
signal module_restored(index: int)
## A hit on a fuel tank vented `fraction` of the ship's fuel capacity.
signal fuel_leaked(index: int, fraction: float)
signal destroyed

const GROUP := &"combat_hulls"
## Faction that fights everyone (old battlefield automatons).
const DERELICT_FACTION := &"derelict"
## Internal damage a magazine adds when it cooks off.
const MAGAZINE_EXPLOSION := 6
## Seconds a weapon discharge keeps blooming the signature.
const EMISSION_DECAY := 4.0
## Modules whose state fits in offline_mask (fuel tanks and modules that are never knocked out take no bit).
const MAX_TRACKED_MODULES := 64
const NO_BIT := -1

@export var display_name: String = ""
## Combat faction. Hulls of different factions are hostile; an empty faction is never targeted.
@export var faction: StringName = Constants.ENEMY_GROUP
## Destroyed hulls free their parent. Off for the player's ship, which many nodes reference.
@export var free_on_destroyed: bool = true
## Hide the whole parent while the player's side has not detected this hull (ships). Off for hulls inside something
## the player can see anyway, like an asteroid emplacement: only the contact marker is hidden.
@export var hide_host_when_undetected: bool = true

@export_category("Armor")
@export var armor: ArmorDefinition
## Total armor mass. Layers = armor_mass / (armor_columns * armor.box_mass).
@export var armor_mass: float = 1.0
## Armor columns: boxes around the hull surface (larger hulls have more columns, so thicker armor costs more).
@export var armor_columns: int = 10

@export_category("Internals")
## The hull's modules. A SimpleHull keeps all of them here; a ModularHull places them in its layout and keeps only
## the ones that need no place here (thrusters).
@export var modules: Array[ShipModule] = []
## Weapon groups for the player's fire control. Weapons left out get a linked group each.
@export var weapon_groups: Array[WeaponGroup] = []
## Seconds of crew work per point of maintenance cost to bring a module back online.
@export var repair_time_per_cost: float = 1.0
## Share of the fuel capacity a fuel tank vents per point of damage before it self-seals.
@export_range(0.0, 0.2, 0.001) var fuel_loss_per_hit: float = 0.01

@export_category("Profile")
## Radius (px) within which munitions and fragments hit the hull.
@export var hit_radius: float = 6.0

var host: Node2D
var is_destroyed := false
## Bit `get_module_bit(i)` is set while module i is offline.
var offline_mask := 0
## Fuel vented by hits on fuel tanks, as a share of the fuel capacity.
var fuel_lost := 0.0
var rng := RandomNumberGenerator.new()

## The hull's own copies of its modules (see get_module).
var _modules: Array[ShipModule] = []
## Bit of each module in offline_mask, NO_BIT for modules that are never knocked out.
var _bits: PackedInt32Array
## Module index -> seconds of repair work done on it.
var _repair_work: Dictionary = {}
var _weapons: Array[WeaponModule] = []
var _groups: Array[WeaponGroup] = []
var _main_drive: EngineModule
var _thrusters: EngineModule

var _emission := 0.0
var _flash := 0.0
var _last_position := Vector2.ZERO
var _velocity := Vector2.ZERO


func _ready() -> void:
	host = get_parent() as Node2D
	add_to_group(GROUP)
	rng.randomize()
	if display_name.is_empty() and host:
		display_name = host.name
	_rebuild()
	_last_position = get_world_position()


func _physics_process(delta: float) -> void:
	for weapon in _weapons:
		weapon.tick(delta)
	if not host:
		return
	var position_now := get_world_position()
	if delta > 0.0:
		_velocity = (position_now - _last_position) / delta
	_last_position = position_now
	_emission = maxf(_emission - _emission * delta / EMISSION_DECAY, 0.0)
	if _flash > 0.0:
		_flash = maxf(_flash - delta, 0.0)
	queue_redraw()


#region Setup

## Rebuilds the hull's module copies, weapons, groups and damage model, clearing all damage.
func _rebuild() -> void:
	offline_mask = 0
	fuel_lost = 0.0
	_repair_work.clear()
	_modules.clear()
	for module in _collect_modules():
		_modules.append(module.duplicate() as ShipModule if module else null)
	_bits = PackedInt32Array()
	_bits.resize(_modules.size())
	var next_bit := 0
	for i in _modules.size():
		if _modules[i] == null or _modules[i].is_fuel_tank() or not _is_knockout_tracked(i):
			_bits[i] = NO_BIT
		elif next_bit >= MAX_TRACKED_MODULES:
			push_error("%s: more than %d modules, module %s is never knocked out"
				% [name, MAX_TRACKED_MODULES, _modules[i].name])
			_bits[i] = NO_BIT
		else:
			_bits[i] = next_bit
			next_bit += 1
	_weapons.clear()
	for i in _modules.size():
		if _modules[i] is WeaponModule:
			var weapon := _modules[i] as WeaponModule
			weapon.bind(self, i)
			_weapons.append(weapon)
	_build_groups()
	_setup_damage_model()
	_update_engines()


## The module designs in index order (null entries keep an index but are ignored). Overridden by ModularHull.
func _collect_modules() -> Array[ShipModule]:
	return modules.duplicate()


## Whether module `index` is knocked out by damage (a bit in offline_mask). Overridden by ModularHull for thrusters.
func _is_knockout_tracked(_index: int) -> bool:
	return true


## Armor and structure. Overridden by the subclasses.
func _setup_damage_model() -> void:
	pass


func _build_groups() -> void:
	_groups.clear()
	var grouped := {}
	for group in weapon_groups:
		if group == null:
			continue
		var copy := group.duplicate() as WeaponGroup
		var valid := PackedInt32Array()
		for weapon_index in copy.weapons:
			if weapon_index >= 0 and weapon_index < _weapons.size():
				valid.append(weapon_index)
				grouped[weapon_index] = true
		copy.weapons = valid
		_groups.append(copy)
	for i in _weapons.size():
		if not grouped.has(i):
			_groups.append(WeaponGroup.create(_weapons[i].name, PackedInt32Array([i])))

#endregion


#region State

## Position in world px (the host sits on the orbital map: see SpaceScale).
func get_world_position() -> Vector2:
	if host is Spaceship:
		return SpaceScale.to_world(host.get_state_position())
	return SpaceScale.to_world(host.global_position if host else global_position)


## Velocity in world px/s.
func get_world_velocity() -> Vector2:
	if host is Spaceship:
		return SpaceScale.to_world(host.get_state_velocity())
	if host is RigidBody2D:
		return SpaceScale.to_world(host.linear_velocity)
	return _velocity


func is_hostile_to(other_faction: StringName) -> bool:
	return ShipHull.factions_hostile(faction, other_faction)


static func factions_hostile(a: StringName, b: StringName) -> bool:
	return a != &"" and b != &"" and a != b


## The SensorSuite on the same host (null if it has none: then it can neither see nor be seen).
func get_sensor_suite() -> SensorSuite:
	return SensorSuite.find_on(host)


## Sensor signature of the whole host (see SensorSuite.get_signature).
func get_signature() -> float:
	var suite := get_sensor_suite()
	return suite.get_signature() if suite else _emission


## Signature bloom from recent weapon fire.
func get_emission() -> float:
	return _emission


## Adds a short-lived signature bloom (weapon discharge).
func add_emission(amount: float) -> void:
	_emission += amount


## Electrical power available to weapons: working reactors plus the main drive's power generation.
func get_power_supply() -> float:
	var power := 0.0
	for i in _modules.size():
		var module := _modules[i]
		if module and module.kind == ShipModule.Kind.REACTOR and is_module_operational(i):
			power += module.power_output
	var ship := host as Spaceship
	if _main_drive and (ship == null or ship.main_engine_online):
		power += maxf(_main_drive.power_generation, 0.0)
	return power


## Can the crew still fight? False once every bridge is offline (a hull without a bridge is automated).
func is_in_command() -> bool:
	return not is_destroyed and (not has_kind(ShipModule.Kind.BRIDGE)
		or get_operational_fraction(ShipModule.Kind.BRIDGE) > 0.0)

#endregion


#region Modules

func get_module_count() -> int:
	return _modules.size()


## The hull's own copy of module `index` (null for an empty slot).
func get_module(index: int) -> ShipModule:
	return _modules[index] if index >= 0 and index < _modules.size() else null


## Room module `index` takes inside the hull (its placement's cells in a ModularHull), which sets its size bonus.
func get_module_installed_size(index: int) -> float:
	var module := get_module(index)
	return module.size if module else 0.0


func get_module_bit(index: int) -> int:
	return _bits[index] if index >= 0 and index < _bits.size() else NO_BIT


func is_module_operational(index: int) -> bool:
	if get_module(index) == null:
		return false
	var bit := get_module_bit(index)
	return bit == NO_BIT or (offline_mask & (1 << bit)) == 0


func is_fuel_tank(index: int) -> bool:
	var module := get_module(index)
	return module != null and module.is_fuel_tank()


func get_module_hits_to_kill(index: int) -> float:
	return get_module(index).get_hits_to_kill(get_module_installed_size(index))


func get_module_effectiveness(index: int) -> float:
	return get_module(index).get_effectiveness(get_module_installed_size(index))


## Share (0..1) of the module's output it still gives: 1 working, 0 offline. ModularHull scales thrusters by the frame.
func get_module_performance(index: int) -> float:
	return 1.0 if is_module_operational(index) else 0.0


func find_module(module_name: String) -> int:
	for i in _modules.size():
		if _modules[i] and _modules[i].name == module_name:
			return i
	return -1


func has_kind(kind: ShipModule.Kind) -> bool:
	for module in _modules:
		if module and module.kind == kind:
			return true
	return false


## Working share (by size) of the modules of `kind`; 1 when the hull has none.
func get_operational_fraction(kind: ShipModule.Kind) -> float:
	var total := 0.0
	var working := 0.0
	for i in _modules.size():
		if _modules[i] and _modules[i].kind == kind:
			total += _modules[i].size
			working += _modules[i].size * get_module_performance(i)
	return working / total if total > 0.0 else 1.0


## Output of the modules of `kind` against their base: the working share by size, times each module's
## effectiveness (electronics placed bigger than their base size do more). 1 when the hull has none.
func get_kind_effectiveness(kind: ShipModule.Kind) -> float:
	var total := 0.0
	var output := 0.0
	for i in _modules.size():
		if _modules[i] and _modules[i].kind == kind:
			total += _modules[i].size
			output += _modules[i].size * get_module_performance(i) * get_module_effectiveness(i)
	return output / total if total > 0.0 else 1.0


## Indices of the offline modules.
func get_offline_modules() -> PackedInt32Array:
	var result := PackedInt32Array()
	for i in _modules.size():
		if _modules[i] and not is_module_operational(i):
			result.append(i)
	return result

#endregion


#region Weapons

## The hull's weapons, in module order.
func get_weapons() -> Array[WeaponModule]:
	return _weapons


## The player's weapon groups: the hull's configured groups, then one for each weapon left out of them.
func get_weapon_groups() -> Array[WeaponGroup]:
	return _groups


## The weapons of `group`.
func get_group_weapons(group: WeaponGroup) -> Array[WeaponModule]:
	var result: Array[WeaponModule] = []
	if group:
		for weapon_index in group.weapons:
			if weapon_index >= 0 and weapon_index < _weapons.size():
				result.append(_weapons[weapon_index])
	return result


func has_railgun() -> bool:
	for weapon in _weapons:
		if weapon is Railgun:
			return true
	return false

#endregion


#region Engines

## The working main engines combined into one (see EngineModule.combine); null when none are fitted.
func get_main_drive() -> EngineModule:
	return _main_drive


## The thrusters combined into one; null when none are fitted.
func get_thrusters() -> EngineModule:
	return _thrusters


## Mass of every engine fitted, working or not.
func get_engine_mass() -> float:
	var total := 0.0
	for module in _modules:
		var engine := module as EngineModule
		if engine:
			total += engine.mass
	return total


## Recombines the engines after a module changed state and hands them to the Spaceship.
func _update_engines() -> void:
	var mains: Array[EngineModule] = []
	var main_performance := PackedFloat32Array()
	var thrusters: Array[EngineModule] = []
	var thruster_performance := PackedFloat32Array()
	for i in _modules.size():
		var engine := _modules[i] as EngineModule
		if engine == null:
			continue
		if engine.is_thrusters():
			thrusters.append(engine)
			thruster_performance.append(get_module_performance(i))
		else:
			mains.append(engine)
			main_performance.append(get_module_performance(i))
	_main_drive = EngineModule.combine(mains, main_performance, _main_drive) if not mains.is_empty() else null
	_thrusters = EngineModule.combine(thrusters, thruster_performance, _thrusters) if not thrusters.is_empty() else null
	var ship := host as Spaceship
	if ship == null:
		return
	ship.main_engine = _main_drive
	ship.thrusters = _thrusters
	ship.main_engine_online = not is_destroyed and _main_drive != null and _main_drive.max_thrust > 0.0
	ship.thrusters_online = not is_destroyed and _thrusters != null \
		and (_thrusters.max_thrust > 0.0 or _thrusters.turn_torque > 0.0)

#endregion


#region Damage

## A hit of `damage` points with `profile`. `direction` is the round's world velocity relative to the hull (zero when
## unknown). Returns the points that got through the armor.
func take_hit(damage: int, profile: ArmorGrid.DamageProfile = ArmorGrid.DamageProfile.KINETIC,
		direction: Vector2 = Vector2.ZERO) -> int:
	if is_destroyed or damage <= 0:
		return 0
	_flash = 0.3
	var through := _resolve_hit(damage, profile, direction)
	hit_taken.emit(damage, through)
	return through


## Applies a hit to the armor and what lies behind it. Overridden by the subclasses.
func _resolve_hit(_damage: int, _profile: ArmorGrid.DamageProfile, _direction: Vector2) -> int:
	return 0


## Damage from inside the hull (a magazine cooking off), starting at module `origin` (-1: anywhere). Overridden by the
## subclasses.
func apply_internal_damage(_points: int, _origin: int = -1) -> void:
	pass


## Fraction of armor left. Overridden by the subclasses.
func get_armor_integrity() -> float:
	return 1.0


## `damage` points reach module `index` at once: a fuel tank vents fuel, anything else is knocked out with a chance of
## damage / hits to kill. Returns true when it was knocked out.
func damage_module(index: int, damage: int) -> bool:
	var module := get_module(index)
	if module == null or damage <= 0 or is_destroyed:
		return false
	module_hit.emit(index, damage)
	if module.is_fuel_tank():
		_leak_fuel(index, damage)
		return false
	if not is_module_operational(index) or get_module_bit(index) == NO_BIT:
		return false
	if rng.randf() >= module.get_kill_chance(damage, get_module_installed_size(index)):
		return false
	set_module_operational(index, false)
	return true


## Knocks a module out or brings it back online, with everything that follows (engines, a magazine cooking off).
func set_module_operational(index: int, operational: bool) -> void:
	var bit := get_module_bit(index)
	if bit == NO_BIT or is_module_operational(index) == operational:
		return
	if operational:
		offline_mask &= ~(1 << bit)
		_repair_work.erase(index)
		_update_engines()
		module_restored.emit(index)
		return
	offline_mask |= 1 << bit
	_update_engines()
	module_offline.emit(index)
	if get_module(index).kind == ShipModule.Kind.MAGAZINE:
		apply_internal_damage(MAGAZINE_EXPLOSION, index)


func _leak_fuel(index: int, damage: int) -> void:
	var fraction := fuel_loss_per_hit * damage
	fuel_lost += fraction
	var ship := host as Spaceship
	if ship:
		ship.fuel = maxf(ship.fuel - fraction * ship.fuel_capacity, 0.0)
	fuel_leaked.emit(index, fraction)


## Destroys the hull outright.
func break_up() -> void:
	_destroy()


func _destroy() -> void:
	if is_destroyed:
		return
	is_destroyed = true
	destroyed.emit()
	var ship := host as Spaceship
	if ship:
		ship.main_engine_online = false
		ship.thrusters_online = false
		ship.cancel_burn()
	if host == null:
		return
	# A wreck left in place keeps its sensor track; a ship that breaks up ends it with the flash.
	CombatExplosion.spawn(host.get_parent(), get_world_position(), hit_radius * 6.0, _get_wreck_size(),
		"Ship destroyed", get_sensor_suite() if free_on_destroyed else null)
	if free_on_destroyed:
		host.queue_free()


## Size of the explosion when the hull is destroyed.
func _get_wreck_size() -> int:
	var total := 0.0
	for module in _modules:
		if module:
			total += module.size
	return maxi(ceili(total), 1)

#endregion


#region Repairs

func needs_repair(index: int) -> bool:
	return get_module(index) != null and not is_module_operational(index)


## Seconds of crew work to bring module `index` back online.
func get_repair_time(index: int) -> float:
	return get_module(index).get_maintenance_cost(get_module_installed_size(index)) * repair_time_per_cost


## 0..1 progress of the repair of an offline module.
func get_repair_progress(index: int) -> float:
	if not needs_repair(index):
		return 1.0
	var time := get_repair_time(index)
	return clampf(_repair_work.get(index, 0.0) / time, 0.0, 1.0) if time > 0.0 else 1.0


## Crew put `seconds` of work into an offline module. Returns true once it is back online.
func add_repair_work(index: int, seconds: float) -> bool:
	if not needs_repair(index):
		return true
	var work: float = _repair_work.get(index, 0.0) + seconds
	if work >= get_repair_time(index):
		set_module_operational(index, true)
		return true
	_repair_work[index] = work
	return false


## Brings a module straight back online. Returns false when it was not offline.
func repair_module(index: int) -> bool:
	if not needs_repair(index):
		return false
	set_module_operational(index, true)
	return true

#endregion


func _draw() -> void:
	# Weapon arcs and the contact marker in screen orientation, kept the same size on screen when zoomed out. The
	# selected contact's brackets and target line are the CombatOverlay's.
	draw_set_transform(Vector2.ZERO, -global_rotation)
	for weapon in _weapons:
		if weapon.wants_redraw():
			weapon.draw(self)
	var scale_factor := SpaceScale.draw_scale(self)
	var r := (hit_radius + 4.0) * scale_factor
	var manager := SpaceCombatManager.find(get_tree())
	var player_side := manager.player_faction if manager else Constants.PLAYER_GROUP
	var color := Color(1.0, 0.35, 0.3) if is_hostile_to(player_side) else Color(0.4, 0.9, 1.0)
	if is_destroyed:
		color = Color(0.5, 0.5, 0.5)
	if faction != player_side:
		var diamond := PackedVector2Array([Vector2(r, 0), Vector2(0, r), Vector2(-r, 0), Vector2(0, -r), Vector2(r, 0)])
		draw_polyline(diamond, color, 1.0 * scale_factor)
	if _flash > 0.0:
		draw_circle(Vector2.ZERO, r * 0.8, Color(1.0, 0.9, 0.6, _flash / 0.3 * 0.7))
