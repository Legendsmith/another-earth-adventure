extends Control
## The FTL navigation screen (Development Overview, FTL Map): every known system with its planet type, a few details
## about the locality (moons, debris fields) and the fuel cost to get there. Jumping costs fuel scaled by the ship's
## mass. Once enough fuel and crew are aboard, the long range jump home to Earth is possible.

const KIND_COLORS := {
	PlanetType.Kind.URBAN: Color(0.7, 0.7, 0.75), PlanetType.Kind.AQUATIC: Color(0.3, 0.55, 0.95),
	PlanetType.Kind.LAVA: Color(1.0, 0.45, 0.15), PlanetType.Kind.FROZEN: Color(0.8, 0.9, 1.0),
	PlanetType.Kind.JUNGLE: Color(0.3, 0.8, 0.35), PlanetType.Kind.WASTELAND: Color(0.85, 0.7, 0.45),
	PlanetType.Kind.TOXIC: Color(0.7, 0.85, 0.25), PlanetType.Kind.MYSTERY: Color(0.7, 0.4, 1.0),
}

var campaign: Node
var selected: int = -1
var hovered: int = -1

var _map_rect := Rect2()
var _info: RichTextLabel
var _jump_button: Button
var _home_button: Button
var _status: Label


func _ready() -> void:
	campaign = get_node_or_null("/root/Campaign")
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	if campaign and not campaign.active:
		campaign.new_game()
		campaign.finish_expedition({"crew_rescued": 6})
		campaign.reach_ftl_limit()
	var side := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.05, 0.07, 0.12, 0.95)
	style.set_content_margin_all(14)
	side.add_theme_stylebox_override("panel", style)
	side.set_anchors_and_offsets_preset(Control.PRESET_RIGHT_WIDE)
	side.offset_left = -440
	add_child(side)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	side.add_child(box)
	var title := Label.new()
	title.text = "FTL NAVIGATION"
	title.add_theme_font_size_override("font_size", 24)
	box.add_child(title)
	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD
	box.add_child(_status)
	_info = RichTextLabel.new()
	_info.bbcode_enabled = true
	_info.fit_content = true
	_info.custom_minimum_size = Vector2(400, 300)
	box.add_child(_info)
	_jump_button = Button.new()
	_jump_button.text = "Jump"
	_jump_button.pressed.connect(_on_jump)
	box.add_child(_jump_button)
	var back := Button.new()
	back.text = "Return to orbit of current planet"
	back.pressed.connect(func() -> void:
		campaign.orbit_stage = campaign.OrbitStage.FTL_LIMIT
		campaign.set_phase(campaign.Phase.ORBIT)
		campaign.go_to_phase_scene())
	box.add_child(back)
	_home_button = Button.new()
	_home_button.text = "Charge the long range jump to Earth"
	_home_button.pressed.connect(_on_home)
	box.add_child(_home_button)
	var save := Button.new()
	save.text = "Save and quit to title"
	save.pressed.connect(func() -> void:
		campaign.autosave()
		campaign.change_scene(campaign.SCENE_TITLE))
	box.add_child(save)
	var help := Label.new()
	help.text = "Click a system to see it. Lines show systems within FTL range; the cost grows with distance and with the mass of everything in the holds."
	help.autowrap_mode = TextServer.AUTOWRAP_WORD
	help.modulate = Color(1, 1, 1, 0.6)
	box.add_child(help)
	_refresh()


func _map_to_screen(point: Vector2) -> Vector2:
	var _scale := minf(_map_rect.size.x / StarMap.MAP_SIZE.x, _map_rect.size.y / StarMap.MAP_SIZE.y)
	return _map_rect.position + point * scale


func _process(_delta: float) -> void:
	var view := get_viewport_rect().size
	_map_rect = Rect2(Vector2(30, 30), Vector2(view.x - 500, view.y - 60))
	var mouse := get_local_mouse_position()
	var new_hover := -1
	for site: PlanetSite in campaign.star_map.sites:
		if _map_to_screen(site.map_position).distance_to(mouse) < 18.0:
			new_hover = site.id
	if new_hover != hovered:
		hovered = new_hover
		_refresh()
	queue_redraw()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT and hovered >= 0:
		selected = hovered
		_refresh()


func _refresh() -> void:
	if campaign == null:
		return
	var stores: ShipStores = campaign.stores
	_status.text = "Fuel %.0f/%.0f   Metal %.0f   Supplies %.0f\nCrew %d/%d needed to go home, fuel %.0f/%.0f needed." % [
		stores.fuel, stores.fuel_capacity(), stores.metal, stores.supplies, campaign.rescued_crew_count(),
		campaign.config.crew_to_win, stores.fuel, campaign.config.fuel_to_win]
	var _show := hovered if hovered >= 0 else selected
	var map: StarMap = campaign.star_map
	if _show >= 0:
		var site: PlanetSite = map.get_site(_show)
		var text := site.describe()
		if _show == map.current:
			text += "\n[color=#88ccff]You are here.[/color]"
		elif map.in_range(map.current, _show):
			text += "\nJump cost: [b]%.0f fuel[/b]" % map.jump_cost(map.current, _show, campaign.config, stores.mass())
		else:
			text += "\n[color=#ff8866]Out of FTL range from here.[/color]"
		_info.text = text
	else:
		_info.text = "Select a system."
	_jump_button.disabled = selected < 0 or selected == map.current or not map.in_range(map.current, selected)
	if selected >= 0 and selected != map.current:
		_jump_button.text = "Jump to %s (%.0f fuel)" % [map.get_site(selected).name, map.jump_cost(map.current, selected,
			campaign.config, stores.mass())]
	_home_button.disabled = not campaign.can_jump_home()


func _on_jump() -> void:
	var result: String = campaign.ftl_jump(selected)
	if result:
		_info.text = "[color=#ff6644]%s[/color]" % result
		return
	campaign.go_to_phase_scene()


func _on_home() -> void:
	var result: String = campaign.jump_home()
	if result:
		_info.text = result
		return
	campaign.go_to_phase_scene()


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.01, 0.015, 0.03))
	if campaign == null:
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for i: int in 300:
		draw_circle(Vector2(rng.randf() * size.x, rng.randf() * size.y), rng.randf_range(0.5, 1.5), Color(1, 1, 1, rng.randf_range(0.1, 0.5)))
	var map: StarMap = campaign.star_map
	var here: PlanetSite = map.get_current()
	var font := ThemeDB.fallback_font
	for site: PlanetSite in map.sites:
		if map.in_range(map.current, site.id):
			draw_line(_map_to_screen(here.map_position), _map_to_screen(site.map_position), Color(0.4, 0.7, 1.0, 0.25), 1.5)
	var range_radius := StarMap.MAX_JUMP * _map_to_screen(Vector2.ONE).distance_to(_map_to_screen(Vector2.ZERO)) / sqrt(2.0)
	draw_arc(_map_to_screen(here.map_position), range_radius, 0, TAU, 96, Color(0.4, 0.7, 1.0, 0.15), 1.0)
	for site: PlanetSite in map.sites:
		var p := _map_to_screen(site.map_position)
		var color: Color = KIND_COLORS.get(site.kind, Color.WHITE)
		if not site.visited:
			color = color.darkened(0.35)
		var radius := 9.0 + site.moons
		draw_circle(p, radius, color)
		if site.expedition_done:
			draw_arc(p, radius + 3.0, 0, TAU, 24, Color(0.5, 1.0, 0.5, 0.6), 1.5)
		if site.known_caches > 0:
			draw_circle(p + Vector2(radius, -radius), 4.0, Color(1.0, 0.85, 0.2))
		if site.visited and site.faction != PlanetSite.Faction.NONE and site.enemy_ships > 0:
			draw_circle(p + Vector2(-radius, -radius), 4.0, Color(1.0, 0.25, 0.2))
		if site.id == map.current:
			draw_arc(p, radius + 8.0, 0, TAU, 32, Color(0.5, 0.85, 1.0), 2.5)
		if site.id == selected:
			draw_arc(p, radius + 12.0, 0, TAU, 32, Color(1.0, 1.0, 1.0), 2.0)
		var label := site.name + ("" if site.visited else " ?")
		draw_string(font, p + Vector2(-30, radius + 18.0), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(1, 1, 1, 0.8))
