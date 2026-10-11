class_name WeaponGroup
extends Resource
## Weapons the player fires with one command (see PlayerWeapons). A hull lists its groups in ShipHull.weapon_groups;
## every weapon left out of them gets a linked group of its own.

enum Mode {
	## One command fires every weapon of the group that is ready.
	LINKED,
	## One command fires the next weapon of the group in turn that is ready.
	ALTERNATING,
	## Toggled on and off by the command: while on, each weapon fires at the selected contact whenever it is ready.
	AUTOFIRE,
}

const MODE_NAMES := ["Linked", "Alternating", "Autofire"]

@export var name: String = "Group"
@export var mode: Mode = Mode.LINKED
## Indices of the group's weapons in the hull's weapon list (ShipHull.get_weapons, in module order).
@export var weapons: PackedInt32Array = []

## AUTOFIRE: firing on its own.
var active := false
## ALTERNATING: position in `weapons` of the next weapon to try.
var next := 0


static func create(group_name: String, weapon_indices: PackedInt32Array, group_mode: Mode = Mode.LINKED) -> WeaponGroup:
	var group := WeaponGroup.new()
	group.name = group_name
	group.weapons = weapon_indices
	group.mode = group_mode
	return group


func get_mode_name() -> String:
	return MODE_NAMES[mode]
