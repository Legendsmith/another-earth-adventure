class_name ShipModule
extends Resource
## A system inside a ShipLayout: a solid rectangle of deck cells that crew walk up to and touch to operate or repair.
## Railgun rounds that cross it damage it. When the layout belongs to a CombatHull, damage and repairs go to the hull
## component named `component_name`, so a wrecked module takes its system offline.

enum Type {
	## Takes damage up to its hit points, then goes offline until repaired.
	SYSTEM,
	## A compartmentalised tank of liquid: it cannot be knocked out. Each hit loses a little fuel before the tank
	## self-seals (ShipInternals.fuel_loss_per_hit).
	FUEL_TANK,
}

const TYPE_NAMES := ["System", "Fuel tank"]

@export var name: String = "Module"
@export var type: Type = Type.SYSTEM
## Deck cells covered by the module (x along the hull from the stern, y across it).
@export var rect: Rect2i = Rect2i(0, 0, 1, 1)
## ShipComponent.name on the CombatHull this module stands for. Empty = scenery with no effect on combat.
@export var component_name: String = ""
## Hits to destroy when the module has no hull component (otherwise the component's hit_to_kill).
@export var hit_points: int = 1
@export var color: Color = Color(0.45, 0.6, 0.75)
