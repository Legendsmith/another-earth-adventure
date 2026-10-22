class_name ExpeditionWeapon
extends Resource
@export var display_name:String = ""
@export var melee:bool = false
@export var damage:float = 0
@export var type:MedicalBody.DamageType 
@export var weapon_range:float = 10.0
@export var cooldown:float = 0.5
@export var accuracy:float = 1.0
## Big hits (huge enemies, explosions) can take off a limb (see MedicalBody.take_damage).
@export var huge:bool = false
## Radius of a blast around the point of impact; 0 for none. Things in it take half damage.
@export var splash:float = 0.0

## Weapon definitions live in this folder, one file per weapon id (claws.tres, pistol.tres...).
const FOLDER := "res://data/expedition_weapons/"

static var _cache:Dictionary[StringName,ExpeditionWeapon] = {}


## The definition for a weapon id, or null when there is no such file.
static func find(id:StringName) -> ExpeditionWeapon:
	if not _cache.has(id):
		var path := FOLDER + String(id) + ".tres"
		_cache[id] = load(path) as ExpeditionWeapon if ResourceLoader.exists(path) else null
	return _cache[id]
