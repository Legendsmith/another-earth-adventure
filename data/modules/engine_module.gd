class_name EngineModule
extends ShipModule
## An engine: the main drive (kind MAIN_ENGINE) or the turning and manoeuvring thrusters (kind THRUSTERS). Engines are
## always taken to fire along the hull's axis, through its centre. A hull may carry several: the ship flies on their
## sum (see ShipHull.get_main_drive and get_thrusters). Thrusters are spread over the hull rather than placed in a
## ModularHull's layout; there they weaken as the frame is holed.

## Maximum force produced by the engine.
@export var max_thrust: float
## Effective exhaust velocity in px/s (Isp * g0 in real units).
@export var exhaust_velocity: float
## Mass of the Engine, this is added to the ship's total mass.
@export var mass: float = 1
## Amount of torque provided to the ship when installed as thrusters.
@export var turn_torque: float
## Flame colour the engine produces. Default is orange.
@export var flame_color: Color = Color(1.0, 0.6, 0.2)
## Visual size of the exhaust plume relative to a standard chemical rocket.
@export var flame_size: float = 1.0
##  Amount of electrical power the engine provides to the ship. Only fusion drives will provide positive power generation. Some engines (eg ion drives) will have negative power generation instead.
@export var power_generation: float = 0
## Emissions the engine adds to the ship's sensor signature when ready. This is zero for cold gas systems.
@export var active_sensor_signature: float = 0
## Detectable emission level the engine produces when run at maximum thrust.
@export var max_sensor_signature: float = 1
## Time the engine takes to become ready when started from an offline state. Not yet Implemented
@export var warmup_time: float


func is_thrusters() -> bool:
	return kind == Kind.THRUSTERS


## One engine standing for `engines` firing together, each scaled by its entry in `performance` (0..1): thrust, torque,
## power and signatures add up, the exhaust velocity is the thrust-weighted one (total thrust / total mass flow) and the
## flame is the strongest engine's. Mass counts every engine fitted, working or not. Null when `engines` is empty.
## Writes into `into` when given, so the ship keeps the same object.
static func combine(engines: Array[EngineModule], performance: PackedFloat32Array,
		into: EngineModule = null) -> EngineModule:
	if engines.is_empty():
		return null
	var result := into if into else EngineModule.new()
	var strongest: EngineModule = engines[0]
	var thrust := 0.0
	var flow := 0.0
	result.max_thrust = 0.0
	result.turn_torque = 0.0
	result.mass = 0.0
	result.power_generation = 0.0
	result.active_sensor_signature = 0.0
	result.max_sensor_signature = 0.0
	for i in engines.size():
		var engine := engines[i]
		var share := performance[i] if i < performance.size() else 1.0
		result.mass += engine.mass
		if engine.max_thrust > strongest.max_thrust:
			strongest = engine
		if share <= 0.0:
			continue
		result.max_thrust += engine.max_thrust * share
		result.turn_torque += engine.turn_torque * share
		result.power_generation += engine.power_generation * share
		result.active_sensor_signature += engine.active_sensor_signature * share
		result.max_sensor_signature += engine.max_sensor_signature * share
		if engine.exhaust_velocity > 0.0:
			thrust += engine.max_thrust * share
			flow += engine.max_thrust * share / engine.exhaust_velocity
	result.exhaust_velocity = thrust / flow if flow > 0.0 else strongest.exhaust_velocity
	result.name = strongest.name if engines.size() == 1 else "%s x%d" % [strongest.name, engines.size()]
	result.kind = strongest.kind
	result.flame_color = strongest.flame_color
	result.flame_size = strongest.flame_size
	return result
