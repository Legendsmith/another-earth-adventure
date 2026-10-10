class_name SpaceViews
extends Node
## Switches the space view between the orbital map and local space (see SpaceScale): each has its own camera on the
## player's ship, the map one zoomed out over the planet, the local one at world scale where the ship's facing,
## engines and combat show. Drawings check SpaceScale.local_view to pick their detail. M toggles the view by hand.

signal view_changed(local: bool)

const GROUP := &"space_views"

@export var map_camera: SpaceCamera
@export var local_camera: SpaceCamera
@export var start_local: bool = false


static func find(tree: SceneTree) -> SpaceViews:
	return tree.get_first_node_in_group(GROUP) as SpaceViews if tree else null


func _enter_tree() -> void:
	add_to_group(GROUP)


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_local(start_local)


func is_local() -> bool:
	return SpaceScale.local_view


func set_local(local: bool) -> void:
	var changed := local != SpaceScale.local_view
	SpaceScale.local_view = local
	var camera := local_camera if local else map_camera
	if camera:
		camera.enabled = true
		camera.make_current()
	_redraw(get_parent())
	if changed:
		view_changed.emit(local)


func toggle() -> void:
	set_local(not SpaceScale.local_view)


func _unhandled_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key and key.pressed and not key.echo and key.keycode == KEY_M:
		toggle()
		get_viewport().set_input_as_handled()


## Drawings that only redraw on change (planet, debris fields) pick up the new detail level.
func _redraw(node: Node) -> void:
	if node is CanvasItem:
		(node as CanvasItem).queue_redraw()
	for child in node.get_children():
		_redraw(child)
