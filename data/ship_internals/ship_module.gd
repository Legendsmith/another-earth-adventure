class_name ShipModule
extends Resource
## A system inside a ShipLayout: a solid rectangle of deck cells that crew walk up to and touch to operate or repair.
## Railgun rounds that cross it damage it. When the layout belongs to a CombatHull, damage and repairs go to the hull
## component named `component_name`, so a wrecked module takes its system offline.

@export var name: String = "Module"
## Deck cells covered by the module (x along the hull from the stern, y across it).
@export var rect: Rect2i = Rect2i(0, 0, 1, 1)
## ShipComponent.name on the CombatHull this module stands for. Empty = scenery with no effect on combat.
@export var component_name: String = ""
## Hits to destroy when the module has no hull component (otherwise the component's hit_to_kill).
@export var hit_points: int = 1
@export var color: Color = Color(0.45, 0.6, 0.75)
