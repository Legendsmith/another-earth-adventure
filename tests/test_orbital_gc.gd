extends SceneTree
## Regression test: rebuilding the ephemeris used to orphan C#-created collision shapes, which the .NET GC then freed
## off the main thread, crashing Rapier. Rebuilds many times across scene reloads; any panic in the log is a failure.
## Run: godot --headless --path . --script res://tests/test_orbital_gc.gd
func _initialize() -> void:
	await process_frame
	var campaign: Node = root.get_node("Campaign")
	campaign.listen_to_chat = false
	campaign.auto_scene_changes = false
	campaign.new_game(4242)
	campaign.finish_expedition({"crew_rescued": 8})
	for round in 3:
		var scene: Node = load("res://ui/ship_console/ship_hud.tscn").instantiate()
		root.add_child(scene)
		current_scene = scene
		for f in 30: await physics_frame
		var system: Node = get_first_node_in_group(Constants.ORBITAL_SYSTEM_GROUP)
		for i in 300:
			system.RebuildEphemeris()
			if i % 10 == 0: await physics_frame
		scene.queue_free()
		for f in 120: await physics_frame
		print("round ", round, " done")
	print("gc stress done")
	quit()
