class_name CrewRecord
extends RefCounted
## One crewmember of the ship (Crew and Character Attributes). Crew are replaceable: a short list of attributes and
## skills that rise slowly with use, a few traits, and a MedicalBody instead of hit points.
##
## Each generic crewmember is a slot Twitch chat can fill: a chatter on the crew roster takes control of a free record
## (controller_id) and steers it with stances. Special characters keep their own preset loadout and can only be taken
## over by a chatter whose name matches theirs exactly.

enum Status {
	## On duty: can man modules and join expeditions.
	ACTIVE,
	## Being treated in the medical bay; counts toward the crew for the lose condition but can't work.
	HEALING,
	DEAD,
}
## Expedition behaviour, set by Twitch chat commands (Expedition Gameplay, Twitch Chat crewmembers) or the crew screen.
enum Stance { DEFEND, EXPLORE, ATTACK, RESCUE, MEDIC }

const STANCE_NAMES := ["Defend", "Explore", "Attack", "Rescue", "Medic"]
const STATUS_NAMES := ["Active", "Healing", "Dead"]

const STRENGTH := &"strength"
const RESILIENCE := &"resilience"
const COMBAT := &"combat"
const MEDICAL := &"medical"
const REPAIR := &"repair"
const SKILLS: Array[StringName] = [COMBAT, MEDICAL, REPAIR]

const TRAIT_LITHE := &"lithe"
const TRAIT_ROBOT := &"robot"

const BASE_ATTRIBUTE := 10.0

const FIRST_NAMES := ["Ada", "Bram", "Cass", "Dov", "Esme", "Faro", "Gil", "Hana", "Ivo", "Juno", "Kael", "Lio",
	"Mira", "Nils", "Oona", "Pax", "Quill", "Rhea", "Sol", "Tam", "Uri", "Vey", "Wren", "Xan", "Yara", "Zed"]
const LAST_NAMES := ["Abara", "Brisk", "Corran", "Dahl", "Ekko", "Frey", "Gault", "Holm", "Ismay", "Jett", "Kova",
	"Lark", "Morrow", "Nakai", "Orr", "Price", "Quell", "Rook", "Sato", "Thorne", "Ulm", "Vance", "Wick", "Yeo"]

var id: int = 0
var display_name: String = "Crewmember"
var special: bool = false
## The main character: emergency teleported instead of dying, never controlled by chat.
var is_player: bool = false
## Twitch user id of the chatter controlling this crewmember, "" for an NPC.
var controller_id: String = ""
var controller_name: String = ""
var color: Color = Color.WHITE

var attributes: Dictionary[StringName, float] = {STRENGTH: BASE_ATTRIBUTE, RESILIENCE: BASE_ATTRIBUTE}
var skills: Dictionary[StringName, float] = {COMBAT: 0.0, MEDICAL: 0.0, REPAIR: 0.0}
## Experience towards the next level of each skill and attribute.
var experience: Dictionary[StringName, float] = {}
var traits: Array[StringName] = []
## Implants, cybernetics and other enhancements (ids), and the preset loadout of special characters.
var enhancements: Array[StringName] = []
var loadout: Array[StringName] = []

var status: Status = Status.ACTIVE
var stance: Stance = Stance.DEFEND
## Group size for !explore N: explorers band together in groups of this size.
var explore_group: int = 1
## Ship module this crewmember is assigned to (index in ShipState.modules), -1 for none.
var assigned_module: int = -1
var body: MedicalBody
var config: GameConfig


func _init(game_config: GameConfig = null) -> void:
	config = game_config if game_config else GameConfig.new()
	body = MedicalBody.new(config, false, BASE_ATTRIBUTE)


static func generate(game_config: GameConfig, rng: RandomNumberGenerator, record_id: int) -> CrewRecord:
	var record := CrewRecord.new(game_config)
	record.id = record_id
	record.display_name = "%s %s" % [FIRST_NAMES[rng.randi() % FIRST_NAMES.size()],
		LAST_NAMES[rng.randi() % LAST_NAMES.size()]]
	record.color = Color.from_hsv(rng.randf(), 0.45, 0.95)
	record.attributes[STRENGTH] = BASE_ATTRIBUTE + rng.randi_range(-2, 2)
	record.attributes[RESILIENCE] = BASE_ATTRIBUTE + rng.randi_range(-2, 2)
	for skill: StringName in SKILLS:
		record.skills[skill] = float(rng.randi_range(0, 1)) if rng.randf() < 0.4 else 0.0
	if rng.randf() < 0.12:
		record.traits.append(TRAIT_LITHE)
	elif rng.randf() < 0.06:
		record.traits.append(TRAIT_ROBOT)
	record.rebuild_body()
	return record


## Builds a fresh body matching the traits and resilience (new recruits, or after changing traits).
func rebuild_body() -> void:
	body = MedicalBody.new(config, has_trait(TRAIT_ROBOT), attributes[RESILIENCE])


func has_trait(trait_id: StringName) -> bool:
	return traits.has(trait_id)


func is_alive() -> bool:
	return status != Status.DEAD


func is_active() -> bool:
	return status == Status.ACTIVE


func is_chat_controlled() -> bool:
	return not controller_id.is_empty()


## The name shown above the character: the chatter's name when chat controls it.
func get_shown_name() -> String:
	return controller_name if is_chat_controlled() and not special else display_name


## Speed multiplier of a task using `skill`: skill levels speed it up with diminishing returns.
func skill_speed(skill: StringName) -> float:
	var level: float = skills.get(skill, 0.0)
	return 1.0 + (1.0 - 1.0 / (1.0 + level * config.skill_speed_factor))


## Carry capacity in loot units: Strength raises it, the Lithe trait lowers it.
func carry_capacity() -> float:
	var capacity: float = 4.0 * attributes[STRENGTH] / BASE_ATTRIBUTE
	if has_trait(TRAIT_LITHE):
		capacity *= 0.7
	return capacity


func move_speed_multiplier() -> float:
	return 1.25 if has_trait(TRAIT_LITHE) else 1.0


## Use raises skills and attributes slowly: an action packed expedition may give a level or two.
## For Resilience, use means being injured or exhausted. Returns true when a level was gained.
func train(stat: StringName, amount: float) -> bool:
	if amount <= 0.0:
		return false
	if has_trait(TRAIT_ROBOT) and attributes.has(stat):
		# Robots need special items to increase attributes.
		return false
	var xp: float = experience.get(stat, 0.0) + amount
	var level: float = skills.get(stat, attributes.get(stat, 0.0))
	var base: float = level if skills.has(stat) else level - BASE_ATTRIBUTE
	var needed := config.xp_per_level * (1.0 + maxf(0.0, base))
	if xp >= needed:
		experience[stat] = xp - needed
		if skills.has(stat):
			skills[stat] += 1.0
		else:
			attributes[stat] += 1.0
			if stat == RESILIENCE:
				body.resilience = attributes[RESILIENCE]
		return true
	experience[stat] = xp
	return false


func set_stance_from_command(command: String, argument: String = "") -> bool:
	match command:
		"!explore":
			stance = Stance.EXPLORE
			explore_group = clampi(argument.to_int(), 1, 12) if argument.is_valid_int() else 1
		"!defend":
			stance = Stance.DEFEND
		"!attack":
			stance = Stance.ATTACK
		"!rescue":
			stance = Stance.RESCUE
		"!heal", "!medic":
			stance = Stance.MEDIC
		_:
			return false
	return true


func summary() -> String:
	var skill_text := "C%d M%d R%d" % [skills[COMBAT], skills[MEDICAL], skills[REPAIR]]
	return "%s [%s] STR %d RES %d %s %s" % [get_shown_name(), STATUS_NAMES[status], attributes[STRENGTH],
		attributes[RESILIENCE], skill_text, body.get_status_name()]


func to_dict() -> Dictionary:
	var attr := {}
	for key: StringName in attributes:
		attr[String(key)] = attributes[key]
	var skill_data := {}
	for key: StringName in skills:
		skill_data[String(key)] = skills[key]
	var xp := {}
	for key: StringName in experience:
		xp[String(key)] = experience[key]
	return {
		"id": id, "name": display_name, "special": special, "player": is_player, "controller_id": controller_id,
		"controller_name": controller_name, "color": color.to_html(), "attributes": attr, "skills": skill_data,
		"experience": xp, "traits": Array(traits).map(func(t: StringName) -> String: return String(t)),
		"enhancements": Array(enhancements).map(func(t: StringName) -> String: return String(t)),
		"loadout": Array(loadout).map(func(t: StringName) -> String: return String(t)),
		"status": status, "stance": stance, "explore_group": explore_group, "assigned_module": assigned_module,
		"body": body.to_dict(),
	}


static func from_dict(data: Dictionary, game_config: GameConfig) -> CrewRecord:
	var record := CrewRecord.new(game_config)
	record.id = int(data.get("id", 0))
	record.display_name = str(data.get("name", "Crewmember"))
	record.special = bool(data.get("special", false))
	record.is_player = bool(data.get("player", false))
	record.controller_id = str(data.get("controller_id", ""))
	record.controller_name = str(data.get("controller_name", ""))
	record.color = Color.from_string(str(data.get("color", "ffffff")), Color.WHITE)
	for key: Variant in data.get("attributes", {}):
		record.attributes[StringName(key)] = float(data["attributes"][key])
	for key: Variant in data.get("skills", {}):
		record.skills[StringName(key)] = float(data["skills"][key])
	for key: Variant in data.get("experience", {}):
		record.experience[StringName(key)] = float(data["experience"][key])
	for value: Variant in data.get("traits", []):
		record.traits.append(StringName(value))
	for value: Variant in data.get("enhancements", []):
		record.enhancements.append(StringName(value))
	for value: Variant in data.get("loadout", []):
		record.loadout.append(StringName(value))
	record.status = int(data.get("status", Status.ACTIVE)) as Status
	record.stance = int(data.get("stance", Stance.DEFEND)) as Stance
	record.explore_group = int(data.get("explore_group", 1))
	record.assigned_module = int(data.get("assigned_module", -1))
	record.rebuild_body()
	record.body.load_dict(data.get("body", {}))
	return record
