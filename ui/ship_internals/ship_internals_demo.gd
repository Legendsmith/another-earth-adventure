extends Control
## Test bench for the ship internals: the deck plan in a SubViewport, the armor surface beside it, and buttons that
## fire railgun salvoes and torpedoes into the ship. Click a module to repair it and a hole to patch it (standing in
## for the crew, who will do this by touching them).

## A heavy slug, enough to punch through the demo hull's 6-deep armor and on through a few modules.
const RAILGUN_SLUG_DAMAGE := 64
const TORPEDO_DAMAGE := 16

@onready var _view: ShipInternalsView = %ShipInternalsView
@onready var _viewport_container: SubViewportContainer = %ViewportContainer
@onready var _armor: ArmorSurfaceRect = %ArmorSurface
@onready var _status: Label = %Status


func _ready() -> void:
	await get_tree().process_frame
	_armor.bind(_view.internals)
	_view.internals.armor_changed.connect(_update_status)
	_view.internals.breach_patched.connect(func(_cell: Vector2i) -> void: _update_status())
	_view.internals.module_repaired.connect(func(_index: int) -> void: _update_status())
	%RailgunButton.pressed.connect(_fire_railgun)
	%TorpedoButton.pressed.connect(_fire_torpedo)
	%PatchButton.pressed.connect(_patch_all)
	%RepairButton.pressed.connect(_repair_all)
	_viewport_container.gui_input.connect(_on_view_input)
	_update_status()


## Three slugs from one side of the ship, a little spread.
func _fire_railgun() -> void:
	var internals := _view.internals
	var direction := Vector2.from_angle(internals.rng.randf() * TAU)
	for i in 3:
		internals.resolve_hit(RAILGUN_SLUG_DAMAGE, ArmorGrid.DamageProfile.KINETIC,
			direction.rotated(internals.rng.randfn(0.0, 0.05)))


func _fire_torpedo() -> void:
	_view.internals.resolve_hit(TORPEDO_DAMAGE, ArmorGrid.DamageProfile.EXPLOSIVE)


func _patch_all() -> void:
	for cell in _view.internals.breaches.keys():
		_view.internals.patch_breach(cell)


func _repair_all() -> void:
	for i in _view.internals.layout.modules.size():
		while _view.internals.repair_module(i):
			pass


func _on_view_input(event: InputEvent) -> void:
	var click := event as InputEventMouseButton
	if click == null or not click.pressed or click.button_index != MOUSE_BUTTON_LEFT:
		return
	var internals := _view.internals
	var cell := _view.local_to_cell(_view.get_global_transform().affine_inverse() * click.position)
	if not internals.patch_breach(cell):
		var module := internals.get_module_at(cell)
		if module != ShipInternals.NO_MODULE:
			internals.repair_module(module)


func _update_status() -> void:
	var internals := _view.internals
	var lines: PackedStringArray = []
	lines.append("Armor %d%%  (%d holes through)" % [roundi(internals.armor.get_integrity() * 100.0),
		internals.armor.get_hole_count()])
	lines.append("Frame %d%%  breaches: %d to space, %d in walls" % [roundi(internals.get_frame_integrity() * 100.0),
		internals.get_hull_breach_count(), internals.breaches.size() - internals.get_hull_breach_count()])
	for i in internals.layout.modules.size():
		var module := internals.get_module(i)
		var state := "OFFLINE" if not internals.is_module_operational(i) else "%d%%" % roundi(
			internals.get_module_condition(i) * 100.0)
		lines.append("%s: %s" % [module.name, state])
	_status.text = "\n".join(lines)
