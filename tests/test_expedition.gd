extends SceneTree
## Runs expeditions headless: the intro dungeon (free the prisoners, reach the ship) and a regular expedition with
## crew in every stance, checking the dungeon, the AI and the results handed back to the campaign.
## Run: godot --headless --path . --script res://tests/test_expedition.gd

var _failures := 0
var _checks := 0


func check(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		printerr("FAIL: ", label)


func _initialize() -> void:
	Engine.time_scale = 3.0
	await process_frame
	_test_generator()
	await _test_intro()
	await _test_expedition()
	await _test_boarding()
	print("expedition: %d checks, %d failures" % [_checks, _failures])
	print("expedition: %s" % ("OK" if _failures == 0 else "FAILED"))
	quit(1 if _failures else 0)


func _test_generator() -> void:
	var generator := DungeonGenerator.new()
	generator.generate(42, 12)
	check(generator.rooms.size() >= 8, "dungeon has rooms (%d)" % generator.rooms.size())
	var unreachable := 0
	for room: DungeonGenerator.Room in generator.rooms:
		if room.depth < 0:
			unreachable += 1
	check(unreachable == 0, "every room is connected")
	var prison := 0
	for room: DungeonGenerator.Room in generator.rooms:
		if room.tag == DungeonGenerator.RoomTag.PRISON:
			prison += 1
	check(prison == 1, "one prison in the lower levels")
	check(generator.is_walkable(generator.rooms[0].center()), "entrance is walkable")
	var ship := DungeonGenerator.new()
	ship.generate_ship(3, 8)
	check(ship.rooms.size() == 8 and ship.rooms[7].depth == 7, "ship interior chains its compartments")


func _campaign() -> Node:
	return root.get_node("Campaign")


func _start_scene() -> Expedition:
	var scene: Expedition = load("res://world/expedition/expedition.tscn").instantiate()
	root.add_child(scene)
	current_scene = scene
	await process_frame
	await physics_frame
	scene.player_input_enabled = false
	return scene


func _run(seconds: float, scene: Expedition, each: Callable = Callable()) -> void:
	var end := scene.elapsed + seconds
	var guard := 0
	while scene.elapsed < end and not scene.is_over and guard < 20000:
		guard += 1
		if each.is_valid():
			each.call()
		await physics_frame


func _test_intro() -> void:
	var campaign := _campaign()
	campaign.listen_to_chat = false
	campaign.auto_scene_changes = false
	campaign.new_game(2024)
	var scene := await _start_scene()
	check(scene.mode == Expedition.Mode.INTRO, "new game starts with the intro dungeon")
	check(scene.player != null and scene.player.weapon_id == &"claws", "the captain starts with claws")
	var cells := scene.loot.filter(func(p: LootPile) -> bool: return p.kind == LootPile.Kind.CELL)
	check(cells.size() == 1 and cells[0].prisoners.size() >= campaign.config.intro_rescued_crew, "prisoners wait in a cell")
	# Make the walk safe: remove the enemies, then free the prisoners and walk them to the ship.
	for actor: ExpeditionActor in scene.actors:
		if actor.is_enemy():
			scene.despawn(actor)
	var cell: LootPile = cells[0]
	scene.player.global_position = cell.global_position + Vector2(30, 0)
	await physics_frame
	scene.player_interact()
	check(cell.used, "the cell opens")
	var freed: Array = cell.prisoners.filter(func(a: ExpeditionActor) -> bool: return a.state == &"freed")
	check(freed.size() == cell.prisoners.size(), "prisoners are freed")
	# Prisoners follow the captain.
	var start_d: float = freed[0].global_position.distance_to(scene.entrance_position())
	var target := scene.entrance_position()
	await _run(40.0, scene, func() -> void:
		scene.player.move_to(target, 30.0)
		if scene.player.global_position.distance_to(target) < 60.0:
			scene.player.stop())
	var followed: float = freed[0].global_position.distance_to(scene.entrance_position())
	print("  intro: elapsed %.1f, captain %.0f from the ship, paused=%s" % [scene.elapsed,
		scene.player.global_position.distance_to(target), paused])
	check(followed < start_d, "freed prisoners follow the captain (%.0f -> %.0f)" % [start_d, followed])
	scene.end_expedition("extracted")
	check(scene.is_over, "extraction ends the expedition")
	var result_crew := 0
	scene.finished.connect(func(_r: Dictionary) -> void: pass)
	for actor: ExpeditionActor in scene.actors:
		if actor.role == ExpeditionActor.Role.PRISONER and not actor.body.dead:
			result_crew += 1
	campaign.finish_expedition({"rescued_records": cell.prisoners.map(func(a: ExpeditionActor) -> CrewRecord: return a.record),
		"crew_rescued": cell.prisoners.size()})
	check(campaign.phase == campaign.Phase.ORBIT, "back to orbit after the intro")
	check(campaign.rescued_crew_count() >= result_crew, "the freed prisoners join the crew")
	scene.queue_free()
	await process_frame


func _test_expedition() -> void:
	var campaign := _campaign()
	campaign.new_game(77)
	campaign.finish_expedition({"crew_rescued": 8})
	# Pick a site with enemies and set up an expedition with crew in every stance.
	var site: PlanetSite = campaign.star_map.get_current()
	site.faction = PlanetSite.Faction.PIRATES
	site.expedition_done = false
	campaign.orbit_stage = campaign.OrbitStage.LOW_ORBIT
	var ids: Array = []
	var stances := [CrewRecord.Stance.DEFEND, CrewRecord.Stance.EXPLORE, CrewRecord.Stance.EXPLORE,
		CrewRecord.Stance.ATTACK, CrewRecord.Stance.RESCUE, CrewRecord.Stance.MEDIC]
	var i := 0
	for record: CrewRecord in campaign.active_crew():
		if record.is_player or i >= stances.size():
			continue
		record.stance = stances[i]
		record.explore_group = 2
		ids.append(record.id)
		i += 1
	var supplies_before: float = campaign.stores.supplies
	check(campaign.start_expedition(ids, [ids[0]]).is_empty(), "start an expedition")
	check(campaign.stores.supplies < supplies_before, "expedition gear costs supplies")
	var scene := await _start_scene()
	check(scene.mode == Expedition.Mode.EXPEDITION and scene.actors.size() > ids.size(), "party and enemies spawned")
	var enemies_before := scene.enemies_left()
	var explored_before := 0
	await _run(90.0, scene)
	var explored := 0
	for room: DungeonGenerator.Room in scene.dungeon.rooms:
		if room.explored:
			explored += 1
	check(explored > 1, "explorers explore rooms (%d)" % explored)
	var picked := 0.0
	for actor: ExpeditionActor in scene.actors:
		picked += actor.carry_weight()
	picked += scene.deposited.fuel + scene.deposited.metal + scene.deposited.supplies
	print("  after 90 s: explored %d rooms, enemies %d -> %d, loot moved %.1f" % [explored, enemies_before,
		scene.enemies_left(), picked])
	var injured := 0
	for actor: ExpeditionActor in scene.actors:
		if actor.faction == ExpeditionActor.PLAYER_FACTION and actor.body.get_status() > MedicalBody.Status.STABLE:
			injured += 1
	print("  injured crew: %d" % injured)
	for actor: ExpeditionActor in scene.actors:
		if actor.role == ExpeditionActor.Role.CREW:
			var room: DungeonGenerator.Room = scene.dungeon.room_at(actor.global_position)
			print("    %s %s state=%s room=%s carry=%.1f %s ammo=%d" % [actor.display_name, CrewRecord.STANCE_NAMES[actor.record.stance],
				actor.state, room.index if room else -1, actor.carry_weight(), actor.body.get_status_name(), actor.ammo])
	check(scene.enemies_left() < enemies_before or picked > 0.0, "the crew fights or loots")
	# Chat commands reach the actors.
	var chat_record: CrewRecord = campaign.get_record(ids[0])
	chat_record.controller_id = "chatter"
	chat_record.controller_name = "Chatter"
	campaign.listen_to_chat = true
	campaign.handle_chat("chatter", "chatter", "hello crew")
	var actor_for_chat: ExpeditionActor = scene.actors.filter(func(a: ExpeditionActor) -> bool: return a.record == chat_record)[0]
	check(actor_for_chat.bubble_text.length() > 0 or actor_for_chat.body.dead, "chat appears as a speech bubble")
	campaign.handle_chat("chatter", "chatter", "!retreat")
	check(actor_for_chat.gone, "!retreat teleports the crewmember out")
	campaign.listen_to_chat = false
	scene.deposited.fuel += 5.0
	scene.end_expedition("extracted")
	var fuel_before: float = campaign.stores.fuel
	campaign.finish_expedition({"fuel": 5.0, "completed": true})
	check(campaign.stores.fuel > fuel_before, "recovered fuel reaches the tanks")
	check(site.expedition_done, "the planet's expedition is done")
	scene.queue_free()
	await process_frame


func _test_boarding() -> void:
	var campaign := _campaign()
	campaign.new_game(31)
	campaign.finish_expedition({"crew_rescued": 8})
	campaign.pending_expedition = {"site": campaign.star_map.current, "boarding": true, "boarders": 3, "members": []}
	campaign.set_phase(campaign.Phase.EXPEDITION)
	var scene := await _start_scene()
	check(scene.mode == Expedition.Mode.BOARDING, "boarding action runs in the expedition scene")
	check(scene.enemies_left() == 3, "boarders spawn at the airlock")
	await _run(120.0, scene)
	for actor: ExpeditionActor in scene.actors:
		print("    %s pos=%s target=%s state=%s path=%d fleeing=%s %s" % [actor.display_name, actor.global_position.round(),
			actor.target.display_name if actor.target else "-", actor.state, actor.path.size(), actor.fleeing, actor.body.get_status_name()])
	print("  boarding: over=%s outcome=%s boarders left %d" % [scene.is_over, scene.outcome, scene.enemies_left()])
	check(scene.is_over or scene.enemies_left() < 3, "the crew fights the boarders")
	scene.queue_free()
	await process_frame
