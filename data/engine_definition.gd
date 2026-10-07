class_name EngineDefinition
extends Resource
## Name of the Engine as it appears to the player
@export var name:String = "Engine"
## Maximum force produced by the engine.
@export var max_thrust:float
## Effective exhaust velocity in px/s (Isp * g0 in real units).
@export var exhaust_velocity:float
## Mass of the Engine, this is added to the ship's total mass, it is also a proxy for the size of the engine.
@export var mass:float = 1
## Amount of torque provided to the ship when installed as thrusters.
@export var turn_torque:float
## Flame colour the engine produces. Default is orange.
@export var flame_color: Color = Color(1.0, 0.6, 0.2)
## Visual size of the exhaust plume relative to a standard chemical rocket.
@export var flame_size: float = 1.0
## Time between required maintenance on the engine to maintain top performance. Not yet Implemented
@export var maintenance_interval:float
##  Amount of electrical power the engine provides to the ship. Only fusion drives will provide positive power generation. Some engines (eg ion drives) will have negative power generation instead. Not yet Implemented
@export var power_generation:float = 0
## Emissions the engine adds to the ship's sensor signature when ready. This is zero for cold gas systems. Not yet Implemented
@export var active_sensor_signature:float = 0
## Detectable emission level the engine produces when run at maximum thrust. Not yet Implemented
@export var max_sensor_signature:float = 1
## Time the engine takes to become ready when started from an offline state. Not yet Implemented
@export var warmup_time:float
