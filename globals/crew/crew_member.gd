## A Twitch chatter known to the crew roster.
## A member is either on the crew (holds a slot), waiting for a free slot, or in cold storage (freshness at 0).
class_name CrewMember
extends RefCounted

## Stable Twitch user id, falls back to the login name when the id is missing.
var user_id: String
var login: String
## Name shown in game, taken from chatter.tags.display_name.
var display_name: String
var color_hex: String
## How recently present this chatter is. Rises with messages, decays over time, retired at 0.
var freshness: float = 0.0
## Unix time of the last message, used to work out the freshness gain falloff.
var last_message_unix: float = 0.0
var message_count: int = 0
## Crew slot index, or -1 when not on the crew.
var slot: int = -1
## Free-form data other systems can attach to a crew member (rewards, stats). Must be JSON-compatible.
var extra: Dictionary = {}


func is_on_crew() -> bool:
	return slot >= 0


func is_cold() -> bool:
	return freshness <= 0.0


func is_waiting() -> bool:
	return not is_on_crew() and not is_cold()


func to_dict() -> Dictionary:
	return {
		"user_id": user_id,
		"login": login,
		"display_name": display_name,
		"color_hex": color_hex,
		"freshness": freshness,
		"last_message_unix": last_message_unix,
		"message_count": message_count,
		"slot": slot,
		"extra": extra,
	}


static func from_dict(data: Dictionary) -> CrewMember:
	var member := CrewMember.new()
	member.user_id = str(data.get("user_id", ""))
	member.login = str(data.get("login", ""))
	member.display_name = str(data.get("display_name", member.login))
	member.color_hex = str(data.get("color_hex", ""))
	member.freshness = float(data.get("freshness", 0.0))
	member.last_message_unix = float(data.get("last_message_unix", 0.0))
	member.message_count = int(data.get("message_count", 0))
	member.slot = int(data.get("slot", -1))
	var extra_data: Variant = data.get("extra", {})
	member.extra = extra_data if extra_data is Dictionary else {}
	return member
