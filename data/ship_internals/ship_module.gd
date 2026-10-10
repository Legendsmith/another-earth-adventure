class_name ShipModule
extends Resource
## A system inside a ShipLayout: a solid rectangle of deck cells that crew walk up to and touch to operate or repair.
## Every cell of it a round or blast crosses is one hit, so a round may clip a corner or bore down its whole length.
## When the layout belongs to a CombatHull, the module stands for the hull component named `component_name`. Several
## modules may share a component (a ship has one main drive, built as four engine modules): each carries an equal share
## of the system's performance, and the system only goes offline when all of them are wrecked.

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
## Hits to wreck the module: each cell a round or blast crosses is one hit.
@export var hit_points: int = 10
@export var color: Color = Color(0.45, 0.6, 0.75)
