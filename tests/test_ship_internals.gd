extends SceneTree
## Headless checks for the ship internals. Run: godot --headless --path . --script res://tests/test_ship_internals.gd

var _failures := 0


func _initialize() -> void:
	await process_frame
	_test_armor_surface()
	_test_layout()
	_test_railgun_bores_through()
	_test_repairs()
	_test_fuel_tank()
	_test_thrusters()
	_test_layout_editing()
	_test_breakup_is_hard()
	print("ship internals: %s" % ("OK" if _failures == 0 else "%d FAILED" % _failures))
	quit(1 if _failures else 0)


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures += 1
		push_error("FAIL: " + message)


func _make_internals() -> ShipInternals:
	var internals := ShipInternals.new()
	root.add_child(internals)
	internals.rng.seed = 1234
	return internals


func _find_module(internals: ShipInternals, module_name: String) -> int:
	for i in internals.layout.modules.size():
		if internals.get_module(i).name == module_name:
			return i
	return -1


func _test_fuel_tank() -> void:
	var internals := _make_internals()
	var tank := _find_module(internals, "Fuel Tank")
	_check(internals.is_fuel_tank(tank), "the default layout has a fuel tank")
	internals.damage_module(tank, 50)
	_check(internals.is_module_operational(tank), "a fuel tank cannot be knocked out")
	_check(is_equal_approx(internals.fuel_lost, 50 * internals.fuel_loss_per_hit), "hits on the tank lose fuel")
	_check(_find_module(internals, "Thrusters") < 0, "thrusters have no module")
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
	_check(low_drop > high_drop * 2.0, "thrust falls off faster near the critical level (%.2f vs %.2f)" % [low_drop,
		high_drop])
	print("  thrusters at frame 50/40/30/20/10%%: %s" % [[0.5, 0.4, 0.3, 0.2, 0.1].map(func(f: float) -> String:
		return "%d%%" % roundi(at.call(f) * 100.0))])
	internals.free()


func _test_layout_editing() -> void:
	var internals := _make_internals()
	var layout := ShipLayout.create_default()
	var walls := layout.get_wall_cells()
	walls.erase(Vector2i(10, 4))
	layout.set_wall_cells(walls)
	_check(layout.get_wall_cells().size() == walls.size(), "wall cells survive the round trip to rectangles")
	_check(layout.walls.size() < walls.size(), "walls are stored as runs")
	internals.resolve_hit(64, ArmorGrid.DamageProfile.KINETIC, Vector2.DOWN)
	internals.set_layout(layout)
	_check(internals.breaches.is_empty() and internals.get_frame_integrity() == 1.0, "a new layout clears the damage")
	_check(internals.get_cell(Vector2i(10, 4)) == ShipInternals.Cell.DECK, "the new layout is used")
	internals.free()


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
	_check(internals.get_cell(Vector2i(0, 5)) == ShipInternals.Cell.HULL, "the border is hull")
	_check(internals.get_cell(Vector2i(8, 5)) == ShipInternals.Cell.DOOR, "bulkheads have corridor doors")
	_check(internals.find_path(Vector2i(2, 5), Vector2i(37, 6)).size() > 30, "the corridor runs stern to bow")
	for i in internals.layout.modules.size():
		var access := internals.get_access_cells(i)
		_check(not access.is_empty(), "%s can be reached" % internals.get_module(i).name)
		_check(not access.is_empty() and internals.find_path(Vector2i(20, 5), access[0]).size() > 0,
			"crew can walk to %s" % internals.get_module(i).name)
	_check(internals.armor.width == 40 and internals.armor.height == 38, "armor image is length x circumference")
	internals.free()


func _test_railgun_bores_through() -> void:
	var internals := _make_internals()
	var tracks: Array = []
	internals.round_tracked.connect(func(from: Vector2, to: Vector2) -> void: tracks.append([from, to]))
	var hits := 0
	for i in 40:
		# Broadside slugs across the hull.
		if internals.resolve_hit(64, ArmorGrid.DamageProfile.KINETIC, Vector2.DOWN) > 0:
			hits += 1
	_check(hits > 0, "slugs get through the armor")
	_check(tracks.size() == hits, "every penetrating slug leaves a track")
	var space := internals.get_hull_breach_count()
	var walls := internals.breaches.size() - space
	print("  broadside: %d penetrating, %d holes to space, %d wall holes, armor %d%%, frame %d%%" % [hits, space, walls,
		roundi(internals.armor.get_integrity() * 100.0), roundi(internals.get_frame_integrity() * 100.0)])
	_check(space >= hits, "each penetrating slug holes the hull where it enters")
	_check(walls > 0, "slugs hole the internal walls they cross")
	var damaged := 0
	for i in internals.layout.modules.size():
		if internals.module_damage[i] > 0:
			damaged += 1
	_check(damaged > 0, "modules on the slugs' paths are damaged")
	_check(internals.armor.get_hole_count() > 0, "the armor image shows holes")
	internals.free()


func _test_repairs() -> void:
	var internals := _make_internals()
	var reactor := _find_module(internals, "Reactor")
	internals.damage_module(reactor, 5)
	_check(not internals.is_module_operational(reactor), "a wrecked module is offline")
	_check(internals.repair_module(reactor), "a damaged module can be repaired")
	_check(internals.repair_module(reactor) and internals.is_module_operational(reactor), "repairs bring it back")
	_check(not internals.repair_module(reactor), "an undamaged module needs no repair")
	internals.resolve_hit(64, ArmorGrid.DamageProfile.KINETIC, Vector2.DOWN)
	internals.resolve_hit(64, ArmorGrid.DamageProfile.KINETIC, Vector2.DOWN)
	var cells := internals.breaches.keys()
	for cell in cells:
		_check(internals.patch_breach(cell), "holes can be patched")
	_check(internals.breaches.is_empty(), "patched holes are gone")
	_check(not internals.patch_breach(Vector2i(3, 3)), "nothing to patch on sound deck")
	internals.free()


func _test_breakup_is_hard() -> void:
	# A CombatHull with internals: torpedo and railgun hits until it breaks up.
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
	var reactor := hull.find_component("Reactor")
	var hits := 0
	var thrust_gone := -1
	while not hull.is_destroyed and hits < 20000:
		if thrust_gone < 0 and internals.get_thruster_performance() == 0.0:
			thrust_gone = hits
		hull.take_hit(2, ArmorGrid.DamageProfile.KINETIC, Vector2.from_angle(randf() * TAU))
		hits += 1
	print("  hull with %d-deep armor: thrusters dead after %d fragment hits, broke up after %d; reactor %s" % [
		internals.armor.thickness, thrust_gone, hits, "up" if hull.is_component_operational(reactor) else "down"])
	_check(hits > 200, "a ship takes many hits before it breaks up (%d)" % hits)
	_check(hull.is_destroyed, "it does break up in the end")
	host.free()
