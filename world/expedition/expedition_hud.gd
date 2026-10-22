extends CanvasLayer
## Expedition interface: objectives and loot, the squad with stances and retreat orders, the communicator (Twitch chat
## plus crew reports), the medical readout with its heartbeat and treatments, and the end of expedition summary.

const PANEL_BG := Color(0.04, 0.06, 0.1, 0.82)
const STATUS_COLORS := [Color(0.4, 0.95, 0.5), Color(1.0, 0.8, 0.25), Color(1.0, 0.5, 0.15), Color(1.0, 0.2, 0.2),
	Color(0.5, 0.5, 0.5)]

var expedition: Expedition
var patient: ExpeditionActor

var _top: Label
var _squad: VBoxContainer
var _squad_rows: Dictionary = {}
var _comms_panel: PanelContainer
var _comms: RichTextLabel
var _chat_input: LineEdit
var _medical: PanelContainer
var _medical_text: RichTextLabel
var _medical_buttons: HFlowContainer
var _menu: PanelContainer
var _summary: PanelContainer
var _flash: ColorRect
var _minigame: DressingMinigame
var _heartbeat: AudioStreamPlayer
var _beat_timer: float = 0.0
var _refresh_timer: float = 0.0
var _help: Label


func _ready() -> void:
	layer = 10
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)
	_flash = ColorRect.new()
	_flash.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_flash.color = Color(1, 0, 0, 0)
	_flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_flash)
	_top = Label.new()
	_top.position = Vector2(16, 10)
	_top.add_theme_font_size_override("font_size", 17)
	_top.add_theme_color_override("font_outline_color", Color.BLACK)
	_top.add_theme_constant_override("outline_size", 5)
	root.add_child(_top)
	_build_squad(root)
	_build_comms(root)
	_build_medical(root)
	_help = Label.new()
	_help.text = "WASD move  Mouse aim  LMB attack  Space dash  E interact/carry  Q weapon  F medical (self / ally under mouse)  RMB ally readout  Tab comms  Esc menu"
	_help.add_theme_font_size_override("font_size", 13)
	_help.modulate = Color(1, 1, 1, 0.6)
	_help.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	_help.position = Vector2(16, -26)
	root.add_child(_help)
	_heartbeat = AudioStreamPlayer.new()
	_heartbeat.stream = _make_thump()
	_heartbeat.bus = &"Effects" if AudioServer.get_bus_index(&"Effects") >= 0 else &"Master"
	add_child(_heartbeat)
	expedition.comms_line.connect(_on_comms_line)


func _panel(parent: Control, rect: Rect2, anchor: Control.LayoutPreset) -> PanelContainer:
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = PANEL_BG
	style.set_corner_radius_all(6)
	style.set_content_margin_all(8)
	panel.add_theme_stylebox_override("panel", style)
	parent.add_child(panel)
	panel.set_anchors_preset(anchor)
	panel.position = rect.position
	panel.size = rect.size
	panel.custom_minimum_size = rect.size
	return panel


func _build_squad(root: Control) -> void:
	var panel := _panel(root, Rect2(12, 120, 330, 10), Control.PRESET_TOP_LEFT)
	var box := VBoxContainer.new()
	panel.add_child(box)
	var title := Label.new()
	title.text = "Squad"
	box.add_child(title)
	_squad = VBoxContainer.new()
	box.add_child(_squad)


func _build_comms(root: Control) -> void:
	var viewport := root.get_viewport_rect().size
	_comms_panel = _panel(root, Rect2(viewport.x - 432, 12, 420, 430), Control.PRESET_TOP_LEFT)
	var box := VBoxContainer.new()
	_comms_panel.add_child(box)
	var title := Label.new()
	title.text = "Communicator"
	box.add_child(title)
	_comms = RichTextLabel.new()
	_comms.bbcode_enabled = true
	_comms.scroll_following = true
	_comms.custom_minimum_size = Vector2(400, 350)
	_comms.add_theme_font_size_override("normal_font_size", 13)
	box.add_child(_comms)
	_chat_input = LineEdit.new()
	_chat_input.placeholder_text = "Test chat: name: message (e.g. alice: !explore 2)"
	_chat_input.text_submitted.connect(_on_chat_submitted)
	box.add_child(_chat_input)


func _build_medical(root: Control) -> void:
	var viewport := root.get_viewport_rect().size
	_medical = _panel(root, Rect2(viewport.x - 432, 452, 420, 420), Control.PRESET_TOP_LEFT)
	var box := VBoxContainer.new()
	_medical.add_child(box)
	_medical_text = RichTextLabel.new()
	_medical_text.bbcode_enabled = true
	_medical_text.fit_content = true
	_medical_text.custom_minimum_size = Vector2(400, 280)
	_medical_text.add_theme_font_size_override("normal_font_size", 13)
	box.add_child(_medical_text)
	_medical_buttons = HFlowContainer.new()
	box.add_child(_medical_buttons)
	_medical.visible = false


func _process(delta: float) -> void:
	if expedition == null or expedition.player == null:
		return
	_update_top()
	_refresh_timer -= delta
	if _refresh_timer <= 0.0:
		_refresh_timer = 0.4
		_update_squad()
		if _medical.visible:
			_update_medical()
	_flash.color.a = maxf(0.0, _flash.color.a - delta * 1.5)
	if _medical.visible and patient and not patient.body.dead and patient.body.heart_rate > 0.0:
		_beat_timer -= delta
		if _beat_timer <= 0.0:
			_beat_timer = 60.0 / maxf(patient.body.heart_rate, 20.0)
			_heartbeat.volume_db = -6.0 if patient.body.get_status() >= MedicalBody.Status.CRITICAL else -14.0
			_heartbeat.play()


func _update_top() -> void:
	var ex := expedition
	var p := ex.player
	var lines: PackedStringArray = []
	var site_name: String = ex.site.name if ex.site else "?"
	lines.append("%s %s  |  %s" % [["Expedition:", "Escape from", "Boarding action aboard"][ex.mode], site_name if ex.mode != Expedition.Mode.BOARDING else "your ship", _time_text()])
	lines.append("Recovered: Fuel %.0f  Metal %.0f  Supplies %.0f  Cores %d  Data %d" % [ex.deposited.fuel,
		ex.deposited.metal, ex.deposited.supplies, ex.deposited.cores, ex.deposited.data])
	var carried: PackedStringArray = []
	for key: Variant in p.carried:
		carried.append("%s %.0f" % [str(key).capitalize(), p.carried[key]])
	lines.append("You: %s  %s  Ammo %d  Dressings %d  Stims %d  |  Carrying %s (%.1f/%.1f)" % [p.get_weapon().name,
		p.body.get_status_name(), p.ammo, p.dressings, p.stimulants, ", ".join(carried) if carried.size() else "nothing",
		p.carry_weight(), p.carry_capacity()])
	if ex.lava_world:
		lines.append("Eruption gauge: %d%%%s" % [roundi(ex.eruption), "  ERUPTING IN %.1f s" % ex.eruption_countdown if ex.eruption_countdown >= 0.0 else ""])
	if ex.mode == Expedition.Mode.BOARDING:
		lines.append("Boarders left: %d" % ex.enemies_left())
	_top.text = "\n".join(lines)


func _time_text() -> String:
	var ex := expedition
	if ex.time_limit > 0.0:
		return "Teleport window: %d s" % maxi(0, roundi(ex.time_limit - ex.elapsed))
	return "%d:%02d" % [int(ex.elapsed) / 60, int(ex.elapsed) % 60]


func _update_squad() -> void:
	for actor: ExpeditionActor in expedition.actors:
		if actor.faction != ExpeditionActor.PLAYER_FACTION or actor.state == &"captive":
			continue
		var row: HBoxContainer = _squad_rows.get(actor)
		if row == null:
			row = _make_squad_row(actor)
			_squad_rows[actor] = row
		var label: Label = row.get_child(0)
		var status := actor.body.get_status()
		var where := " (ship)" if actor.gone and not actor.body.dead else ""
		var stance := ""
		if actor.record and actor.role == ExpeditionActor.Role.CREW:
			stance = " [%s]" % CrewRecord.STANCE_NAMES[actor.record.stance]
		elif actor.role == ExpeditionActor.Role.PRISONER:
			stance = " [freed]"
		label.text = "%s%s %s%s" % [actor.display_name, stance, MedicalBody.STATUS_NAMES[status], where]
		label.modulate = STATUS_COLORS[status] if not actor.gone else Color(0.6, 0.7, 0.9)


func _make_squad_row(actor: ExpeditionActor) -> HBoxContainer:
	var row := HBoxContainer.new()
	var label := Label.new()
	label.custom_minimum_size = Vector2(200, 0)
	label.add_theme_font_size_override("font_size", 13)
	label.clip_text = true
	row.add_child(label)
	var inspect := Button.new()
	inspect.text = "Med"
	inspect.focus_mode = Control.FOCUS_NONE
	inspect.pressed.connect(func() -> void: open_medical(actor))
	row.add_child(inspect)
	# NPCs (not chat controlled) take orders from the crew interface.
	if actor.role == ExpeditionActor.Role.CREW and actor.record and not actor.record.is_chat_controlled():
		var stance := OptionButton.new()
		stance.focus_mode = Control.FOCUS_NONE
		for stance_name: String in CrewRecord.STANCE_NAMES:
			stance.add_item(stance_name)
		stance.selected = actor.record.stance
		stance.item_selected.connect(func(index: int) -> void:
			actor.record.stance = index as CrewRecord.Stance
			expedition._on_stance_changed(actor.record))
		row.add_child(stance)
		var retreat := Button.new()
		retreat.text = "Retreat"
		retreat.focus_mode = Control.FOCUS_NONE
		retreat.pressed.connect(func() -> void:
			if not actor.body.dead:
				expedition.teleport_out(actor, "Retreating to the ship!"))
		row.add_child(retreat)
	_squad.add_child(row)
	return row


#region Communicator

func _on_comms_line(sender: String, text: String, color: Color, kind: StringName) -> void:
	if kind == &"minor":
		return
	var prefix := ""
	match kind:
		&"system":
			prefix = "[color=#88aacc]» [/color]"
		&"chat":
			prefix = "[color=#aa88ff]💬 [/color]"
	_comms.append_text("%s[color=#%s][b]%s:[/b][/color] %s\n" % [prefix, color.to_html(false), sender.replace("[", "("),
		text.replace("[", "(")])


func toggle_comms() -> void:
	_comms_panel.visible = not _comms_panel.visible


func _on_chat_submitted(text: String) -> void:
	_chat_input.text = ""
	_chat_input.release_focus()
	var split := text.find(":")
	if split <= 0:
		return
	var who := text.substr(0, split).strip_edges()
	var message := text.substr(split + 1).strip_edges()
	var roster: Node = get_node_or_null("/root/Crew")
	if roster:
		roster.register_message(who.to_lower(), who.to_lower(), who, message)
	if expedition.campaign:
		expedition.campaign.handle_chat(who.to_lower(), who.to_lower(), message)

#endregion


#region Medical

func open_medical(actor: ExpeditionActor) -> void:
	if actor == null:
		return
	if _medical.visible and patient == actor:
		_medical.visible = false
		return
	patient = actor
	_medical.visible = true
	_beat_timer = 0.0
	_update_medical()


func _update_medical() -> void:
	if patient == null:
		_medical.visible = false
		return
	var b := patient.body
	var lines: PackedStringArray = []
	var status := b.get_status()
	lines.append("[b]%s[/b]  [color=#%s]%s[/color]  %s" % [patient.display_name, STATUS_COLORS[status].to_html(false),
		MedicalBody.STATUS_NAMES[status].to_upper(), MedicalBody.AWARENESS_NAMES[b.awareness]])
	if b.is_robot:
		lines.append(b.readout())
	else:
		lines.append("Brain %d  Blood %.2f L  O2 %d%%  Heart %d bpm%s" % [roundi(b.brain), b.blood, roundi(b.blood_o2),
			roundi(b.heart_rate), "  [color=#ff4444]CARDIAC ARREST[/color]" if b.cardiac_arrest else ""])
		lines.append("Pain %d  Shock %d  Adrenaline %d  Stamina %d  Consciousness %d" % [roundi(b.effective_pain()),
			roundi(b.shock), roundi(b.adrenaline), roundi(b.stamina), roundi(b.consciousness)])
		if b.stimulant > 1.0 or b.painkiller > 1.0 or b.sedative > 1.0 or b.toxin > 1.0:
			lines.append("Stim %d  Painkiller %d  Sedative %d  Toxin %d" % [roundi(b.stimulant), roundi(b.painkiller),
				roundi(b.sedative), roundi(b.toxin)])
	lines.append("")
	for part: MedicalBody.Part in b.parts.values():
		var frac := clampf(part.hp / part.max_hp, 0.0, 1.0)
		var bar := "█".repeat(roundi(frac * 10.0)) + "░".repeat(10 - roundi(frac * 10.0))
		var notes: PackedStringArray = []
		if part.amputated:
			notes.append("[color=#ff4444]LOST[/color]")
		elif part.is_disabled():
			notes.append("[color=#ff8844]disabled[/color]")
		if part.bleed > 0.0:
			notes.append("[color=#ff5555]bleeding %.2f L/min[/color]" % part.bleed)
		if part.dressing > 0.0:
			notes.append("[color=#aaddff]dressed %ds[/color]" % roundi(part.dressing))
		if part.bionic:
			notes.append("bionic")
		lines.append("%-10s %s %3d/%d %s" % [MedicalBody.PART_LABELS.get(part.id, String(part.id)), bar, roundi(part.hp),
			roundi(part.max_hp), " ".join(notes)])
	_medical_text.text = "\n".join(lines)
	_rebuild_medical_buttons()


func _rebuild_medical_buttons() -> void:
	for child: Node in _medical_buttons.get_children():
		child.queue_free()
	var medic := expedition.player
	var in_reach := patient == medic or medic.global_position.distance_to(patient.global_position) <= ExpeditionActor.INTERACT_RANGE * 1.5
	if patient.body.dead:
		_add_button("Close", func() -> void: _medical.visible = false)
		return
	for part: MedicalBody.Part in patient.body.parts.values():
		if part.bleed > 0.0 and part.dressing <= 0.0 and not part.amputated:
			var target_part := part
			var button := _add_button("Dress %s (%d)" % [MedicalBody.PART_LABELS.get(part.id, part.id), medic.dressings],
				func() -> void: _start_dressing(target_part.id))
			button.disabled = not in_reach or medic.dressings <= 0
	var stim := _add_button("Stimulant (%d)" % medic.stimulants, func() -> void: _give(&"stim"))
	stim.disabled = not in_reach or medic.stimulants <= 0
	var pain := _add_button("Painkiller (%d)" % medic.painkillers, func() -> void: _give(&"pain"))
	pain.disabled = not in_reach or medic.painkillers <= 0
	var sedate := _add_button("Sedative (%d)" % medic.sedatives, func() -> void: _give(&"sedative"))
	sedate.disabled = not in_reach or medic.sedatives <= 0
	if patient.body.cardiac_arrest:
		var cpr := _add_button("CPR", func() -> void: _give(&"cpr"))
		cpr.disabled = not in_reach
	_add_button("Close", func() -> void: _medical.visible = false)
	if not in_reach:
		var far := Label.new()
		far.text = "Move next to them to treat."
		_medical_buttons.add_child(far)


func _add_button(text: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.focus_mode = Control.FOCUS_NONE
	button.pressed.connect(action)
	_medical_buttons.add_child(button)
	return button


func _give(what: StringName) -> void:
	var medic := expedition.player
	var b := patient.body
	match what:
		&"stim":
			medic.stimulants -= 1
			b.give_stimulant()
		&"pain":
			medic.painkillers -= 1
			b.give_painkiller()
		&"sedative":
			medic.sedatives -= 1
			b.give_sedative()
		&"cpr":
			var ok := b.resuscitate(medic.skill(CrewRecord.MEDICAL))
			expedition.comms("You", "Pulse is back!" if ok else "No pulse... keep trying.", Color(0.8, 0.9, 1.0), &"system")
	if medic.record:
		medic.record.train(CrewRecord.MEDICAL, 1.0)
	_update_medical()


func _start_dressing(part_id: StringName) -> void:
	if _minigame:
		return
	var medic := expedition.player
	_minigame = DressingMinigame.new()
	_minigame.part_label = MedicalBody.PART_LABELS.get(part_id, String(part_id)).to_lower()
	_minigame.skill_speed = medic.skill_speed(CrewRecord.MEDICAL) * medic.body.handling_multiplier()
	var target := patient
	_minigame.completed.connect(func(quality: float) -> void:
		_minigame = null
		if medic.dressings > 0 and not target.body.dead:
			medic.dressings -= 1
			target.body.apply_dressing(part_id, quality)
			if medic.record:
				medic.record.train(CrewRecord.MEDICAL, 3.0)
			expedition.comms("You", "Dressed %s's %s." % [target.display_name, MedicalBody.PART_LABELS.get(part_id, "wound").to_lower()],
				Color(0.8, 0.9, 1.0), &"system")
		_update_medical())
	_minigame.cancelled.connect(func() -> void: _minigame = null)
	add_child(_minigame)


func is_minigame_active() -> bool:
	return _minigame != null and is_instance_valid(_minigame)


func mouse_over_ui() -> bool:
	var hovered := get_viewport().gui_get_hovered_control()
	return hovered != null and hovered != _flash and hovered.mouse_filter != Control.MOUSE_FILTER_IGNORE


func flash_damage(amount: float) -> void:
	_flash.color.a = clampf(_flash.color.a + amount / 60.0, 0.0, 0.45)


## A short low thump for the heartbeat.
func _make_thump() -> AudioStreamWAV:
	var rate := 22050
	var samples := int(rate * 0.12)
	var data := PackedByteArray()
	data.resize(samples * 2)
	for i: int in samples:
		var t := float(i) / rate
		var value := sin(TAU * 55.0 * t) * exp(-t * 30.0) + 0.4 * sin(TAU * 110.0 * t) * exp(-t * 45.0)
		data.encode_s16(i * 2, int(clampf(value, -1.0, 1.0) * 26000.0))
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = rate
	stream.data = data
	return stream

#endregion


#region Menu and summary

func toggle_menu() -> void:
	if _minigame:
		return
	if _menu and is_instance_valid(_menu):
		_menu.queue_free()
		_menu = null
		return
	var root: Control = get_child(0)
	_menu = _panel(root, Rect2(root.get_viewport_rect().size / 2.0 - Vector2(180, 110), Vector2(360, 220)), Control.PRESET_TOP_LEFT)
	var box := VBoxContainer.new()
	_menu.add_child(box)
	var label := Label.new()
	label.text = "Expedition paused? No: the world keeps moving.\nAbandoning recalls everyone with what they carry."
	label.autowrap_mode = TextServer.AUTOWRAP_WORD
	box.add_child(label)
	var resume := Button.new()
	resume.text = "Resume"
	resume.pressed.connect(toggle_menu)
	box.add_child(resume)
	var abandon := Button.new()
	abandon.text = "Abandon expedition (teleport everyone back)"
	abandon.pressed.connect(func() -> void:
		toggle_menu()
		expedition.end_expedition("abandoned"))
	box.add_child(abandon)


func confirm_extract() -> void:
	var out := 0
	for actor: ExpeditionActor in expedition.allies(true):
		if actor != expedition.player and actor.global_position.distance_to(expedition.entrance_position()) > Expedition.EXTRACT_RADIUS:
			out += 1
	if out == 0:
		expedition.end_expedition("extracted")
		return
	var root: Control = get_child(0)
	var dialog := _panel(root, Rect2(root.get_viewport_rect().size / 2.0 - Vector2(200, 80), Vector2(400, 160)), Control.PRESET_TOP_LEFT)
	var box := VBoxContainer.new()
	dialog.add_child(box)
	var label := Label.new()
	label.text = "Return to the ship? %d of the team are still out there; they will be teleported back with what they carry." % out
	label.autowrap_mode = TextServer.AUTOWRAP_WORD
	box.add_child(label)
	var row := HBoxContainer.new()
	box.add_child(row)
	var yes := Button.new()
	yes.text = "Return"
	yes.pressed.connect(func() -> void:
		dialog.queue_free()
		expedition.end_expedition("extracted"))
	row.add_child(yes)
	var no := Button.new()
	no.text = "Stay"
	no.pressed.connect(dialog.queue_free)
	row.add_child(no)


func show_summary(result: Dictionary) -> void:
	var root: Control = get_child(0)
	_summary = _panel(root, Rect2(root.get_viewport_rect().size / 2.0 - Vector2(260, 170), Vector2(520, 340)), Control.PRESET_TOP_LEFT)
	var box := VBoxContainer.new()
	_summary.add_child(box)
	var text := RichTextLabel.new()
	text.bbcode_enabled = true
	text.fit_content = true
	text.custom_minimum_size = Vector2(500, 250)
	var titles := {"extracted": "Back aboard", "flyby": "Teleport window closed", "eruption": "Eruption!",
		"captain_down": "Emergency teleport", "repelled": "Boarders repelled", "boarding_lost": "The ship is taken",
		"abandoned": "Expedition abandoned"}
	var lines: PackedStringArray = ["[b]%s[/b]" % titles.get(result.reason, "Expedition over"), ""]
	lines.append("Fuel %.0f   Metal %.0f   Supplies %.0f" % [result.get("fuel", 0.0), result.get("metal", 0.0), result.get("supplies", 0.0)])
	lines.append("Module cores %d   Cache locations %d" % [result.get("cores", 0), result.get("cache_info", 0)])
	lines.append("Prisoners rescued: %d" % result.get("crew_rescued", 0))
	lines.append("(Anything beyond the ship's tank and hold capacity is left behind.)")
	lines.append("")
	for actor: ExpeditionActor in expedition.actors:
		if actor.faction == ExpeditionActor.PLAYER_FACTION and actor.role != ExpeditionActor.Role.PRISONER:
			var state := "dead" if actor.body.dead else actor.body.get_status_name()
			lines.append("%s: %s" % [actor.display_name, state])
	text.text = "\n".join(lines)
	box.add_child(text)
	var button := Button.new()
	button.text = "Continue"
	button.pressed.connect(func() -> void: expedition.return_to_ship(result))
	box.add_child(button)
	button.grab_focus()

#endregion
