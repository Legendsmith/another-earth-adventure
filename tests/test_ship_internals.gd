extends SceneTree
## Headless checks for the ship internals. Run: godot --headless --path . --script res://tests/test_ship_internals.gd
## The last check times 200 crew (CPU per physics frame, Linux only); change that with `-- --crew-perf=N`, 0 to skip.

var _failures := 0


func _initialize() -> void:
	await process_frame
	_test_armor_surface()
	_test_layout()
	_test_decks_and_elevators()
	_test_railgun_bores_through()
	_test_penetrator_spends_points()
	_test_split_main_engine()
	_test_repairs()
	_test_fuel_tank()
	_test_thrusters()
	_test_layout_editing()
	_test_breakup_is_hard()
	await _test_editor()
	await _test_crew()
	await _test_spacing()
	await _test_crew_performance(_crew_perf_count())
	print("ship internals: %s" % ("OK" if _failures == 0 else "%d FAILED" % _failures))
	quit(1 if _failures else 0)


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures += 1
		push_error("FAIL: " + message)


func _make_internals(layout: ShipLayout = null) -> ShipInternals:
	var internals := ShipInternals.new()
	internals.layout = layout
	root.add_child(internals)
	internals.rng.seed = 1234
	return internals


func _find_module(internals: ShipInternals, module_name: String, nth: int = 0) -> int:
	for i in internals.get_module_count():
		if internals.get_module(i).name == module_name:
			if nth == 0:
				return i
			nth -= 1
	return -1


func _test_armor_surface() -> void:
	var surface := HullArmorSurface.new(10, 8, 4)
	_check(surface.get_integrity() == 1.0, "fresh armor is intact")
	_check(surface.image.get_pixel(3, 3).v > 0.99, "intact armor is white")
	var through := surface.apply_crater(5, 0, 2, ArmorGrid.DamageProfile.KINETIC)
	_check(through == 0, "a 2-point fragment is stopped by 4-deep armor (got %d)" % through)
	_check(surface.get_remaining(5, 0) == 2, "a small fragment digs one column")
	_check(surface.get_remaining(5, 8) == 2, "y wraps round the hull")
	through = surface.apply_crater(5, 0, 20, ArmorGrid.DamageProfile.KINETIC)
	_check(through > 0 and surface.is_holed(5, 0), "a heavy slug holes the column")
	_check(surface.get_remaining(5, 2) == 4, "a kinetic pit is narrow")
	var before := surface.get_integrity()
	through = surface.apply_crater(2, 4, 16, ArmorGrid.DamageProfile.EXPLOSIVE)
	_check(through == 0 and surface.get_remaining(2, 4) == 2, "an explosive crater is shallow")
	_check(is_equal_approx((before - surface.get_integrity()) * 10 * 8 * 4, 16.0), "every point of damage is spent")
	_check(surface.image.get_pixel(5, 0).v < 0.01, "a hole is black")
	_check(surface.image.get_pixel(5, 1).v < 0.99, "a pit is grey")


func _test_layout() -> void:
	var internals := _make_internals()
	_check(internals.get_cell(Vector3i(0, 5, 0)) == ShipInternals.Cell.HULL, "the border is hull")
	_check(internals.get_cell(Vector3i(8, 5, 0)) == ShipInternals.Cell.DOOR, "bulkheads have corridor doors")
	_check(internals.find_path(Vector3i(2, 6, 0), Vector3i(37, 5, 0)).size() > 30, "the corridor runs stern to bow")
	for i in internals.get_module_count():
		var access := internals.get_access_cells(i)
		_check(not access.is_empty(), "%s can be reached" % internals.get_module(i).name)
		_check(not access.is_empty() and internals.find_path(Vector3i(20, 5, 0), access[0]).size() > 0,
			"crew can walk to %s" % internals.get_module(i).name)
	_check(internals.armor.width == 40 and internals.armor.height == 38, "armor image is length x circumference")
	_check(_find_module(internals, "Thrusters") < 0, "thrusters have no module")
	internals.free()


func _test_decks_and_elevators() -> void:
	var internals := _make_internals()
	_check(internals.decks == 2, "the default ship has two decks")
	_check(internals.get_cell(Vector3i(3, 5, 0)) == ShipInternals.Cell.ELEVATOR
		and internals.get_cell(Vector3i(3, 5, 1)) == ShipInternals.Cell.ELEVATOR, "elevators link the decks")
	var path := internals.find_path(Vector3i(20, 5, 0), Vector3i(20, 9, 1))
	_check(not path.is_empty() and path[0].z == 0 and path[-1].z == 1, "paths ride elevators between decks")
	var rides := 0
	for i in range(1, path.size()):
		if path[i].z != path[i - 1].z:
			rides += 1
			_check(internals.get_cell(path[i]) == ShipInternals.Cell.ELEVATOR, "decks change only on elevators")
	_check(rides == 1, "one elevator ride from deck to deck")
	_check(internals.get_zone_cells(ShipRoom.Zone.CARGO).size() > 50, "the lower deck has cargo holds")
	# A round straight down through the ship holes the floor between the decks.
	internals.rng.seed = 5
	var floors: Array[Vector3i] = []
	internals.breach_opened.connect(func(cell: Vector3i, kind: ShipInternals.BreachKind) -> void:
		if kind == ShipInternals.BreachKind.FLOOR:
			floors.append(cell))
	for i in 30:
		internals._trace_round(Vector3(10.5 + i * 0.5, 1.0, 5.9), Vector3(10.5 + i * 0.5, 1.0, -5.9), 99)
	_check(floors.size() > 0, "rounds between decks hole the floor")
	_check(floors.all(func(cell: Vector3i) -> bool: return cell.z == 1), "floor holes belong to the lower deck")
	internals.free()


func _test_railgun_bores_through() -> void:
	var internals := _make_internals()
	var tracks: Array = []
	internals.round_tracked.connect(func(deck: int, from: Vector2, to: Vector2) -> void: tracks.append([deck, from, to]))
	var hits := 0
	for i in 40:
		# Broadside slugs across the hull.
		if internals.resolve_hit(64, ArmorGrid.DamageProfile.KINETIC, Vector2.DOWN) > 0:
			hits += 1
	_check(hits > 0, "slugs get through the armor")
	_check(tracks.size() >= hits, "every penetrating slug leaves a track")
	var space := internals.get_hull_breach_count()
	var inside := internals.breaches.size() - space
	print("  broadside: %d penetrating, %d holes to space, %d inside, armor %d%%, frame %d%%" % [hits, space, inside,
		roundi(internals.armor.get_integrity() * 100.0), roundi(internals.get_frame_integrity() * 100.0)])
	_check(space >= hits, "each penetrating slug holes the hull where it enters")
	_check(inside > 0, "slugs hole the internal walls they cross")
	var damaged := 0
	for i in internals.get_module_count():
		if internals.module_damage[i] > 0:
			damaged += 1
	_check(damaged > 0, "modules on the slugs' paths are damaged")
	_check(internals.armor.get_hole_count() > 0, "the armor image shows holes")
	internals.free()


func _test_penetrator_spends_points() -> void:
	var internals := _make_internals()
	var railgun := _find_module(internals, "Railgun")
	var rect := internals.get_module(railgun).rect
	# Straight along the railgun's row (5 cells long) on the main deck, z inside the top deck: every cell is a hit.
	var row := rect.position.y + 0.5 - internals.radius
	internals._trace_round(Vector3(rect.position.x - 0.5, row, 3.0), Vector3(rect.end.x + 0.5, row, 3.0), 99)
	_check(internals.module_damage[railgun] == rect.size.x, "a round along a module hits every cell (%d of %d)" % [
		internals.module_damage[railgun], rect.size.x])
	# A round that only clips a corner hits once.
	var reactor := _find_module(internals, "Reactor")
	var corner := internals.get_module(reactor).rect.position
	internals._trace_round(Vector3(corner.x + 0.5, corner.y + 0.5 - internals.radius, 5.9),
		Vector3(corner.x + 0.5, corner.y + 0.5 - internals.radius, 3.1), 99)
	_check(internals.module_damage[reactor] == 1, "a round clipping a module hits it once")
	# Walls spend points too: three points cross the corridor wall and stop in the first module cell after it.
	internals.set_layout(internals.layout)
	var stops: Array[Vector2] = []
	internals.round_tracked.connect(func(_deck: int, _from: Vector2, to: Vector2) -> void: stops.append(to))
	internals._trace_round(Vector3(19.5, 6.5 - internals.radius, 3.0), Vector3(19.5, 0.0 - internals.radius, 3.0), 3)
	_check(internals.is_breached(Vector3i(19, 4, 0)), "the corridor wall is holed")
	_check(internals.module_damage[_find_module(internals, "Torpedo Magazine")] == 2,
		"the wall takes a point, the rest goes into the module")
	_check(stops.size() == 1 and stops[0].y > 0.5, "the round stops inside the ship")
	internals.free()


func _test_split_main_engine() -> void:
	var internals := _make_internals()
	var first := _find_module(internals, "Main Engine")
	var second := _find_module(internals, "Main Engine", 1)
	_check(first >= 0 and second >= 0 and internals.get_module_deck(first) != internals.get_module_deck(second),
		"the main drive is an engine module on each deck")
	_check(internals.get_main_engine_performance() == 1.0, "both engines give full thrust")
	internals.damage_module(first, 999)
	_check(is_equal_approx(internals.get_main_engine_performance(), 0.5), "one engine down halves the main drive")
	internals.damage_module(second, 999)
	_check(internals.get_main_engine_performance() == 0.0, "both down stop it")
	internals.repair_module(first, 999)
	_check(is_equal_approx(internals.get_main_engine_performance(), 0.5), "repairs bring a share back")
	internals.free()


func _test_repairs() -> void:
	var internals := _make_internals()
	var reactor := _find_module(internals, "Reactor")
	internals.damage_module(reactor, 999)
	_check(not internals.is_module_operational(reactor), "a wrecked module is offline")
	_check(internals.get_module_hit_points(reactor) >= 10, "modules take many hits")
	_check(internals.repair_module(reactor), "a damaged module can be repaired")
	_check(internals.is_module_operational(reactor), "one repair brings it back online")
	_check(internals.repair_module(reactor, 999) and not internals.repair_module(reactor), "repairs finish")
	internals.resolve_hit(64, ArmorGrid.DamageProfile.KINETIC, Vector2.DOWN)
	internals.resolve_hit(64, ArmorGrid.DamageProfile.KINETIC, Vector2.DOWN)
	for cell in internals.breaches.keys():
		_check(internals.patch_breach(cell), "holes can be patched")
	_check(internals.breaches.is_empty(), "patched holes are gone")
	_check(not internals.patch_breach(Vector3i(3, 3, 0)), "nothing to patch on sound deck")
	internals.free()


func _test_fuel_tank() -> void:
	var internals := _make_internals()
	var tank := _find_module(internals, "Fuel Tank")
	_check(internals.is_fuel_tank(tank), "the default layout has a fuel tank")
	internals.damage_module(tank, 50)
	_check(internals.is_module_operational(tank), "a fuel tank cannot be knocked out")
	_check(is_equal_approx(internals.fuel_lost, 50 * internals.fuel_loss_per_hit), "hits on the tank lose fuel")
	internals.free()


func _test_thrusters() -> void:
	var internals := _make_internals()
	var at := func(integrity: float) -> float:
		var t := inverse_lerp(internals.thruster_dead_integrity, internals.thruster_full_integrity, integrity)
		return ease(clampf(t, 0.0, 1.0), internals.thruster_ease)
	_check(internals.get_thruster_performance() == 1.0, "an undamaged frame gives full thrust")
	_check(at.call(0.6) == 1.0 and at.call(0.5) == 1.0, "full thrust down to half the frame")
	_check(at.call(0.1) == 0.0 and at.call(0.05) == 0.0, "no thrust at a tenth of the frame")
	var high_drop: float = at.call(0.5) - at.call(0.4)
	var low_drop: float = at.call(0.2) - at.call(0.1)
	_check(low_drop > high_drop * 2.0, "thrust falls off faster near the critical level")
	internals.free()


func _test_layout_editing() -> void:
	var internals := _make_internals()
	var layout := ShipLayout.create_default()
	var walls := layout.get_deck(0).get_wall_cells()
	walls.erase(Vector2i(10, 4))
	layout.get_deck(0).set_wall_cells(walls)
	_check(layout.get_deck(0).get_wall_cells().size() == walls.size(), "wall cells survive the round trip")
	_check(layout.get_deck(0).walls.size() < walls.size(), "walls are stored as runs")
	internals.resolve_hit(64, ArmorGrid.DamageProfile.KINETIC, Vector2.DOWN)
	internals.set_layout(layout)
	_check(internals.breaches.is_empty() and internals.get_frame_integrity() == 1.0, "a new layout clears the damage")
	_check(internals.get_cell(Vector3i(10, 4, 0)) == ShipInternals.Cell.DECK, "the new layout is used")
	internals.free()


func _test_breakup_is_hard() -> void:
	# A CombatHull with internals: railgun fragments until it breaks up.
	var host := Node2D.new()
	var hull := CombatHull.new()
	hull.armor = load("res://data/armor/ceramic_laminate.tres")
	hull.armor_mass = 3.0
	hull.armor_columns = 16
	for path in ["bridge", "reactor", "main_engine", "railgun", "torpedo_magazine", "sensors"]:
		hull.components.append(load("res://data/components/%s.tres" % path))
	hull.free_on_destroyed = false
	var internals := ShipInternals.new()
	hull.add_child(internals)
	host.add_child(hull)
	root.add_child(host)
	_check(hull.internals == internals, "internals attach to their hull")
	var engine := hull.find_component("Main Engine")
	internals.damage_module(_find_module(internals, "Main Engine"), 999)
	_check(hull.is_component_operational(engine), "the main drive stays online while an engine module works")
	internals.damage_module(_find_module(internals, "Main Engine", 1), 999)
	_check(not hull.is_component_operational(engine), "and goes offline with the last one")
	var hits := 0
	var thrust_gone := -1
	while not hull.is_destroyed and hits < 40000:
		if thrust_gone < 0 and internals.get_thruster_performance() == 0.0:
			thrust_gone = hits
		hull.take_hit(2, ArmorGrid.DamageProfile.KINETIC, Vector2.from_angle(randf() * TAU))
		hits += 1
	print("  hull with %d-deep armor: thrusters dead after %d fragment hits, broke up after %d" % [
		internals.armor.thickness, thrust_gone, hits])
	_check(hits > 200, "a ship takes many hits before it breaks up (%d)" % hits)
	_check(hull.is_destroyed, "it does break up in the end")
	host.free()


func _test_editor() -> void:
	var editor: ShipLayoutEditor = load("res://ui/ship_internals/ship_layout_editor.tscn").instantiate()
	root.add_child(editor)
	await process_frame
	var internals := editor._view.internals
	_check(internals.decks == editor.layout.get_deck_count(), "the editor previews its layout")
	# Paint a wall across the mess and put a door in it.
	editor._set_tool(ShipLayoutEditor.Tool.WALL)
	editor._on_press(Vector2i(28, 8), false)
	for y in range(9, 11):
		editor._on_drag_to(Vector2i(28, y))
	editor._on_release(Vector2i(28, 10))
	_check(internals.get_cell(Vector3i(28, 10, 0)) == ShipInternals.Cell.WALL, "walls can be painted")
	editor._set_tool(ShipLayoutEditor.Tool.DOOR)
	editor._on_press(Vector2i(28, 9), false)
	_check(internals.get_cell(Vector3i(28, 9, 0)) == ShipInternals.Cell.DOOR, "doors go in walls")
	# A module in the crew quarters, and one that would overlap it.
	editor._set_tool(ShipLayoutEditor.Tool.MODULE)
	editor._on_preset_selected(editor._presets.find_custom(func(c: ShipComponent) -> bool:
		return c.name == "Reactor") + 1)
	var count := editor._deck().modules.size()
	editor._on_press(Vector2i(26, 1), false)
	editor._on_release(Vector2i(27, 2))
	_check(editor._deck().modules.size() == count + 1, "modules can be placed")
	_check(editor._deck().modules[-1].hit_points >= 10, "presets give modules many hit points")
	_check(internals.get_module_at(Vector3i(27, 2, 0)) != ShipInternals.NO_MODULE, "placed modules are live")
	editor._on_press(Vector2i(27, 2), false)
	editor._on_release(Vector2i(29, 3))
	_check(editor._deck().modules.size() == count + 1, "modules cannot overlap")
	# A cargo zone, then undo it.
	editor._set_tool(ShipLayoutEditor.Tool.ZONE)
	editor._zone_type.select(ShipRoom.Zone.CARGO)
	var rooms := editor._deck().rooms.size()
	editor._on_press(Vector2i(29, 9), false)
	editor._on_release(Vector2i(31, 10))
	_check(editor._deck().rooms.size() == rooms + 1 and editor._deck().rooms[-1].zone == ShipRoom.Zone.CARGO,
		"zones can be marked")
	editor.undo()
	_check(editor._deck().rooms.size() == rooms, "undo removes it")
	# Move the new module with Select.
	editor._set_tool(ShipLayoutEditor.Tool.SELECT)
	editor._on_press(Vector2i(26, 1), false)
	editor._on_drag_to(Vector2i(29, 1))
	editor._on_release(Vector2i(29, 1))
	_check(editor._deck().modules[-1].rect.position == Vector2i(29, 1), "modules can be dragged")
	# A third deck linked to the second by an elevator.
	editor.select_deck(1)
	editor.add_deck()
	_check(editor.layout.get_deck_count() == 3 and editor.deck_index == 2, "decks can be added")
	editor._set_tool(ShipLayoutEditor.Tool.ELEVATOR)
	editor._on_press(Vector2i(3, 5), false)
	_check(internals.get_cell(Vector3i(3, 5, 2)) == ShipInternals.Cell.ELEVATOR, "elevators can be placed")
	_check(not internals.find_path(Vector3i(20, 5, 0), Vector3i(10, 3, 2)).is_empty(), "the new deck is reachable")
	_check(editor.save_layout("user://test_layout.tres") == OK, "layouts save")
	editor._new_layout(true)
	_check(editor.layout.get_deck_count() == 1 and editor._deck().modules.is_empty(), "an empty hull is empty")
	editor.load_layout("user://test_layout.tres")
	_check(editor.layout.get_deck_count() == 3 and editor._deck().get_wall_cells().has(Vector2i(28, 10)),
		"layouts load back")
	editor.remove_deck()
	_check(editor.layout.get_deck_count() == 2, "decks can be removed")
	editor.queue_free()


## A view with a crew, on the default ship.
func _make_crew() -> ShipCrew:
	var view := ShipInternalsView.new()
	root.add_child(view)
	var crew := ShipCrew.new()
	crew.follow_roster = false
	view.add_child(crew)
	await process_frame
	view.internals.rng.seed = 99
	crew.rng.seed = 99
	return crew


func _member(id: String) -> CrewMember:
	var member := CrewMember.new()
	member.user_id = id
	member.login = id
	member.display_name = id.capitalize()
	return member


func _wait_physics(frames: int) -> void:
	for i in frames:
		await physics_frame


func _test_crew() -> void:
	var crew := await _make_crew()
	var internals := crew.internals
	crew.auto_jobs = false
	var walker := crew.add_crew(_member("walker"), Vector3i(20, 5, 0))
	_check(walker is RigidBody2D and walker.member.user_id == "walker", "crew are rigid bodies tied to a member")
	_check(walker.get_children().any(func(child: Node) -> bool: return child is Sprite2D), "crew have a sprite")
	_check(walker.walk_to(Vector3i(20, 9, 1)), "crew can path to the lower deck")
	await _wait_physics(900)
	_check(walker.deck == 1, "the walker rode the elevator down (deck %d)" % walker.deck)
	_check(walker.get_cell() == Vector3i(20, 9, 1) and walker.state == CrewBody.State.IDLE,
		"and arrived (at %s)" % walker.get_cell())
	_check(not walker.visible, "crew on another deck are hidden")
	crew.view.show_deck(1)
	_check(walker.visible, "and shown with their deck")
	# A repair job: the crew fixes the bridge on its own.
	crew.auto_jobs = true
	var bridge := _find_module(internals, "Bridge")
	internals.damage_module(bridge, 4)
	await _wait_physics(900)
	_check(internals.module_damage[bridge] == 0, "crew repair damaged modules (%d left)" % internals.module_damage[bridge])
	var hole := Vector3i(30, 2, 0)
	internals._open_breach(hole, ShipInternals.BreachKind.DECK)
	walker.stop()
	walker.set_deck(1)
	await _wait_physics(1200)
	_check(not internals.is_breached(hole), "crew patch holes")
	crew.view.queue_free()


func _test_spacing() -> void:
	var crew := await _make_crew()
	var internals := crew.internals
	crew.auto_jobs = false
	crew.spacing_chance = 1.0
	crew.spaced_survival_time = 0.5
	var near := crew.add_crew(_member("near"), Vector3i(30, 2, 0))
	var far := crew.add_crew(_member("far"), Vector3i(10, 9, 0))
	var below := crew.add_crew(_member("below"), Vector3i(30, 2, 1))
	var spaced: Array = []
	var dead: Array = []
	crew.crew_spaced.connect(func(_body: CrewBody, drifter: SpacedCrew) -> void: spaced.append(drifter))
	crew.crew_died.connect(func(member: CrewMember) -> void: dead.append(member))
	await _wait_physics(2)
	internals._open_breach(Vector3i(30, 1, 0), ShipInternals.BreachKind.DECK)
	_check(spaced.size() == 1 and spaced[0].member.user_id == "near", "crew next to a new hole are sucked out")
	_check(far in crew.bodies and below in crew.bodies, "crew far away or on another deck stay aboard")
	_check(not near in crew.bodies, "the spaced crew member left the deck")
	internals._open_breach(Vector3i(31, 2, 1), ShipInternals.BreachKind.WALL)
	_check(below in crew.bodies, "holes inside the ship don't space anyone")
	await _wait_physics(60)
	_check(dead.size() == 1, "a spaced crew member dies when the suit runs out")
	crew.spaced_survival_time = -1.0
	internals._open_breach(Vector3i(11, 10, 0), ShipInternals.BreachKind.HULL)
	await _wait_physics(120)
	_check(spaced.size() == 2 and dead.size() == 1 and is_instance_valid(spaced[1]) and spaced[1].time_left == INF,
		"with -1 survival time a spaced crew member lives on")
	crew.sync_roster()
	_check(crew.find_body(spaced[1].member) == null, "spaced crew don't reappear aboard")
	crew.view.queue_free()


func _crew_perf_count() -> int:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--crew-perf="):
			return int(arg.get_slice("=", 1))
	return 200


## CPU time (ms) this process has used, from /proc (Linux only; -1 elsewhere).
func _cpu_ms() -> float:
	var file := FileAccess.open("/proc/self/stat", FileAccess.READ)
	if file == null:
		return -1.0
	var stat := file.get_line()
	var fields := stat.get_slice(")", 1).split(" ", false)
	# utime and stime are fields 14 and 15 of the stat line, 12 and 13 after the command name.
	return (int(fields[11]) + int(fields[12])) * 10.0


## Times `count` crew on the default ship after a battering: CPU per physics frame, less the same ship with no crew.
func _test_crew_performance(count: int) -> void:
	if count <= 0:
		return
	var empty := await _crew_frame_cost(0, false)
	var working := await _crew_frame_cost(count, false)
	var walking := await _crew_frame_cost(count, true)
	if empty.cpu >= 0.0:
		print("  %d crew: %.2f ms of CPU per physics frame repairing (%d took jobs), %.2f ms all walking (%.2f ms for the"
			% [count, working.cpu - empty.cpu, working.busy, walking.cpu - empty.cpu, empty.cpu]
			+ " ship with no crew)")


## CPU per physics frame of the default ship after a battering with `count` crew aboard, taking jobs or, with `walk`,
## all walking to random places on both decks the whole time.
func _crew_frame_cost(count: int, walk: bool) -> Dictionary:
	var crew := await _make_crew()
	var internals := crew.internals
	var cells := internals.get_walkable_cells()
	# Damage first so there is work, then bring everyone aboard.
	for i in 20:
		internals.resolve_hit(64, ArmorGrid.DamageProfile.KINETIC)
	for i in count:
		crew.add_crew(_member("perf_%d" % i), cells[crew.rng.randi_range(0, cells.size() - 1)])
	crew.auto_jobs = not walk
	var busy := {}
	var frames := 300
	var start := _cpu_ms()
	for i in frames:
		await physics_frame
		if walk:
			for body in crew.bodies:
				if body.state == CrewBody.State.IDLE:
					body.walk_to(cells[crew.rng.randi_range(0, cells.size() - 1)])
		elif i % 10 == 0:
			for body in crew.bodies:
				if body.state != CrewBody.State.IDLE:
					busy[body] = true
	var cpu := (_cpu_ms() - start) / frames if start >= 0.0 else -1.0
	_check(crew.bodies.size() == count, "every crew member is aboard")
	crew.view.queue_free()
	await process_frame
	return {"cpu": cpu, "busy": busy.size()}
