extends Node
var current_channel

func _init():
	name = "Twitch"

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	GameSettings.channel_changed.connect(switch_channel)
	GameSettings.debug_setting_changed.connect(switch_debug)
	current_channel = GameSettings.get_channel_name()
	VerySimpleTwitch.login_chat_anon(current_channel)


func print_chatter_message(chatter) -> void:
	print("Message received from %s: %s" % [chatter.tags.display_name, chatter.message])

func switch_channel() -> void:
	if GameSettings.get_channel_name() == current_channel:
		return
	else:
		VerySimpleTwitch.end_chat_client()
		current_channel = GameSettings.get_channel_name()
		VerySimpleTwitch.login_chat_anon(current_channel)

func switch_debug() -> void:
	if GameSettings.get_print_twitch_messages() and not VerySimpleTwitch.chat_message_received.is_connected(print_chatter_message):
		VerySimpleTwitch.chat_message_received.connect(print_chatter_message)
	elif VerySimpleTwitch.chat_message_received.is_connected(print_chatter_message) and not GameSettings.get_print_twitch_messages():
		VerySimpleTwitch.chat_message_received.disconnect(print_chatter_message)
