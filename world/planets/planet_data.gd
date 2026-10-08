class_name PlanetData
extends Resource
## Everything needed to rebuild a generated planet, kept separate from the node so it can be saved.

@export var kind:PlanetType.Kind
@export var radius:float = 32.0
## The part of the shared noise texture this planet's surface is cut from.
@export var region:Rect2
@export var rewards:PlanetRewards
@export var collected:bool = false
