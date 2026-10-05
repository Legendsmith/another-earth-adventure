class_name Constants

#region Program Navigation

const MAIN_MENU:String = "uid://dea4j22alycht"

#region Physics & Groups

const PLAYER_ENTITY := &"player_ent"
const PLAYER_GROUP := &"player"
const ENEMY_GROUP := &"opponent"
const PHYS_TERRAIN := 0
const PHYS_HAZARD := 1
const PHYS_INTERACT := 2
const FACTION_PHYSLAYER_OFFSET := 4
const PLAYER_PHYSICS_LAYER:= 3
const AGENT_MAX_LINEAR_DAMP := 4.0

#endregion

const CONTEST:StringName = &"contested"
const UPDATE:StringName = &"updating"

#endregion

#region Navigation

const NAV_LAYER_ALL := 1
const AVOIDANCE_OFFSET := 0
const FLOW_FIELD_GROUP := &"flow_field_target"
const SPATIAL_HASH_SIZE := 1024

#endregion


#region Audio Bus Information

const MASTER_BUS: StringName = &"Master"
const MUSIC_BUS: StringName = &"Music"
const SFX_BUS: StringName = &"Sfx"
const CHARACTER_VOICING: StringName = &"Character Voicing"

const MASTER_BUS_INDEX: int = 0
const MUSIC_BUS_INDEX: int = 1
const SFX_BUS_INDEX: int = 2
const CHARACTER_VOICING_INDEX: int = 3

#endregion

#region Dialogic Constants
const DIALOG_FIRST:String = "first"
const DIALOG_REPEAT:String = "repeat"
