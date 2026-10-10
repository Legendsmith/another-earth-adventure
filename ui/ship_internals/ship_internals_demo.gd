extends Control
## Test bench for the ship internals: a deck in a SubViewport with the crew aboard, the armor surface beside it, and
## buttons that fire railgun salvoes and torpedoes into the ship. Crew take jobs on their own (patching holes,
## repairing modules); clicking a module repairs it and clicking a hole patches it too. The crew manifest's members
## board automatically; "Add test crew" brings aboard stand-ins.

## A heavy slug, enough to punch through the demo hull's 6-deep armor and on through a few modules.
const RAILGUN_SLUG_DAMAGE := 64
const TORPEDO_DAMAGE := 16
const TEST_CREW := 20

var _crew: ShipCrew
var _test_crew_count := 0
var _spaced_count := 0
var _dead_count := 0
var _status_wait := 0.0

@onready var _view: ShipInternalsView = %ShipInternalsView
@onready var _viewport_container: SubViewportContainer = %ViewportContainer
@onready var _armor: ArmorSurfaceRect = %ArmorSurface
@onready var _status: Label = %Status


func _ready() -> void:
	await get_tree().process_frame
	_crew = ShipCrew.new()
	_crew.name = "Crew"
	_view.add_child(_crew)
	_crew.crew_spaced.connect(func(_body: CrewBody, _spaced: SpacedCrew) -> void: _spaced_count += 1)
	_crew.crew_died.connect(func(_member: CrewMember) -> void: _dead_count += 1)
	_armor.bind(_view.internals)
	%RailgunButton.pressed.connect(_fire_railgun)
	%TorpedoButton.pressed.connect(_fire_torpedo)
	%PatchButton.pressed.connect(_patch_all)
	%RepairButton.pressed.connect(_repair_all)
	var right: VBoxContainer = %RailgunButton.get_parent()
	_add_button(right, "Add %d test crew" % TEST_CREW, add_test_crew, 0)
	_add_button(right, "Next deck (Tab)", _next_deck, 0)
	_viewport_container.gui_input.connect(_on_view_input)


func _process(delta: float) -> void:
	# A few times a second is plenty for a readout.
	_status_wait -= delta
	if _status_wait <= 0.0:
		_status_wait = 0.25
		_update_status()


func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key and key.pressed and not key.echo and key.keycode == KEY_TAB:
		_next_deck()
		get_viewport().set_input_as_handled()


func add_test_crew(count: int = TEST_CREW) -> void:
	for i in count:
		_test_crew_count += 1
		var member := CrewMember.new()
		member.user_id = "test_%d" % _test_crew_count
		member.login = member.user_id
		member.display_name = "Crew %d" % _test_crew_count
		member.color_hex = "#%s" % Color.from_hsv(randf(), 0.5, 1.0).to_html(false)
		_crew.add_crew(member)


func _next_deck() -> void:
	_view.show_deck((_view.deck + 1) % _view.internals.decks)


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
	for i in _view.internals.get_module_count():
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


func _add_button(parent: Control, text: String, action: Callable, at: int) -> void:
	var button := Button.new()
	button.text = text
	button.pressed.connect(func() -> void: action.call())
	parent.add_child(button)
	parent.move_child(button, at)


func _update_status() -> void:
	var internals := _view.internals
	if internals == null or _crew == null:
		return
	var lines: PackedStringArray = []
	lines.append("Deck %d of %d: %s" % [_view.deck + 1, internals.decks, internals.layout.get_deck(_view.deck).name])
	var working := 0
	for body in _crew.bodies:
		if body.state != CrewBody.State.IDLE:
			working += 1
	lines.append("Crew aboard %d (%d busy), spaced %d, dead %d" % [_crew.bodies.size(), working,
		_spaced_count - _dead_count, _dead_count])
	lines.append("Armor %d%%  (%d holes through)" % [roundi(internals.armor.get_integrity() * 100.0),
		internals.armor.get_hole_count()])
	lines.append("Frame %d%%  breaches: %d to space, %d inside" % [roundi(internals.get_frame_integrity() * 100.0),
		internals.get_hull_breach_count(), internals.breaches.size() - internals.get_hull_breach_count()])
	lines.append("Main drive %d%%  thrusters %d%%  fuel lost %d%%" % [
		roundi(internals.get_main_engine_performance() * 100.0),
		roundi(internals.get_thruster_performance() * 100.0), roundi(internals.fuel_lost * 100.0)])
	for i in internals.get_module_count():
		if internals.is_fuel_tank(i):
			continue
		var module := internals.get_module(i)
		var state := "OFFLINE" if not internals.is_module_operational(i) else "%d%%" % roundi(
			internals.get_module_condition(i) * 100.0)
		lines.append("%s (deck %d): %s" % [module.name, internals.get_module_deck(i) + 1, state])
	var text := "\n".join(lines)
	if _status.text != text:
		_status.text = text
