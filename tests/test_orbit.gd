extends SceneTree
## Runs the orbital scene under the campaign: arrival, orbital time and maintenance, pirate demands, combat
## preparation, module knockouts and repairs, the boarding countdown, and the FTL limit.
## Run: godot --headless --path . --script res://tests/test_orbit.gd

var _failures := 0
var _checks := 0


func check(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		printerr("FAIL: ", label)


func _initialize() -> void:
	await process_frame
	var campaign: Node = root.get_node("Campaign")
	campaign.listen_to_chat = false
	campaign.auto_scene_changes = false
	campaign.new_game(4242)
	campaign.finish_expedition({"crew_rescued": 10})
	var site: PlanetSite = campaign.star_map.get_current()
	site.faction = PlanetSite.Faction.PIRATES
	site.enemy_ships = 1
	campaign.orbit_stage = campaign.OrbitStage.FTL_LIMIT
	var scene: Node = load("res://ui/ship_console/ship_hud.tscn").instantiate()
	root.add_child(scene)
	current_scene = scene
	for f: int in 30:
		await physics_frame
	var orbit = root.find_child("CampaignOrbit", true, false)
	check(orbit != null and orbit.site == site, "the orbit scene picks up the campaign")
	check(orbit.outside_ftl_limit, "the ship arrives at the FTL limit")
	check(orbit.can_engage_ftl(), "FTL can be engaged at the limit")
	var expected_fuel: float = campaign.stores.fuel * CampaignOrbit.FUEL_SCALE
	check(absf(orbit.ship.fuel - expected_fuel) < 0.5, "ship fuel follows the campaign stores")
	check(orbit.hull.get_module_count() == campaign.ship.modules.size(), "hull modules come from the campaign ship")
	# Orbital time runs the maintenance clocks.
	var clock: float = campaign.ship.modules[0].maintenance_clock
	for f: int in 60:
		await physics_frame
	check(campaign.ship.modules[0].maintenance_clock < clock, "orbital time wears down maintenance")
	# Pirates: move next to the gunship.
	var gunship: Node = null
	for node: Node in get_nodes_in_group(ShipHull.GROUP):
		if node.has_meta(&"campaign_faction"):
			gunship = node
	check(gunship != null and gunship.faction == &"", "pirates hold fire before making demands")
	var supplies: float = campaign.stores.supplies
	_place(orbit.ship, gunship.host.global_position + Vector2(0.5, 0))
	for f: int in 10:
		await physics_frame
	print("  debug: player %s gunship %s dist %.1f reach %.1f contacts %s phase %d" % [orbit.hull.get_world_position(),
		gunship.get_world_position(), orbit.hull.get_world_position().distance_to(gunship.get_world_position()),
		orbit._max_range(gunship), orbit.contacts.values(), campaign.phase])
	check(orbit.encounter == CampaignOrbit.Encounter.DEMAND, "pirates make demands when in range (%d)" % orbit.encounter)
	check(paused, "the game pauses for the demand")
	orbit.answer_demand(false)
	check(gunship.faction == Constants.ENEMY_GROUP and orbit.encounter == CampaignOrbit.Encounter.PREPARING, "refusing starts combat preparation")
	check(campaign.ship.weapons_loaded and campaign.stores.supplies < supplies, "weapons are loaded from supplies")
	orbit.prep_left = 0.01
	for f: int in 5:
		await physics_frame
	check(orbit.encounter == CampaignOrbit.Encounter.COMBAT and campaign.ship.combat_power, "combat power after preparation")
	# A knockout reaches the campaign and damage control brings it back in combat.
	var sensors := -1
	for i: int in campaign.ship.modules.size():
		if campaign.ship.modules[i].get_kind() == ShipModule.Kind.SENSORS:
			sensors = i
	orbit.hull.set_module_operational(sensors, false)
	check(not campaign.ship.modules[sensors].online, "a knocked out module is offline in the campaign")
	var waited := 0
	while not campaign.ship.modules[sensors].online and waited < 900:
		await physics_frame
		waited += 1
	check(campaign.ship.modules[sensors].online, "damage control repairs it (%d frames)" % waited)
	# Crew at a hit module get hurt.
	var bridge_crew: Array = campaign.crew.filter(func(r: CrewRecord) -> bool: return r.assigned_module == 0)
	for i: int in 6:
		orbit._on_module_hit(0, 6)
	check(orbit.casualties.injured + orbit.casualties.dead > 0 or bridge_crew.is_empty(), "hits on a module wound its crew")
	# Boarding: the gunship sits right next to us and we don't shoot back.
	orbit._last_fire_time = -100.0
	_place(orbit.ship, gunship.host.global_position + Vector2(0.5, 0))
	orbit.ship.linear_velocity = gunship.host.linear_velocity
	var frames := 0
	while campaign.phase == campaign.Phase.ORBIT and frames < 900:
		_place(orbit.ship, gunship.host.global_position + Vector2(0.5, 0))
		await physics_frame
		frames += 1
	check(campaign.phase == campaign.Phase.EXPEDITION and campaign.pending_expedition.get("boarding", false),
		"the enemy boards after the countdown (%d frames)" % frames)
	print("orbit: log tail: ", campaign.log_lines.slice(maxi(0, campaign.log_lines.size() - 8)))
	print("orbit: %d checks, %d failures" % [_checks, _failures])
	print("orbit: %s" % ("OK" if _failures == 0 else "FAILED"))
	quit(1 if _failures else 0)


func _place(body: RigidBody2D, at: Vector2) -> void:
	if body.has_method("is_parked") and body.is_parked():
		body.unpark()
	body.auto_park = false
	PhysicsServer2D.body_set_state(body.get_rid(), PhysicsServer2D.BODY_STATE_TRANSFORM, Transform2D(0.0, at))
	body.global_position = at
