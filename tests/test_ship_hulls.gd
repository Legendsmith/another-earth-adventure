extends SceneTree
## Headless checks for ShipHull and its modules: the size bonus, knockout chances and the offline bitmask, SimpleHull
## damage, engines as modules and weapon groups. Run: godot --headless --path . --script res://tests/test_ship_hulls.gd

var _failures := 0


## A weapon that fires whenever it is operational, counting its shots.
class TestWeapon extends WeaponModule:
	var shots := 0

	func _init() -> void:
		name = "Test gun"
		kind = Kind.WEAPON
		max_range = 1e9

	func is_ready() -> bool:
		return true

	func fire_at(target: ShipHull) -> bool:
		if not can_engage(target):
			return false
		shots += 1
		return true


func _initialize() -> void:
	await process_frame
	_test_size_bonus()
	_test_kill_chance()
	_test_simple_hull()
	_test_bitmask()
	await _test_engines()
	await _test_weapon_groups()
	print("ship hulls: %s" % ("OK" if _failures == 0 else "%d FAILED" % _failures))
	quit(1 if _failures else 0)


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures += 1
		push_error("FAIL: " + message)


func _module(module_name: String, kind: ShipModule.Kind, size: float, hits_to_kill: int) -> ShipModule:
	var module := ShipModule.new()
	module.name = module_name
	module.kind = kind
	module.size = size
	module.hits_to_kill = hits_to_kill
	return module


func _engine(engine_name: String, kind: ShipModule.Kind, thrust: float, exhaust: float) -> EngineModule:
	var engine := EngineModule.new()
	engine.name = engine_name
	engine.kind = kind
	engine.max_thrust = thrust
	engine.exhaust_velocity = exhaust
	engine.turn_torque = 10.0 if kind == ShipModule.Kind.THRUSTERS else 0.0
	engine.hits_to_kill = 1
	return engine


func _hull(modules: Array[ShipModule], parent: Node = null) -> SimpleHull:
	var hull := SimpleHull.new()
	hull.modules = modules
	hull.free_on_destroyed = false
	(parent if parent else root).add_child(hull)
	hull.rng.seed = 42
	return hull


func _test_size_bonus() -> void:
	_check(ShipModule.size_bonus(2.0, 2.0) == 0.0, "no bonus at the base size")
	_check(ShipModule.size_bonus(2.0, 1.0) == 0.0, "no bonus below it")
	_check(is_equal_approx(ShipModule.size_bonus(2.0, 4.0), 2.0 / 3.0), "two thirds of the bonus at twice the size")
	_check(is_equal_approx(ShipModule.size_bonus(2.0, 8.0), 1.0), "the full bonus at four times the size")
	_check(ShipModule.size_bonus(2.0, 20.0) == 1.0, "and no more beyond it")
	var gains: Array[float] = []
	for cells in range(2, 9):
		gains.append(ShipModule.size_bonus(2.0, cells + 1) - ShipModule.size_bonus(2.0, cells))
	_check(gains[0] > gains[1] and gains[1] > gains[2], "each extra cell is worth less than the last")

	var weapon := _module("Gun", ShipModule.Kind.WEAPON, 2.0, 4)
	_check(weapon.get_hits_to_kill(2.0) == 4.0 and is_equal_approx(weapon.get_hits_to_kill(8.0), 12.0),
		"weapons get up to 3x the hits to kill")
	_check(weapon.get_maintenance_cost(8.0) == weapon.maintenance_cost and weapon.get_effectiveness(8.0) == 1.0,
		"and nothing else")
	var reactor := _module("Reactor", ShipModule.Kind.REACTOR, 2.0, 4)
	_check(is_equal_approx(reactor.get_hits_to_kill(8.0), 6.0), "engineering gets up to 1.5x the hits to kill")
	_check(is_equal_approx(reactor.get_maintenance_cost(8.0), reactor.maintenance_cost * 0.5),
		"and half the maintenance cost")
	_check(is_equal_approx(_engine("Drive", ShipModule.Kind.MAIN_ENGINE, 1.0, 1.0).get_maintenance_cost(12.0),
		5.0), "engines are engineering")
	var sensors := _module("Sensors", ShipModule.Kind.SENSORS, 2.0, 1)
	_check(is_equal_approx(sensors.get_effectiveness(8.0), 1.5) and sensors.get_hits_to_kill(8.0) == 1.0,
		"electronics get up to 1.5x the effectiveness")
	var quarters := _module("Quarters", ShipModule.Kind.CREW, 2.0, 1)
	_check(quarters.get_hits_to_kill(8.0) == 1.0 and quarters.get_effectiveness(8.0) == 1.0, "crew quarters get nothing")


func _test_kill_chance() -> void:
	var module := _module("Box", ShipModule.Kind.STRUCTURE, 1.0, 4)
	_check(module.get_kill_chance(0) == 0.0, "no damage, no chance")
	_check(module.get_kill_chance(4) == 1.0 and module.get_kill_chance(9) == 1.0, "hits to kill or more is certain")
	_check(module.get_kill_chance(1) == 0.25, "less is damage / hits to kill")
	var hull := _hull([module])
	var knocked := 0
	var trials := 4000
	for i in trials:
		if hull.damage_module(0, 1):
			knocked += 1
			hull.repair_module(0)
	var share := float(knocked) / trials
	_check(absf(share - 0.25) < 0.03, "a 1-point hit on 4 hits to kill knocks it out a quarter of the time (%.3f)" % share)
	hull.free()


func _test_simple_hull() -> void:
	var big := _module("Big", ShipModule.Kind.STRUCTURE, 3.0, 99)
	var small := _module("Small", ShipModule.Kind.STRUCTURE, 1.0, 99)
	var hull := _hull([big, small])
	_check(hull.internal_size == 4.0 and hull.structure == 4, "internal size and structure default to the modules")
	_check(hull.get_module(0) != big, "the hull works on its own copies")
	var counts := [0, 0, 0]
	for i in 4000:
		counts[hull.pick_module() + 1] += 1
	_check(counts[0] == 0, "with the default internal size every hit finds a module")
	_check(absf(counts[1] / 4000.0 - 0.75) < 0.03, "modules are hit by size (%d to %d)" % [counts[1], counts[2]])
	hull.free()

	hull = SimpleHull.new()
	hull.modules = [_module("Box", ShipModule.Kind.STRUCTURE, 1.0, 1)] as Array[ShipModule]
	hull.internal_size = 4.0
	hull.structure = 1000
	root.add_child(hull)
	var misses := 0
	for i in 4000:
		if hull.pick_module() < 0:
			misses += 1
	_check(absf(misses / 4000.0 - 0.75) < 0.03, "the rest of the internal size is empty hull (%d misses)" % misses)
	var hits: Array = []
	hull.module_hit.connect(func(index: int, damage: int) -> void: hits.append([index, damage]))
	for i in 40:
		hull.apply_internal_damage(5)
	_check(not hits.is_empty() and hits.all(func(hit: Array) -> bool: return hit[1] == 5),
		"a hit strikes one module with all its points at once")
	_check(hull.structure_left == 1000 - 200, "every point comes off the structure")
	hull.free()

	# A magazine cooks off when knocked out.
	var magazine := _module("Magazine", ShipModule.Kind.MAGAZINE, 1.0, 1)
	hull = _hull([magazine, _module("Hull", ShipModule.Kind.STRUCTURE, 1.0, 999)])
	var before := hull.structure_left
	hull.set_module_operational(0, false)
	_check(hull.structure_left == before - ShipHull.MAGAZINE_EXPLOSION, "a magazine cooks off inside the hull")
	hull.free()


func _test_bitmask() -> void:
	var modules: Array[ShipModule] = []
	for i in 70:
		modules.append(_module("M%d" % i, ShipModule.Kind.STRUCTURE, 1.0, 1))
	modules.insert(3, _module("Tank", ShipModule.Kind.FUEL_TANK, 1.0, 1))
	var hull := _hull(modules)
	_check(hull.get_module_bit(3) == ShipHull.NO_BIT, "fuel tanks take no bit")
	_check(hull.get_module_bit(4) == 3, "bits skip them")
	_check(hull.get_module_bit(64) == 63 and hull.get_module_bit(65) == ShipHull.NO_BIT, "64 modules fit in the mask")
	hull.set_module_operational(64, false)
	hull.set_module_operational(1, false)
	_check(hull.offline_mask == (1 << 63) | (1 << 1), "each offline module sets its bit")
	_check(not hull.is_module_operational(64) and not hull.is_module_operational(1) and hull.is_module_operational(2),
		"and reads back")
	_check(hull.get_offline_modules() == PackedInt32Array([1, 64]), "offline modules are listed")
	hull.set_module_operational(64, true)
	_check(hull.offline_mask == 1 << 1, "repairs clear the bit")
	hull.free()


func _test_engines() -> void:
	var ship := Spaceship.new()
	ship.start_in_circular_orbit = false
	var fast := _engine("Fast", ShipModule.Kind.MAIN_ENGINE, 100.0, 1000.0)
	var slow := _engine("Slow", ShipModule.Kind.MAIN_ENGINE, 100.0, 250.0)
	var thrusters := _engine("Puffers", ShipModule.Kind.THRUSTERS, 5.0, 100.0)
	var hull := SimpleHull.new()
	hull.modules = [fast, slow, thrusters] as Array[ShipModule]
	hull.armor_mass = 0.0
	ship.add_child(hull)
	root.add_child(ship)
	await process_frame
	_check(ship.main_engine and is_equal_approx(ship.main_engine.max_thrust, 200.0), "main engines add their thrust")
	# Total thrust over total mass flow: 200 / (100/1000 + 100/250) = 400.
	_check(is_equal_approx(ship.main_engine.exhaust_velocity, 400.0), "the exhaust velocity is thrust-weighted")
	_check(ship.thrusters and ship.thrusters.max_thrust == 5.0 and ship.thrusters.turn_torque == 10.0,
		"thrusters are their own drive")
	_check(is_equal_approx(ship.get_dry_mass(), ship.dry_mass + 3.0), "every engine counts towards the mass")
	var drive := ship.main_engine
	hull.set_module_operational(0, false)
	_check(ship.main_engine == drive and is_equal_approx(ship.main_engine.max_thrust, 100.0)
		and is_equal_approx(ship.main_engine.exhaust_velocity, 250.0), "an engine knocked out leaves the others")
	_check(ship.main_engine_online, "the drive stays online")
	hull.set_module_operational(1, false)
	_check(not ship.main_engine_online, "the drive goes offline with its last engine")
	hull.set_module_operational(2, false)
	_check(not ship.thrusters_online, "and the thrusters with theirs")
	hull.repair_module(0)
	_check(ship.main_engine_online and is_equal_approx(ship.main_engine.max_thrust, 100.0), "repairs bring it back")
	ship.free()


func _test_weapon_groups() -> void:
	var manager := SpaceCombatManager.new()
	root.add_child(manager)
	var target := _hull([_module("Rock", ShipModule.Kind.STRUCTURE, 1.0, 999)])
	target.faction = &"enemy"
	manager.selected_contact = target
	var guns: Array[ShipModule] = []
	for i in 3:
		guns.append(TestWeapon.new())
	var hull := SimpleHull.new()
	hull.faction = &"player"
	hull.modules = guns
	var pair := WeaponGroup.create("Pair", PackedInt32Array([0, 1]), WeaponGroup.Mode.ALTERNATING)
	hull.weapon_groups = [pair] as Array[WeaponGroup]
	var fire_control := PlayerWeapons.new()
	hull.add_child(fire_control)
	root.add_child(hull)
	await process_frame
	var weapons := hull.get_weapons()
	_check(weapons.size() == 3 and weapons[0] is TestWeapon and weapons[0].hull == hull, "weapons are bound modules")
	var groups := hull.get_weapon_groups()
	_check(groups.size() == 2 and groups[0].name == "Pair" and groups[1].weapons == PackedInt32Array([2]),
		"weapons left out of the groups get one each")
	_check(groups[0] != pair, "the hull works on copies of its groups")
	var shots := func() -> Array: return weapons.map(func(w: TestWeapon) -> int: return w.shots)

	# Alternating: one weapon per command, in turn.
	fire_control.fire_selected()
	fire_control.fire_selected()
	fire_control.fire_selected()
	_check(shots.call() == [2, 1, 0], "an alternating group fires its weapons in turn (%s)" % [shots.call()])
	hull.set_module_operational(0, false)
	fire_control.fire_selected()
	fire_control.fire_selected()
	_check(shots.call() == [2, 3, 0], "skipping an offline one (%s)" % [shots.call()])
	hull.repair_module(0)

	# Linked: every weapon at once.
	groups[0].mode = WeaponGroup.Mode.LINKED
	fire_control.fire_selected()
	_check(shots.call() == [3, 4, 0], "a linked group fires every weapon (%s)" % [shots.call()])

	# Autofire: toggled by the command, fires on its own while on.
	fire_control.select_group(1)
	groups[1].mode = WeaponGroup.Mode.AUTOFIRE
	await physics_frame
	_check(shots.call()[2] == 0, "autofire is off until switched on")
	fire_control.fire_selected()
	_check(groups[1].active and shots.call()[2] == 0, "the command switches it on without firing")
	await physics_frame
	await physics_frame
	_check(shots.call()[2] >= 2, "it fires on its own every frame it is ready (%d)" % shots.call()[2])
	fire_control.fire_selected()
	var after: int = shots.call()[2]
	await physics_frame
	_check(not groups[1].active and shots.call()[2] == after, "and stops when switched off")
	_check(shots.call()[0] == 3 and shots.call()[1] == 4, "other groups hold fire")
	hull.free()
	target.free()
	manager.free()
