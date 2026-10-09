class_name CombatHull
extends Node2D
## Makes its parent (a Spaceship, an asteroid emplacement or any Node2D) a combatant: armor and internal components.
## Weapon mounts are children of the hull. Sensors and the sensor signature live in a SensorSuite on the same parent;
## the hull gives it its faction, adds weapon flashes to its signature and degrades it as sensor components are lost.
##
## Damage follows Aurora 4X: hits strike a random column of the ArmorGrid and dig down through its layers; damage
## that gets through hits random internal components (weighted by size) and wears down the hull's structure.
## The hull is destroyed when its structure reaches zero.

signal hit_taken(damage: int, penetrating: int)
signal component_destroyed(component: ShipComponent)
signal destroyed

const GROUP := &"combat_hulls"
## Faction that fights everyone (old battlefield automatons).
const DERELICT_FACTION := &"derelict"
## Internal damage a destroyed magazine adds when it cooks off.
const MAGAZINE_EXPLOSION := 6
## Seconds a weapon discharge keeps blooming the signature.
const EMISSION_DECAY := 4.0

@export var display_name: String = ""
## Combat faction. Hulls of different factions are hostile; an empty faction is never targeted.
@export var faction: StringName = Constants.ENEMY_GROUP
## Destroyed hulls free their parent. Off for the player's ship, which many nodes reference.
@export var free_on_destroyed: bool = true
## Hide the whole parent while the player's side has not detected this hull (ships). Off for hulls inside something
## the player can see anyway, like an asteroid emplacement: only the contact marker is hidden.
@export var hide_host_when_undetected: bool = true

@export_category("Armor")
@export var armor: ArmorDefinition
## Total armor mass. Layers = armor_mass / (armor_columns * armor.box_mass).
@export var armor_mass: float = 1.0
## Armor columns: boxes around the hull surface (larger hulls have more columns, so thicker armor costs more).
@export var armor_columns: int = 10

@export_category("Internals")
@export var components: Array[ShipComponent] = []
## Internal damage the hull can take before it breaks up. 0 = the total size of its components, rounded up.
@export var structure: int = 0

@export_category("Profile")
## Radius (px) within which munitions and fragments hit the hull.
@export var hit_radius: float = 6.0

var grid: ArmorGrid
## Armor surface and deck plan that take over from the armor grid when the hull has a ShipInternals child (it sets
## this itself). Null for hulls without one, which keep the Aurora damage model.
var internals: ShipInternals
var host: Node2D
var is_destroyed := false
## Internal damage taken by each component (same order as `components`).
var component_damage: PackedInt32Array
var structure_left: int
var rng := RandomNumberGenerator.new()

var _emission := 0.0
var _flash := 0.0
var _last_position := Vector2.ZERO
var _velocity := Vector2.ZERO


func _ready() -> void:
	host = get_parent() as Node2D
	add_to_group(GROUP)
	rng.randomize()
	if display_name.is_empty() and host:
		display_name = host.name
	# Components are shared resources: damage is tracked per hull in component_damage.
	component_damage = PackedInt32Array()
	component_damage.resize(components.size())
	var columns := maxi(armor_columns, 1)
	grid = ArmorGrid.new(columns, armor.layers_for(armor_mass, columns) if armor else 0)
	if structure <= 0:
		var total := 0.0
		for component in components:
			total += component.size
		structure = maxi(ceili(total), 1)
	structure_left = structure
	_last_position = host.global_position if host else global_position


func _physics_process(delta: float) -> void:
	if not host:
		return
	var position_now := host.global_position
	if delta > 0.0:
		_velocity = (position_now - _last_position) / delta
	_last_position = position_now
	_emission = maxf(_emission - _emission * delta / EMISSION_DECAY, 0.0)
	if _flash > 0.0:
		_flash = maxf(_flash - delta, 0.0)
	queue_redraw()


#region State

func get_world_position() -> Vector2:
	if host is Spaceship:
		return host.get_state_position()
	return host.global_position if host else global_position


func get_world_velocity() -> Vector2:
	if host is Spaceship:
		return host.get_state_velocity()
	if host is RigidBody2D:
		return host.linear_velocity
	return _velocity


func is_hostile_to(other_faction: StringName) -> bool:
	return CombatHull.factions_hostile(faction, other_faction)


static func factions_hostile(a: StringName, b: StringName) -> bool:
	return a != &"" and b != &"" and a != b


## The SensorSuite on the same host (null if it has none: then it can neither see nor be seen).
func get_sensor_suite() -> SensorSuite:
	return SensorSuite.find_on(host)


## Sensor signature of the whole host (see SensorSuite.get_signature).
func get_signature() -> float:
	var suite := get_sensor_suite()
	return suite.get_signature() if suite else _emission


## Signature bloom from recent weapon fire.
func get_emission() -> float:
	return _emission


## Electrical power available to weapons: operational reactors plus any power-generating engines.
func get_power_supply() -> float:
	var power := 0.0
	for i in components.size():
		if components[i].kind == ShipComponent.Kind.REACTOR and is_component_operational(i):
			power += components[i].power_output
	if host is Spaceship and host.main_engine and host.main_engine_online:
		power += maxf(host.main_engine.power_generation, 0.0)
	return power


## Adds a short-lived signature bloom (weapon discharge).
func add_emission(amount: float) -> void:
	_emission += amount


func is_component_operational(index: int) -> bool:
	return index >= 0 and index < components.size() and component_damage[index] < components[index].hit_to_kill


func find_component(component_name: String) -> int:
	for i in components.size():
		if components[i].name == component_name:
			return i
	return -1


func has_kind(kind: ShipComponent.Kind) -> bool:
	for component in components:
		if component.kind == kind:
			return true
	return false


## Operational share (by size) of the components of `kind`; 1 when the hull has none.
func get_operational_fraction(kind: ShipComponent.Kind) -> float:
	var total := 0.0
	var working := 0.0
	for i in components.size():
		if components[i].kind == kind:
			total += components[i].size
			if is_component_operational(i):
				working += components[i].size
	return working / total if total > 0.0 else 1.0


## Can the crew still fight? False once every bridge is destroyed (a hull without a bridge is automated).
func is_in_command() -> bool:
	return not is_destroyed and (not has_kind(ShipComponent.Kind.BRIDGE)
		or get_operational_fraction(ShipComponent.Kind.BRIDGE) > 0.0)


func get_weapons() -> Array[WeaponMount]:
	var weapons: Array[WeaponMount] = []
	for child in get_children():
		if child is WeaponMount:
			weapons.append(child)
	return weapons


func has_railgun() -> bool:
	for weapon in get_weapons():
		if weapon is Railgun:
			return true
	return false

#endregion


#region Damage

## A hit of `damage` points on a random armor column, cratering it in the shape of `profile`. Returns the points
## that penetrated the armor. `direction` is the round's world velocity relative to the hull (zero when unknown): with
## ShipInternals it sets where the round enters and the path it bores through the ship.
func take_hit(damage: int, profile: ArmorGrid.DamageProfile = ArmorGrid.DamageProfile.KINETIC,
		direction: Vector2 = Vector2.ZERO) -> int:
	if is_destroyed or damage <= 0:
		return 0
	_flash = 0.3
	if internals:
		# The internals apply the damage along the round's path themselves.
		var through := internals.resolve_hit(damage, profile, direction)
		hit_taken.emit(damage, through)
		return through
	var penetrating := grid.apply_hit(damage, profile, rng)
	hit_taken.emit(damage, penetrating)
	if penetrating > 0:
		apply_internal_damage(penetrating)
	return penetrating


## Damage that got through the armor: each point hits a random intact component (chance by size) and the structure.
func apply_internal_damage(points: int) -> void:
	if internals:
		internals.apply_internal_damage(points)
		return
	for i in points:
		if is_destroyed:
			return
		structure_left -= 1
		var index := _pick_component()
		if index >= 0:
			component_damage[index] += 1
			if not is_component_operational(index):
				_on_component_destroyed(index)
		if structure_left <= 0:
			_destroy()


func _pick_component() -> int:
	var total := 0.0
	for i in components.size():
		if is_component_operational(i):
			total += components[i].size
	if total <= 0.0:
		return -1
	var roll := rng.randf() * total
	for i in components.size():
		if is_component_operational(i):
			roll -= components[i].size
			if roll <= 0.0:
				return i
	return -1


## Sets a component's damage directly (ShipInternals: hits on its module and crew repairs), taking its system offline
## when it is destroyed and back online when it is repaired.
func set_component_damage(index: int, value: int) -> void:
	if index < 0 or index >= components.size() or is_destroyed:
		return
	var was_operational := is_component_operational(index)
	component_damage[index] = clampi(value, 0, components[index].hit_to_kill)
	var operational := is_component_operational(index)
	if was_operational and not operational:
		_on_component_destroyed(index)
	elif operational and not was_operational:
		_on_component_restored(index)


func _on_component_restored(index: int) -> void:
	var ship := host as Spaceship
	if ship == null:
		return
	match components[index].kind:
		ShipComponent.Kind.MAIN_ENGINE:
			ship.main_engine_online = true
		ShipComponent.Kind.THRUSTERS:
			ship.thrusters_online = true


## Fraction of armor left, on the internals' armor surface when the hull has one.
func get_armor_integrity() -> float:
	return internals.armor.get_integrity() if internals else grid.get_integrity()


## Destroys the hull outright (ShipInternals: once its frame is holed through).
func break_up() -> void:
	_destroy()


func _on_component_destroyed(index: int) -> void:
	var component := components[index]
	var ship := host as Spaceship
	match component.kind:
		ShipComponent.Kind.MAIN_ENGINE:
			if ship and get_operational_fraction(ShipComponent.Kind.MAIN_ENGINE) <= 0.0:
				ship.main_engine_online = false
		ShipComponent.Kind.THRUSTERS:
			if ship and get_operational_fraction(ShipComponent.Kind.THRUSTERS) <= 0.0:
				ship.thrusters_online = false
		ShipComponent.Kind.FUEL_TANK:
			if ship:
				# The tank's share of the remaining fuel vents.
				var before := get_operational_fraction(ShipComponent.Kind.FUEL_TANK) + component.size / _kind_size(ShipComponent.Kind.FUEL_TANK)
				ship.fuel *= get_operational_fraction(ShipComponent.Kind.FUEL_TANK) / maxf(before, 1e-6)
	component_destroyed.emit(component)
	if component.kind == ShipComponent.Kind.MAGAZINE:
		apply_internal_damage(MAGAZINE_EXPLOSION)


func _kind_size(kind: ShipComponent.Kind) -> float:
	var total := 0.0
	for component in components:
		if component.kind == kind:
			total += component.size
	return total


func _destroy() -> void:
	if is_destroyed:
		return
	is_destroyed = true
	destroyed.emit()
	var ship := host as Spaceship
	if ship:
		ship.main_engine_online = false
		ship.thrusters_online = false
		ship.cancel_burn()
	# A wreck left in place keeps its sensor track; a ship that breaks up ends it with the flash.
	CombatExplosion.spawn(host.get_parent(), host.global_position, hit_radius * 6.0, structure,
		"Ship destroyed", get_sensor_suite() if free_on_destroyed else null)
	if free_on_destroyed:
		host.queue_free()

#endregion


func _draw() -> void:
	# Contact marker in screen orientation, kept the same size on screen when zoomed out. The selected contact's
	# brackets and target line are the CombatOverlay's.
	var scale_factor := maxf(1.0, 1.0 / get_canvas_transform().get_scale().x)
	draw_set_transform(Vector2.ZERO, -global_rotation)
	var r := (hit_radius + 4.0) * scale_factor
	var manager := SpaceCombatManager.find(get_tree())
	var player_side := manager.player_faction if manager else Constants.PLAYER_GROUP
	var color := Color(1.0, 0.35, 0.3) if is_hostile_to(player_side) else Color(0.4, 0.9, 1.0)
	if is_destroyed:
		color = Color(0.5, 0.5, 0.5)
	if faction != player_side:
		var diamond := PackedVector2Array([Vector2(r, 0), Vector2(0, r), Vector2(-r, 0), Vector2(0, -r), Vector2(r, 0)])
		draw_polyline(diamond, color, 1.0 * scale_factor)
	if _flash > 0.0:
		draw_circle(Vector2.ZERO, r * 0.8, Color(1.0, 0.9, 0.6, _flash / 0.3 * 0.7))
