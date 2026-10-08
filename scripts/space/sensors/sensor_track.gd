class_name SensorTrack
extends RefCounted
## What the player's side knows about one contact. While the contact is held the track follows it; once it is lost
## the track becomes a ghost: the last known position, plus a projection of where it should be now and next,
## assuming it kept coasting under gravity.

enum Kind { SHIP, MUNITION }
## How the contact is held this sweep.
enum Lock { LOST, PASSIVE, ACTIVE }

const LOCK_NAMES := ["lost", "passive", "active"]

## "S-04" for ships and stations, "M-12" for munitions.
var designation: String
var kind: Kind
## The SensorSuite or Munition being tracked. May be freed while the track is a ghost.
var target: Object
var lock: Lock = Lock.LOST
## Identified contacts show their name, class and faction. Stays true once earned.
var identified := false

var first_seen := 0.0
var last_seen := 0.0
var last_position := Vector2.ZERO
var last_velocity := Vector2.ZERO
var last_signature := 0.0

## Ghost projection from the moment the contact was lost: world positions sampled from ghost_start to ghost_end.
var ghost_points := PackedVector2Array()
var ghost_start := 0.0
var ghost_end := 0.0


func is_held() -> bool:
	return lock != Lock.LOST


func is_ghost() -> bool:
	return lock == Lock.LOST


func has_target() -> bool:
	return is_instance_valid(target)


## The tracked suite's CombatHull, if it has one.
func get_hull() -> CombatHull:
	# Check validity first: `is` on a freed object (a ghost whose contact was destroyed) is an error.
	if is_instance_valid(target) and target is SensorSuite:
		return (target as SensorSuite).get_hull()
	return null


func get_faction() -> StringName:
	if not has_target():
		return &""
	if target is SensorSuite:
		return (target as SensorSuite).get_faction()
	return target.faction


func get_display_name() -> String:
	if not identified or not has_target():
		return "Unknown contact" if kind == Kind.SHIP else "Unknown munition"
	if target is SensorSuite:
		return (target as SensorSuite).display_name
	return target.munition_name


func get_classification() -> String:
	if not identified or not has_target():
		return "?"
	if target is SensorSuite:
		return (target as SensorSuite).classification
	return "Munition"


## Projected position at `time`: the live position while held, the ghost projection once lost.
func get_position_at(time: float) -> Vector2:
	if is_held():
		return last_position
	if ghost_points.is_empty():
		return last_position + last_velocity * (time - last_seen)
	if ghost_points.size() == 1 or ghost_end <= ghost_start:
		return ghost_points[0]
	var t := clampf((time - ghost_start) / (ghost_end - ghost_start), 0.0, 1.0) * (ghost_points.size() - 1)
	var i := mini(floori(t), ghost_points.size() - 2)
	return ghost_points[i].lerp(ghost_points[i + 1], t - i)


## Points of the projected path between two times (for drawing).
func get_path_between(from_time: float, to_time: float) -> PackedVector2Array:
	var points := PackedVector2Array()
	if ghost_points.size() < 2 or ghost_end <= ghost_start:
		return points
	points.append(get_position_at(from_time))
	var step := (ghost_end - ghost_start) / (ghost_points.size() - 1)
	var first := ceili((from_time - ghost_start) / step)
	var last := floori((minf(to_time, ghost_end) - ghost_start) / step)
	for i in range(maxi(first, 0), mini(last, ghost_points.size() - 1) + 1):
		points.append(ghost_points[i])
	points.append(get_position_at(to_time))
	return points


## True once the projection has run out: the ghost no longer says anything useful.
func is_projection_expired(time: float) -> bool:
	return is_ghost() and time > ghost_end
