class_name SensorSuite
extends Node
## A ship's (or station's) sensors and the signature it shows to everyone else's. Place it as a child of the thing it
## belongs to: a Spaceship, an asteroid emplacement or any Node2D. A CombatHull on the same host supplies the faction,
## weapon flashes and sensor damage.
##
## Passive sensors listen for emissions: a contact of signature S is detected within passive_strength * sqrt(S) px.
## Active sensors ping: a contact of cross section C is detected within active_strength * sqrt(C) px whatever it
## emits, and is identified, but the ping adds active_signature to this ship's own signature.
## The SensorNetwork does the detecting; ships without a SensorSuite cannot be seen or see anything.

signal active_changed(active: bool)

const GROUP := &"sensor_suites"
## A sensor with every sensor component destroyed keeps this share of its strength.
const DAMAGED_FLOOR := 0.2

@export var display_name: String = ""
## Ship class shown once the contact is identified ("Freighter", "Gunship").
@export var classification: String = "Ship"
## Sensor faction when there is no CombatHull on the host. Empty = civilian: seen by everyone, sees for no one.
@export var faction: StringName = &""

@export_category("Passive")
@export var passive_strength: float = 400.0
## Signature of the host itself (reactor heat, lights, comms). Engines, weapon fire and active pings add to it.
@export var base_signature: float = 1.0

@export_category("Active")
## 0 = no active sensors.
@export var active_strength: float = 1200.0
## Signature the ping adds while active sensors are on.
@export var active_signature: float = 40.0
@export var active: bool = false: set = set_active

@export_category("Profile")
## Size seen by other ships' active sensors.
@export var cross_section: float = 1.0

var host: Node2D

var _hull: CombatHull
var _hull_checked := false


static func find_on(node: Node) -> SensorSuite:
	if node == null:
		return null
	for child in node.get_children():
		if child is SensorSuite:
			return child
	return null


func _enter_tree() -> void:
	add_to_group(GROUP)
	host = get_parent() as Node2D


func _ready() -> void:
	if display_name.is_empty() and host:
		display_name = host.name


func set_active(value: bool) -> void:
	value = value and has_active_sensors()
	if active == value:
		return
	active = value
	active_changed.emit(active)


func has_active_sensors() -> bool:
	return active_strength > 0.0


func get_hull() -> CombatHull:
	if not _hull_checked or (_hull != null and not is_instance_valid(_hull)):
		_hull_checked = true
		_hull = null
		if host:
			for child in host.get_children():
				if child is CombatHull:
					_hull = child
					break
	return _hull


func get_faction() -> StringName:
	var hull := get_hull()
	return hull.faction if hull else faction


## False once the host's CombatHull is destroyed: a wreck still shows up on sensors but no longer looks.
func is_operational() -> bool:
	var hull := get_hull()
	return hull == null or not hull.is_destroyed


func get_world_position() -> Vector2:
	if host is Spaceship:
		return host.get_state_position()
	return host.global_position if host else Vector2.ZERO


func get_world_velocity() -> Vector2:
	var hull := get_hull()
	if hull:
		return hull.get_world_velocity()
	if host is Spaceship:
		return host.get_state_velocity()
	return Vector2.ZERO


## Everything the host emits: itself, its engines, recent weapon fire and the active ping.
func get_signature() -> float:
	var signature := base_signature
	if host and host.has_method(&"get_sensor_signature"):
		signature += host.get_sensor_signature()
	var hull := get_hull()
	if hull:
		signature += hull.get_emission()
	if active:
		signature += active_signature
	return signature


## Share of the sensors still working after combat damage.
func get_condition() -> float:
	var hull := get_hull()
	if hull == null:
		return 1.0
	return maxf(hull.get_operational_fraction(ShipComponent.Kind.SENSORS), DAMAGED_FLOOR)


func passive_range_for(signature: float) -> float:
	return passive_strength * get_condition() * sqrt(maxf(signature, 0.0))


## Active range against a contact of `target_cross_section`; 0 while active sensors are off.
func active_range_for(target_cross_section: float) -> float:
	if not active:
		return 0.0
	return active_strength * get_condition() * sqrt(maxf(target_cross_section, 0.0))
