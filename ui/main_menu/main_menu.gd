extends Control

const SANDBOX := "res://ui/ship_console/ship_hud.tscn"


func _ready() -> void:
	%ContinueButton.pressed.connect(func() -> void:
		Campaign.listen_to_chat = true
		Campaign.continue_game()
	)
	%ContinueButton.disabled = not Campaign.has_save()
	%NewGameButton.pressed.connect(func() -> void:
		Campaign.listen_to_chat = true
		Campaign.new_game()
		Campaign.go_to_phase_scene()
	)
	%SandboxButton.pressed.connect(func() -> void:
		Campaign.active = false
		get_tree().change_scene_to_file(SANDBOX)
	)
	%QuitButton.pressed.connect(func() -> void: get_tree().quit())
