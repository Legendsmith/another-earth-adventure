extends Control
## The end of a run: home to Earth, or lost (Development Overview, Win and Lose Conditions).


func _ready() -> void:
	var campaign: Node = get_node_or_null("/root/Campaign")
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = Color(0.02, 0.03, 0.06)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var box := VBoxContainer.new()
	box.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	box.custom_minimum_size = Vector2(700, 0)
	box.position -= Vector2(350, 200)
	box.add_theme_constant_override("separation", 16)
	add_child(box)
	var victory: bool = campaign != null and campaign.phase == campaign.Phase.VICTORY
	var title := Label.new()
	title.text = "HOME TO EARTH" if victory else "THE VOYAGE ENDS"
	title.add_theme_font_size_override("font_size", 48)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.modulate = Color(0.6, 1.0, 0.7) if victory else Color(1.0, 0.5, 0.4)
	box.add_child(title)
	var reason := Label.new()
	reason.text = campaign.game_over_reason if campaign else ""
	reason.autowrap_mode = TextServer.AUTOWRAP_WORD
	reason.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(reason)
	if campaign:
		var stats := Label.new()
		var dead := 0
		for record: CrewRecord in campaign.crew:
			if not record.is_alive():
				dead += 1
		var visited := 0
		for site: PlanetSite in campaign.star_map.sites:
			if site.visited:
				visited += 1
		stats.text = "Crew aboard: %d   Lost: %d   Systems visited: %d   Orbital time: %s" % [campaign.rescued_crew_count(),
			dead, visited, ShipHud.format_time(campaign.orbital_time)]
		stats.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		box.add_child(stats)
	var button := Button.new()
	button.text = "Main menu"
	button.pressed.connect(func() -> void:
		if campaign:
			campaign.active = false
			campaign.change_scene(campaign.SCENE_TITLE)
		else:
			get_tree().quit())
	box.add_child(button)
