class_name PlanetRewards
extends Resource
## What a planet hands over when its rewards are collected.

@export var crew:int = 0
@export var items:Dictionary[StringName,int] = {}
@export var resources:Dictionary[StringName,int] = {}


func add_item(id:StringName, amount:int = 1) -> void:
	items[id] = items.get(id, 0) + amount


func add_resource(id:StringName, amount:int) -> void:
	resources[id] = resources.get(id, 0) + amount


func is_empty() -> bool:
	return crew == 0 and items.is_empty() and resources.is_empty()
