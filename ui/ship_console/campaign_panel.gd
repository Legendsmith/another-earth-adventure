class_name CampaignPanel
extends VBoxContainer
## The campaign side of the Command view: stores and storage, where the ship is (low orbit, flyby, FTL limit) and
## what it can do there (expeditions, the FTL jump, salvage, caches), the modules with their maintenance and
## malfunctions, module cores waiting to be installed, and the crew with their wounds.

var campaign: Node
var orbit: CampaignOrbit

var _status: RichTextLabel
var _actions: HFlowContainer
var _modules: VBoxContainer
var _crew: VBoxContainer
var _log: RichTextLabel
var _dirty := true
var _timer := 0.0
var _planner: PanelContainer


func _ready() -> void:
	campaign = get_node_or_null("/root/Campaign")
	add_theme_constant_override("separation", 6)
	_status = _rich(self)
	_actions = HFlowContainer.new()
	add_child(_actions)
	_header("Ship modules")
	_modules = VBoxContainer.new()
	add_child(_modules)
	_header("Crew")
	_crew = VBoxContainer.new()
	add_child(_crew)
	_header("Ship log")
	_log = _rich(self)
	if campaign:
		campaign.stores_changed.connect(_mark_dirty)
		campaign.crew_changed.connect(_mark_dirty)
		campaign.ship.module_changed.connect(func(_m: ModuleState) -> void: _mark_dirty())
		campaign.message_posted.connect(func(_t: String, _s: int) -> void: _update_log())
	orbit = get_tree().root.find_child("CampaignOrbit", true, false) as CampaignOrbit


func _mark_dirty() -> void:
	_dirty = true


func _rich(parent: Node) -> RichTextLabel:
	var label := RichTextLabel.new()
	label.bbcode_enabled = true
	label.fit_content = true
	label.scroll_active = false
	label.add_theme_font_size_override("normal_font_size", 13)
	label.add_theme_font_size_override("bold_font_size", 13)
	parent.add_child(label)
	return label


func _header(text: String) -> void:
	var sep := HSeparator.new()
	add_child(sep)
	var label := Label.new()
	label.text = text
	add_child(label)


func _process(delta: float) -> void:
	if campaign == null or not campaign.active or not is_visible_in_tree():
		return
	_timer -= delta
	if _timer > 0.0:
		return
	_timer = 0.5
	_update_status()
	if _dirty and not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_dirty = false
		_rebuild_actions()
		_rebuild_modules()
		_rebuild_crew()
		_update_log()


func _update_status() -> void:
	var s: ShipStores = campaign.stores
	var site: PlanetSite = campaign.star_map.get_current()
	var stage: String = ["at the FTL limit", "in transit", "in LOW ORBIT", "on a LOW FLYBY"][campaign.orbit_stage]
	var lines: PackedStringArray = []
	lines.append("[b]%s[/b] - %s, %s" % [site.name, site.kind_name(), stage])
	lines.append("Fuel [b]%.0f[/b]/%.0f   Metal [b]%.0f[/b]   Supplies [b]%.0f[/b]   Hold %.0f/%.0f" % [s.fuel,
		s.fuel_capacity(), s.metal, s.supplies, s.cargo_used(), s.cargo_capacity()])
	var state: ShipState = campaign.ship
	lines.append("Power %.0f/%.0f   Reactor %d%%   Readiness %d%%   Armor %.0f/%.0f%s" % [state.power_demand(),
		state.power_capacity(), roundi(state.reactor_output() * 100.0), roundi(state.combat_readiness(campaign.crew) * 100.0),
		state.armor, state.max_armor, "   [color=#ff8844]COMBAT POWER[/color]" if state.combat_power else ""])
	lines.append("Home: fuel %.0f/%.0f, crew %d/%d" % [s.fuel, campaign.config.fuel_to_win, campaign.rescued_crew_count(),
		campaign.config.crew_to_win])
	if site.known_caches > 0:
		lines.append("Ship log: %d cache%s on this planet's satellites." % [site.known_caches, "s" if site.known_caches > 1 else ""])
	_status.text = "\n".join(lines)


func _rebuild_actions() -> void:
	for child: Node in _actions.get_children():
		child.queue_free()
	var reason: String = campaign.can_start_expedition()
	var expedition := _button(_actions, "Plan expedition", _open_planner)
	expedition.disabled = not reason.is_empty()
	expedition.tooltip_text = reason if reason else "Choose who goes and how they are equipped."
	var ftl := _button(_actions, "Engage FTL", func() -> void: orbit.engage_ftl())
	ftl.disabled = orbit == null or not orbit.can_engage_ftl()
	ftl.tooltip_text = "Fly out past the FTL limit ring to jump." if ftl.disabled else "Open the FTL map."
	var salvage := _button(_actions, "Stop salvage" if orbit and orbit.salvaging else "Salvage debris", _toggle_salvage)
	salvage.disabled = orbit == null or orbit.salvage_field() == null
	salvage.tooltip_text = "Fly inside a debris field to salvage it: time and supplies turn into metal."
	var site: PlanetSite = campaign.star_map.get_current()
	if site.known_caches > 0:
		var cache := _button(_actions, "Recover cache", _recover_cache)
		cache.disabled = not campaign.is_in_low_orbit()
	_button(_actions, "Load weapons", func() -> void:
		if orbit:
			orbit.load_weapons()
		_mark_dirty()).disabled = campaign.ship.weapons_loaded
	_button(_actions, "Build fuel tank (%.0f metal)" % campaign.config.storage_build_cost, func() -> void:
		campaign.stores.build_storage(true))
	_button(_actions, "Build cargo hold (%.0f metal)" % campaign.config.storage_build_cost, func() -> void:
		campaign.stores.build_storage(false))
	var missing: float = campaign.ship.max_armor - campaign.ship.armor
	if missing > 0.5:
		_button(_actions, "Repair armor (%.0f metal)" % (missing * campaign.config.metal_per_armor_point), func() -> void:
			campaign.ship.repair_armor(campaign.stores, missing)
			_mark_dirty())
	for i: int in campaign.stored_cores.size():
		var entry: Dictionary = campaign.stored_cores[i]
		var design := load(entry.design) as ShipModule
		var index := i
		_button(_actions, "Install %s core (%.0f metal)" % [design.name, design.size * campaign.config.storage_build_cost * 0.5],
			func() -> void:
				var result: String = campaign.install_core(index)
				if result:
					campaign.post(result, 1)
				_mark_dirty())


func _rebuild_modules() -> void:
	for child: Node in _modules.get_children():
		child.queue_free()
	var state: ShipState = campaign.ship
	var due := state.maintenance_due()
	var cost := 0.0
	for module: ModuleState in due:
		cost += module.maintenance_cost()
	if not due.is_empty():
		_button(_modules, "Maintain all due (%d modules, %.1f supplies)" % [due.size(), cost], func() -> void:
			campaign.maintain_all()
			_mark_dirty())
	for i: int in state.modules.size():
		var module := state.modules[i]
		var row := HBoxContainer.new()
		var label := Label.new()
		label.text = "%s [%s] crew %d - %s" % [module.get_module_name(), Manufacturers.display_name_of(module.manufacturer),
			module.crew_required(), module.status_text()]
		label.tooltip_text = Manufacturers.describe(module.manufacturer, module.get_kind(), module.military)
		label.mouse_filter = Control.MOUSE_FILTER_PASS
		label.add_theme_font_size_override("font_size", 12)
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		label.clip_text = true
		if not module.online:
			label.modulate = Color(1.0, 0.45, 0.4)
		elif module.is_overdue() or not module.malfunctions.is_empty():
			label.modulate = Color(1.0, 0.8, 0.35)
		elif not state.is_manned(i, campaign.crew):
			label.modulate = Color(0.7, 0.7, 0.7)
		row.add_child(label)
		var target := module
		var maintain := _button(row, "Maint", func() -> void:
			var result: String = campaign.maintain_module(target)
			if result:
				campaign.post(result, 1)
			_mark_dirty())
		maintain.tooltip_text = "%.1f supplies" % module.maintenance_cost()
		_modules.add_child(row)


func _rebuild_crew() -> void:
	for child: Node in _crew.get_children():
		child.queue_free()
	var counts := [0, 0, 0]
	for record: CrewRecord in campaign.crew:
		counts[record.status] += 1
	var summary := Label.new()
	summary.text = "%d active, %d in the medical bay, %d dead. Essential stations need %d." % [counts[0], counts[1],
		counts[2], campaign.ship.essential_crew_required()]
	summary.add_theme_font_size_override("font_size", 12)
	_crew.add_child(summary)
	for record: CrewRecord in campaign.crew:
		if not record.is_alive():
			continue
		var row := HBoxContainer.new()
		var label := Label.new()
		var station := ""
		if record.assigned_module >= 0 and record.assigned_module < campaign.ship.modules.size():
			station = " @ " + campaign.ship.modules[record.assigned_module].get_module_name()
		var chat := " (chat)" if record.is_chat_controlled() else ""
		label.text = "%s%s [%s] %s%s" % [record.get_shown_name(), chat, CrewRecord.STATUS_NAMES[record.status],
			record.body.get_status_name(), station]
		label.tooltip_text = record.summary() + "\n" + record.body.readout()
		label.mouse_filter = Control.MOUSE_FILTER_PASS
		label.add_theme_font_size_override("font_size", 12)
		label.add_theme_color_override("font_color", record.color)
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		label.clip_text = true
		row.add_child(label)
		if record.body.needs_augmentation():
			var target := record
			_button(row, "Bionics (%.0f metal)" % campaign.config.bionic_metal_cost, func() -> void:
				var result: String = campaign.augment(target)
				if result:
					campaign.post(result, 1)
				_mark_dirty())
		_crew.add_child(row)


func _update_log() -> void:
	if campaign == null:
		return
	var lines: PackedStringArray = campaign.log_lines
	_log.text = "\n".join(lines.slice(maxi(0, lines.size() - 8)))


func _button(parent: Node, text: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.focus_mode = Control.FOCUS_NONE
	button.add_theme_font_size_override("font_size", 12)
	button.pressed.connect(action)
	parent.add_child(button)
	return button


func _toggle_salvage() -> void:
	if orbit:
		orbit.salvaging = not orbit.salvaging
		campaign.post("Salvaging the debris field." if orbit.salvaging else "Salvage stopped.")
	_mark_dirty()


## A cache on one of the planet's satellites: resources, and sometimes a module core.
func _recover_cache() -> void:
	var site: PlanetSite = campaign.star_map.get_current()
	if site.known_caches <= 0:
		return
	site.known_caches -= 1
	site.caches = maxi(0, site.caches - 1)
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var fuel: float = campaign.stores.add(ShipStores.FUEL, rng.randf_range(10.0, 30.0))
	var metal: float = campaign.stores.add(ShipStores.METAL, rng.randf_range(5.0, 15.0))
	var supplies: float = campaign.stores.add(ShipStores.SUPPLIES, rng.randf_range(5.0, 20.0))
	campaign.post("Cache recovered: +%.0f fuel, +%.0f metal, +%.0f supplies." % [fuel, metal, supplies])
	if rng.randf() < 0.4:
		campaign._store_core(rng)
		campaign.post("The cache held a ship module core!")
	_mark_dirty()


#region Expedition planner

func _open_planner() -> void:
	if _planner and is_instance_valid(_planner):
		_planner.queue_free()
	_planner = PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.05, 0.07, 0.12, 0.97)
	style.border_color = Color(0.4, 0.7, 1.0)
	style.set_border_width_all(2)
	style.set_content_margin_all(12)
	_planner.add_theme_stylebox_override("panel", style)
	var layer := CanvasLayer.new()
	layer.layer = 30
	get_tree().root.add_child(layer)
	layer.add_child(_planner)
	_planner.tree_exited.connect(layer.queue_free)
	_planner.position = Vector2(560, 120)
	_planner.custom_minimum_size = Vector2(760, 600)
	var box := VBoxContainer.new()
	_planner.add_child(box)
	var site: PlanetSite = campaign.star_map.get_current()
	var title := Label.new()
	title.text = "Expedition to %s (%s)" % [site.name, site.kind_name()]
	box.add_child(title)
	var info := Label.new()
	info.text = PlanetRules.describe(site.kind)
	if campaign.orbit_stage == campaign.OrbitStage.FLYBY:
		info.text += "\nLow flyby: the expedition has %d seconds before the teleport window closes." % roundi(campaign.config.flyby_expedition_seconds)
	info.autowrap_mode = TextServer.AUTOWRAP_WORD
	box.add_child(info)
	var help := Label.new()
	help.text = "Up to %d crew besides you. Each needs a kit (%.1f supplies: ammo, medical kit%s); body armor costs %.1f metal." % [
		campaign.config.max_expedition_crew, campaign.config.supplies_per_kit,
		", oxygen" if PlanetRules.get_rule(site.kind, "needs_oxygen", false) else "", campaign.config.metal_per_armor]
	help.autowrap_mode = TextServer.AUTOWRAP_WORD
	box.add_child(help)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(740, 360)
	box.add_child(scroll)
	var list := VBoxContainer.new()
	scroll.add_child(list)
	var picks := {}
	var armor := {}
	var cost_label := Label.new()
	var update_cost := func() -> void:
		var members := 1 + picks.values().filter(func(v: bool) -> bool: return v).size()
		var armored := armor.keys().filter(func(id: int) -> bool: return armor[id] and (picks.get(id, false) or id == campaign.get_player().id)).size()
		var cost: Dictionary = campaign.expedition_cost(members, armored)
		cost_label.text = "Team of %d: %.1f supplies (have %.0f), %.1f metal (have %.0f)" % [members, cost.supplies,
			campaign.stores.supplies, cost.metal, campaign.stores.metal]
	var default_count := 0
	for record: CrewRecord in campaign.crew:
		if not record.is_active():
			continue
		var row := HBoxContainer.new()
		var pick := CheckBox.new()
		pick.focus_mode = Control.FOCUS_NONE
		pick.text = "%s  C%d M%d R%d  %s [%s]" % [record.get_shown_name(), record.skills[CrewRecord.COMBAT],
			record.skills[CrewRecord.MEDICAL], record.skills[CrewRecord.REPAIR], record.body.get_status_name(),
			CrewRecord.STANCE_NAMES[record.stance]]
		pick.custom_minimum_size = Vector2(520, 0)
		if record.is_player:
			pick.button_pressed = true
			pick.disabled = true
		else:
			# By default take a few crew who aren't needed at an essential station.
			var essential: bool = record.assigned_module >= 0 and campaign.ship.modules[record.assigned_module].is_essential()
			picks[record.id] = default_count < 4 and not essential
			if picks[record.id]:
				default_count += 1
			pick.button_pressed = picks[record.id]
			var id := record.id
			pick.toggled.connect(func(on: bool) -> void:
				picks[id] = on
				update_cost.call())
		row.add_child(pick)
		var armor_box := CheckBox.new()
		armor_box.focus_mode = Control.FOCUS_NONE
		armor_box.text = "Armor"
		var rid := record.id
		armor[rid] = false
		armor_box.toggled.connect(func(on: bool) -> void:
			armor[rid] = on
			update_cost.call())
		row.add_child(armor_box)
		if not record.is_player:
			var stance := OptionButton.new()
			stance.focus_mode = Control.FOCUS_NONE
			for stance_name: String in CrewRecord.STANCE_NAMES:
				stance.add_item(stance_name)
			stance.selected = record.stance
			var target := record
			stance.item_selected.connect(func(index: int) -> void: target.stance = index as CrewRecord.Stance)
			stance.disabled = record.is_chat_controlled()
			stance.tooltip_text = "Chat controls this crewmember's stance." if record.is_chat_controlled() else ""
			row.add_child(stance)
		list.add_child(row)
	box.add_child(cost_label)
	update_cost.call()
	var buttons := HBoxContainer.new()
	box.add_child(buttons)
	_button(buttons, "Launch expedition", func() -> void:
		var ids: Array = picks.keys().filter(func(id: int) -> bool: return picks[id])
		if ids.size() > campaign.config.max_expedition_crew:
			campaign.post("At most %d crew can go." % campaign.config.max_expedition_crew, 1)
			return
		var armored: Array = armor.keys().filter(func(id: int) -> bool: return armor[id])
		var result: String = campaign.start_expedition(ids, armored)
		if result:
			campaign.post(result, 1)
			return
		_planner.queue_free()
		campaign.go_to_phase_scene())
	_button(buttons, "Cancel", func() -> void: _planner.queue_free())

#endregion
