class_name ShipComponent
extends Resource
## An internal system of a combat hull. Damage that gets through the armor hits components at random, each with a
## chance proportional to its size (Aurora's damage allocation chart), and destroys them once it reaches their
## hit-to-kill rating.

enum Kind { STRUCTURE, MAIN_ENGINE, THRUSTERS, REACTOR, FUEL_TANK, SENSORS, WEAPON, MAGAZINE, CREW, BRIDGE }

const KIND_NAMES := ["Structure", "Main engine", "Thrusters", "Reactor", "Fuel tank", "Sensors", "Weapon",
	"Magazine", "Crew quarters", "Bridge"]

## Name shown on the damage readout. Weapon mounts name the component that runs them (WeaponMount.component_name).
@export var name: String = "Component"
@export var kind: Kind = Kind.STRUCTURE
## Size on the damage allocation chart: larger components are hit more often.
@export var size: float = 1.0
## Hits to kill: internal damage needed to destroy the component.
@export var hit_to_kill: int = 1
## Power produced by a reactor (same units as EngineDefinition.power_generation).
@export var power_output: float = 0.0
