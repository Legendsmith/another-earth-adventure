class_name WeaponModule
extends ShipModule
## Base for weapons: a ShipModule the hull fires. The hull it is fitted to binds its own copy (bind), ticks it every
## physics frame (tick) and draws it (draw); positions and velocities come from the hull, the weapon only knows its
## bearing. It stops while its module is offline.

@export var max_range: float = 3000.0
## Fired by the hull's CombatAI. Off for the player's weapons, which fire on command (see PlayerWeapons).
@export var auto_fire: bool = true

## The hull this copy is fitted to, and its index there.
var hull: ShipHull
var index := -1


## Fits this copy to `owner` as its module `module_index`.
func bind(owner: ShipHull, module_index: int) -> void:
	hull = owner
	index = module_index


## Called by the hull every physics frame.
func tick(_delta: float) -> void:
	pass


## Called from the hull's _draw, in the hull's canvas with world orientation (no rotation).
func draw(_canvas: CanvasItem) -> void:
	pass


## Whether the weapon draws anything (the hull redraws every frame while one does).
func wants_redraw() -> bool:
	return false


func is_operational() -> bool:
	return hull != null and not hull.is_destroyed and hull.is_module_operational(index)


## Loaded / charged and able to fire now.
func is_ready() -> bool:
	return false


## 0..1 progress of the current reload or charge.
func get_readiness() -> float:
	return 1.0 if is_ready() else 0.0


func in_range(target: ShipHull) -> bool:
	return target.get_world_position().distance_to(hull.get_world_position()) <= max_range


func can_engage(target: ShipHull) -> bool:
	return is_instance_valid(target) and not target.is_destroyed and is_operational() and is_ready() and in_range(target)


## Fires at `target`. Returns false when the weapon could not fire (not ready, out of range, no firing solution).
func fire_at(_target: ShipHull) -> bool:
	return false


## Range bands drawn around the ship in the Combat view, inner to outer: {inner, outer, label} (world px).
func get_range_bands() -> Array[Dictionary]:
	return [{"inner": 0.0, "outer": max_range, "label": "%s range" % name}]


## Whether this weapon can engage incoming munitions (point defence).
func is_point_defence() -> bool:
	return false


## Chance (0..1) that this weapon destroys `munition` before it arrives. Point defence weapons override this.
func get_point_defence_kill_chance(_munition: Munition) -> float:
	return 0.0


## One-line status for the HUD.
func get_status() -> String:
	if not is_operational():
		return "%s: OFFLINE" % name
	return "%s: %s" % [name, "ready" if is_ready() else "%d%%" % roundi(get_readiness() * 100.0)]


func get_tree() -> SceneTree:
	return hull.get_tree() if hull and hull.is_inside_tree() else null
