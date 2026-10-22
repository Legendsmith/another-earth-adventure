extends Control
## A plain main menu for the campaign: new run, continue the latest save, the orbital sandbox, quit.
## (The art title screen in ui/title_screen does the same once its audio and shader assets are in the repo.)

const SANDBOX := "res://ui/ship_console/ship_hud.tscn"


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = Color(0.02, 0.03, 0.07)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	box.custom_minimum_size = Vector2(420, 0)
	box.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	box.position -= Vector2(210, 180)
	add_child(box)
	var title := Label.new()
	title.text = "ANOTHER EARTH\nADVENTURE"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 46)
	box.add_child(title)
	var campaign: Node = get_node("/root/Campaign")
	var continue_button := _button(box, "Continue", func() -> void:
		campaign.listen_to_chat = true
		campaign.continue_game())
	continue_button.disabled = not campaign.has_save()
	_button(box, "New voyage", func() -> void:
		campaign.listen_to_chat = true
		campaign.new_game()
		campaign.go_to_phase_scene()).grab_focus()
	_button(box, "Orbital sandbox", func() -> void:
		campaign.active = false
		get_tree().change_scene_to_file(SANDBOX))
	_button(box, "Quit", func() -> void: get_tree().quit())
	var hint := Label.new()
	hint.text = "Twitch channel and other options are in the ship console's settings."
	hint.modulate = Color(1, 1, 1, 0.5)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(hint)


func _button(parent: Node, text: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(0, 48)
	button.add_theme_font_size_override("font_size", 20)
	button.pressed.connect(action)
	parent.add_child(button)
	return button
