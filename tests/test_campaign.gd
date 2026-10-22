extends SceneTree
## Headless checks for the campaign layer: stores and cargo limits, the medical simulation, maintenance and
## malfunctions, reactor fuel, the FTL map, Twitch crew slots, win/lose rules and save/load.
## Run: godot --headless --path . --script res://tests/test_campaign.gd

var _failures := 0
var _checks := 0


func _initialize() -> void:
	_test_stores()
	_test_medical()
	_test_robot()
	_test_maintenance()
	_test_reactor()
	await process_frame
	_test_campaign()
	_test_roster()
	_test_save_load()
	print("campaign: %d checks, %d failures" % [_checks, _failures])
	print("campaign: %s" % ("OK" if _failures == 0 else "FAILED"))
	quit(1 if _failures else 0)


func check(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		printerr("FAIL: ", label)


func _test_stores() -> void:
	var config := GameConfig.new()
	var stores := ShipStores.new(config)
	stores.fuel_tanks = 1
	stores.cargo_holds = 1
	check(is_equal_approx(stores.add(ShipStores.FUEL, 150.0), config.fuel_per_tank), "fuel beyond the tanks is left behind")
	check(is_equal_approx(stores.add(ShipStores.METAL, 30.0), 30.0), "metal fits")
	check(is_equal_approx(stores.add(ShipStores.SUPPLIES, 30.0), config.cargo_per_hold - 30.0), "metal and supplies share the hold")
	check(not stores.spend(ShipStores.METAL, 31.0), "can't spend more than stored")
	check(stores.mass() > 0.0, "stored resources have mass")
	var before := stores.cargo_capacity()
	check(stores.build_storage(false) and stores.cargo_capacity() > before, "build a cargo hold for metal")


func _test_medical() -> void:
	var config := GameConfig.new()
	var body := MedicalBody.new(config)
	check(body.get_status() == MedicalBody.Status.STABLE, "healthy body is stable")
	body.take_damage(20.0, MedicalBody.DamageType.PIERCE, MedicalBody.THORAX)
	check(body.total_bleed() > 0.3, "a gunshot opens a bleeding wound")
	check(body.get_status() >= MedicalBody.Status.BLEEDING, "wounded body reports bleeding")
	var blood_before := body.blood
	for i: int in 60:
		body.step(1.0, 0.5)
	check(body.blood < blood_before, "bleeding loses blood")
	check(not body.dead, "one wound does not kill within a minute")
	var bleed_before := body.total_bleed()
	body.apply_dressing(MedicalBody.THORAX)
	body.step(10.0)
	check(body.total_bleed() < bleed_before * 0.3, "a dressing stops most bleeding")
	# Clotting slows bleeding over time.
	var clot := MedicalBody.new(config)
	clot.take_damage(10.0, MedicalBody.DamageType.CUT, MedicalBody.ARM_L)
	var start := clot.total_bleed()
	for i: int in 180:
		clot.step(1.0)
	check(clot.total_bleed() < start * 0.5, "wounds clot over time")
	# Massive trauma: unconscious long before dead.
	var heavy := MedicalBody.new(config)
	for part: StringName in [MedicalBody.THORAX, MedicalBody.ABDOMEN, MedicalBody.LEG_L, MedicalBody.LEG_R]:
		heavy.take_damage(35.0, MedicalBody.DamageType.PIERCE, part)
	var fell_unconscious_at := -1
	var died_at := -1
	for i: int in 900:
		heavy.step(1.0, 0.2)
		if fell_unconscious_at < 0 and not heavy.is_conscious():
			fell_unconscious_at = i
		if heavy.dead:
			died_at = i
			break
	check(fell_unconscious_at >= 0, "massive trauma knocks out")
	check(died_at < 0 or died_at > fell_unconscious_at + 20, "death comes well after unconsciousness")
	# A stopped heart starves the brain within a few minutes; CPR can restart it.
	var arrest := MedicalBody.new(config)
	arrest.cardiac_arrest = true
	for i: int in 30:
		arrest.step(1.0)
	check(arrest.blood_o2 < 60.0 and arrest.get_status() == MedicalBody.Status.DYING, "cardiac arrest is dying")
	var revived := false
	for attempt: int in 20:
		if arrest.resuscitate(3.0):
			revived = true
			break
	check(revived and not arrest.cardiac_arrest, "resuscitation can restart the heart")
	var starved := MedicalBody.new(config)
	starved.cardiac_arrest = true
	starved.rng.seed = 1
	for i: int in 600:
		starved.step(1.0)
		starved.cardiac_arrest = true
	check(starved.dead, "brain dies after minutes without oxygen")
	# Limbs.
	var legs := MedicalBody.new(config)
	legs.take_damage(60.0, MedicalBody.DamageType.BLUNT, MedicalBody.LEG_L)
	check(legs.parts[MedicalBody.LEG_L].is_disabled(), "a limb at 0 is disabled")
	check(legs.move_multiplier() < 0.8, "a disabled leg slows movement")
	var boom := MedicalBody.new(config)
	boom.take_damage(80.0, MedicalBody.DamageType.EXPLOSIVE, MedicalBody.ARM_R, true)
	check(boom.parts[MedicalBody.ARM_R].amputated and boom.needs_augmentation(), "huge explosions dismember")
	# The medical bay heals everything but the amputation.
	boom.step(5.0)
	var used := boom.medbay_heal(1000.0)
	check(used > 0.0 and boom.parts[MedicalBody.ARM_R].amputated, "medbay can't regrow limbs")
	boom.augment()
	check(not boom.needs_augmentation() and boom.parts[MedicalBody.ARM_R].bionic, "bionics replace lost limbs")
	# Save round trip.
	var copy := MedicalBody.new(config)
	copy.load_dict(heavy.to_dict())
	check(is_equal_approx(copy.blood, heavy.blood) and copy.parts[MedicalBody.THORAX].hp == heavy.parts[MedicalBody.THORAX].hp,
		"medical state survives a save")


func _test_robot() -> void:
	var robot := MedicalBody.new(GameConfig.new(), true)
	robot.take_damage(30.0, MedicalBody.DamageType.ELECTRIC)
	check(robot.battery < 100.0 and robot.total_bleed() == 0.0, "electric attacks drain a robot's battery")
	robot.take_damage(40.0, MedicalBody.DamageType.EMP)
	check(robot.consciousness_cap < 100.0, "EMP lowers the consciousness cap")


func _test_maintenance() -> void:
	var config := GameConfig.new()
	var module := ModuleState.create("res://data/components/sensors.tres", &"hypa_spark", config)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	check(module.maintenance_clock == config.default_maintenance_interval, "clock starts at the interval")
	check(not module.tick(100.0, 1.0, rng), "no malfunction checks before the clock runs out")
	module.maintenance_clock = 0.0
	check(module.malfunction_chance() > 0.0, "malfunction chance at 0 maintenance")
	module.maintenance_clock = -module.maintenance_interval()
	check(module.malfunction_chance() > config.malfunction_base_chance, "chance rises the longer it is overdue")
	var failures := 0
	for i: int in 50:
		module.maintenance_clock = -module.maintenance_interval() * 2.0
		if module.tick(600.0, 1.0, rng):
			failures += 1
	check(failures > 0, "badly overdue modules malfunction")
	module.malfunctions.append(ModuleState.Malfunction.GIMBAL_MISALIGNMENT)
	module.maintain()
	check(module.malfunctions.is_empty() and module.maintenance_clock > 0.0, "maintenance clears malfunctions")
	var wastrel := ModuleState.create("res://data/components/sensors.tres", &"wastrel", config)
	check(wastrel.maintenance_interval() > module.maintenance_interval(), "W. Wastrel lasts longer between maintenance")
	var nostro := ModuleState.create("res://data/components/torpedo_tubes.tres", &"nostro", config)
	check(not nostro.combat_malfunction_pool().has(ModuleState.Malfunction.JAM), "Nostro weapons never jam")
	var ship := ShipState.create_starting_ship(config)
	var weapon := ship.find_kind(ShipModule.Kind.WEAPON)[0]
	ship.apply_malfunction(weapon, ModuleState.Malfunction.GIMBAL_MISALIGNMENT)
	ship.apply_malfunction(weapon, ModuleState.Malfunction.GIMBAL_MISALIGNMENT)
	check(is_equal_approx(weapon.accuracy_multiplier(), 0.9), "gimbal misalignment stacks")
	var reactor := ship.find_kind(ShipModule.Kind.REACTOR)[0]
	ship.apply_malfunction(reactor, ModuleState.Malfunction.MAIN_BUS_FAULT)
	var capacity := ship.power_capacity()
	ship.apply_malfunction(reactor, ModuleState.Malfunction.MAJOR_POWER_SURGE)
	check(ship.power_capacity() > capacity, "a major power surge clears a main bus fault")
	var knocked := 0
	for i: int in 200:
		var target := ModuleState.create("res://data/components/structure.tres", &"hypa_spark", config)
		ship.modules.append(target)
		if ship.hit_module(target, target.hits_to_kill() * 0.5, false):
			knocked += 1
		ship.modules.erase(target)
	check(knocked > 60 and knocked < 140, "half the hits to kill knocks out about half the time (%d/200)" % knocked)


func _test_reactor() -> void:
	var config := GameConfig.new()
	config.reactor_cruise_output = 1.0
	var ship := ShipState.create_starting_ship(config)
	var full := ship.reactor_fuel_rate()
	config.reactor_cruise_output = 0.5
	for module: ModuleState in ship.modules:
		module.powered = false
	var half := ship.reactor_fuel_rate()
	check(full > 0.0 and is_equal_approx(half / full, 0.25), "reactor fuel goes with output squared")
	check(ship.essential_crew_required() >= 4, "bridge, reactor and engines need crew")


func _campaign() -> Node:
	return root.get_node("Campaign")


func _test_campaign() -> void:
	var campaign := _campaign()
	campaign.listen_to_chat = false
	campaign.auto_scene_changes = false
	campaign.new_game(1234)
	check(campaign.phase == campaign.Phase.INTRO, "new game starts in the intro dungeon")
	check(campaign.star_map.sites.size() == campaign.config.map_systems, "star map has all its systems")
	check(campaign.star_map.reachable_from(0).size() == campaign.star_map.sites.size(), "every system is reachable")
	var result := {"fuel": 10.0, "metal": 5.0, "supplies": 5.0, "crew_rescued": 6, "completed": true}
	campaign.finish_expedition(result)
	check(campaign.phase == campaign.Phase.ORBIT and campaign.is_in_low_orbit(), "after the intro the ship is in low orbit")
	check(campaign.rescued_crew_count() == 6, "rescued crew join")
	check(campaign.lose_reason().is_empty(), "a fresh crew is not a loss")
	# FTL.
	campaign.reach_ftl_limit()
	check(campaign.phase == campaign.Phase.FTL_MAP, "the FTL limit opens the map")
	var target := -1
	for site: PlanetSite in campaign.star_map.sites:
		if campaign.star_map.in_range(0, site.id):
			target = site.id
			break
	var fuel_before: float = campaign.stores.fuel
	var cost: float = campaign.star_map.jump_cost(0, target, campaign.config, campaign.stores.mass())
	check(campaign.ftl_jump(target).is_empty(), "jump to a system in range")
	check(is_equal_approx(campaign.stores.fuel, fuel_before - cost), "a jump costs its fuel")
	# A heavier ship pays more for the same jump.
	var light: float = campaign.star_map.jump_cost(0, target, campaign.config, 0.0)
	check(cost > light, "cargo mass makes jumps cost more")
	# Lose: out of fuel away from a planet.
	campaign.stores.fuel = 0.0
	campaign.orbit_stage = campaign.OrbitStage.IN_TRANSIT
	check(not campaign.lose_reason().is_empty(), "no fuel outside low orbit loses")
	campaign.orbit_stage = campaign.OrbitStage.LOW_ORBIT
	check(campaign.lose_reason().is_empty(), "no fuel in low orbit with an expedition left is not lost yet")
	campaign.stores.supplies = 0.0
	check(not campaign.lose_reason().is_empty(), "no fuel and no supplies for an expedition loses")
	campaign.stores.supplies = 30.0
	campaign.stores.fuel = 50.0
	# Lose: not enough crew for the essential modules.
	var alive: Array = campaign.living_crew()
	for record: CrewRecord in alive:
		if not record.is_player:
			campaign.kill(record, "test")
	check(not campaign.lose_reason().is_empty(), "too few crew for the essential modules loses")
	# Win.
	campaign.new_game(99)
	campaign.finish_expedition({"crew_rescued": campaign.config.crew_to_win})
	check(not campaign.can_jump_home(), "need fuel to go home")
	campaign.stores.fuel_tanks = 10
	campaign.stores.fuel = campaign.config.fuel_to_win
	check(campaign.can_jump_home() and campaign.jump_home().is_empty(), "enough fuel and crew wins")
	check(campaign.phase == campaign.Phase.VICTORY, "victory phase")


func _test_roster() -> void:
	var campaign := _campaign()
	var roster: Node = root.get_node("Crew")
	roster.members.clear()
	roster.slots.fill(null)
	campaign.new_game(5)
	campaign.finish_expedition({"crew_rescued": 6})
	check(roster.crew_size == 6, "one chat slot per generic crewmember")
	roster.register_message("u1", "alice", "Alice", "hello")
	roster.register_message("u2", "bob", "Bob", "hi")
	var controlled: Array = campaign.crew.filter(func(r: CrewRecord) -> bool: return r.is_chat_controlled())
	check(controlled.size() == 2, "chatters take control of crewmembers")
	campaign.listen_to_chat = true
	campaign.handle_chat("u1", "alice", "!explore 3")
	var alice: CrewRecord = controlled.filter(func(r: CrewRecord) -> bool: return r.controller_id == "u1")[0]
	check(alice.stance == CrewRecord.Stance.EXPLORE and alice.explore_group == 3, "!explore 3 sets the stance and group")
	campaign.handle_chat("u1", "alice", "!medic")
	check(alice.stance == CrewRecord.Stance.MEDIC, "!medic")
	roster.register_message("u1", "alice", "Alice", "!lurk")
	check(not alice.is_chat_controlled(), "!lurk hands the crewmember back to the NPC")
	roster.register_message("u3", "carol", "Carol", "yo")
	var bob: CrewRecord = campaign.crew.filter(func(r: CrewRecord) -> bool: return r.controller_id == "u2")[0]
	campaign.kill(bob, "test")
	check(roster.crew_size == 5, "a dead crewmember's slot is lost")
	check(roster.get_member("u2").extra.get("back_of_queue", false) or roster.get_member("u2").is_on_crew(),
		"the chatter goes to the back of the queue")
	campaign.listen_to_chat = false
	roster.members.clear()
	roster.slots.fill(null)


func _test_save_load() -> void:
	var campaign := _campaign()
	campaign.new_game(777)
	campaign.finish_expedition({"fuel": 12.0, "metal": 3.0, "crew_rescued": 6})
	var record: CrewRecord = campaign.crew[1]
	record.body.take_damage(15.0, MedicalBody.DamageType.CUT, MedicalBody.ARM_L)
	record.skills[CrewRecord.REPAIR] = 2.0
	campaign.ship.modules[0].maintenance_clock = -5.0
	campaign.ship.modules[0].malfunctions.append(ModuleState.Malfunction.FUEL_LEAK)
	var data: Dictionary = campaign.to_dict()
	# Through the same path as the SaveSystem: store_var and back.
	var bytes := var_to_bytes(data)
	var restored: Dictionary = bytes_to_var(bytes)
	var fuel: float = campaign.stores.fuel
	campaign.new_game(1)
	campaign.load_dict(restored)
	check(is_equal_approx(campaign.stores.fuel, fuel), "stores survive a save")
	check(campaign.crew.size() == 7, "crew survive a save")
	check(campaign.crew[1].skills[CrewRecord.REPAIR] == 2.0, "skills survive a save")
	check(campaign.crew[1].body.parts[MedicalBody.ARM_L].hp < 30.0, "injuries survive a save")
	check(campaign.ship.modules[0].malfunctions.has(ModuleState.Malfunction.FUEL_LEAK), "malfunctions survive a save")
	check(campaign.star_map.sites.size() == campaign.config.map_systems and campaign.star_map.sites[0].visited,
		"the map survives a save")
	check(campaign.phase == campaign.Phase.ORBIT, "phase survives a save")
