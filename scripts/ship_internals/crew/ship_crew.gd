class_name ShipCrew
extends Node2D
## The crew aboard a ship: a CrewBody for each member of the crew manifest (the Crew autoload's slots, filled by Twitch
## chatters), living in a ShipInternalsView's deck space. Add it as a child of the view.
##
## It hands out jobs (patch the nearest hole, repair the nearest damaged module) to idle crew, and blows crew out of
## hull breaches: when a hole to space opens, crew on that deck near it may be sucked out (spacing_radius,
## spacing_chance) and become SpacedCrew drifting beside the ship in their suits, which last spaced_survival_time.

signal crew_boarded(body: CrewBody)
signal crew_spaced(body: CrewBody, spaced: SpacedCrew)
signal crew_died(member: CrewMember)

## The view whose decks the crew walk (the parent when left empty).
@export var view: ShipInternalsView
## Follow the crew manifest: a body for every filled crew slot, removed when the member leaves the crew.
@export var follow_roster: bool = true
## Idle crew take jobs on their own.
@export var auto_jobs: bool = true
## Physics frames each crew member skips between decisions.
@export var skip_frames: int = 8
## Crew bump into each other. Off, they walk through each other (only walls stop them), which is much cheaper with
## hundreds aboard and keeps crowds from jamming doorways.
@export var crew_collide: bool = false

@export_group("Spacing")
## Crew within this many cells of a new hole to space, on the same deck, may be sucked out.
@export var spacing_radius: float = 3.0
## Chance of being sucked out within a cell of the hole; it falls off to nothing at spacing_radius.
@export_range(0.0, 1.0, 0.01) var spacing_chance: float = 0.8
## Seconds a space suit keeps a spaced crew member alive. -1 = indefinitely.
@export var spaced_survival_time: float = 1800.0
## Speed (world px/s) a spaced crew member leaves the ship at, on top of the ship's own velocity.
@export var eject_speed: float = 3.0

var internals: ShipInternals
var bodies: Array[CrewBody] = []
var spaced: Array[SpacedCrew] = []
var rng := RandomNumberGenerator.new()

## Job key (a breach's cell, or a module's index) -> the body doing it, so two crew don't take the same job.
var _claims: Dictionary = {}
## Bumped whenever there may be new work on the ship (a hole opens, a module is damaged, an unfinished job is let go),
## so idle crew who found nothing to do only look again when there may be something new.
var jobs_version := 0
## Job keys with nowhere to stand (a hole in the hull behind a module), skipped until the layout changes.
var _unreachable: Dictionary = {}
## user_id -> true for members who are off the ship (spaced or dead), so the roster doesn't put them back aboard.
var _off_ship: Dictionary = {}


func _ready() -> void:
	rng.randomize()
	if view == null:
		view = get_parent() as ShipInternalsView
	if view == null:
		push_warning("ShipCrew needs a ShipInternalsView")
		return
	if not view.is_node_ready():
		await view.ready
	if view.internals and not view.internals.is_node_ready():
		await view.internals.ready
	internals = view.internals
	internals.breach_opened.connect(_on_breach_opened)
	internals.layout_changed.connect(_on_layout_changed)
	view.deck_shown.connect(_on_deck_shown)
	var roster := _roster()
	if follow_roster and roster:
		roster.roster_changed.connect(sync_roster)
		sync_roster()


func _roster() -> Node:
	return get_node_or_null(^"/root/Crew")


## Puts the crew manifest aboard: a body for each filled slot, none for members who left the crew.
func sync_roster() -> void:
	var roster := _roster()
	if roster == null:
		return
	var aboard := {}
	for member: CrewMember in roster.get_crew():
		aboard[member.user_id] = true
		if find_body(member) == null and not _off_ship.has(member.user_id):
			add_crew(member)
	for body in bodies.duplicate():
		if body.member and not aboard.has(body.member.user_id):
			remove_crew(body)


## Brings a member aboard, in the crew quarters if the ship has any. Returns the new body.
func add_crew(member: CrewMember, at: Vector3i = Vector3i(-1, -1, -1)) -> CrewBody:
	if internals == null:
		return null
	if at.x < 0:
		at = _spawn_cell()
	var body := CrewBody.new()
	body.name = "Crew_%s" % (member.login if member and member.login else str(bodies.size()))
	body.member = member
	body.crew = self
	body.skip_frames = skip_frames
	body.deck = at.z
	body.position = view.cell_to_local(at)
	add_child(body)
	bodies.append(body)
	crew_boarded.emit(body)
	return body


func remove_crew(body: CrewBody) -> void:
	body.stop()
	bodies.erase(body)
	body.queue_free()


func find_body(member: CrewMember) -> CrewBody:
	for body in bodies:
		if body.member == member or (body.member and member and body.member.user_id == member.user_id):
			return body
	return null


func _spawn_cell() -> Vector3i:
	var cells := internals.get_zone_cells(ShipRoom.Zone.CREW_QUARTERS)
	if cells.is_empty():
		cells = internals.get_walkable_cells()
	return cells[rng.randi_range(0, cells.size() - 1)] if not cells.is_empty() else Vector3i(1, 1, 0)


#region Jobs

## Gives an idle body the nearest unclaimed job it can reach and starts it walking there. Holes open to space come
## first, then wrecked modules, then other holes and damaged modules.
func assign_job(body: CrewBody) -> bool:
	var from := body.get_cell()
	var jobs: Array = []
	for cell: Vector3i in internals.breaches:
		if _claims.has(cell) or _unreachable.has(cell):
			continue
		var urgent := ShipInternals.is_open_to_space(internals.breaches[cell])
		jobs.append([_distance(from, cell) + (0.0 if urgent else 40.0), {"type": &"breach", "cell": cell, "key": cell}])
	for index in internals.get_module_count():
		if internals.module_damage[index] <= 0 or _claims.has(index) or _unreachable.has(index) \
				or internals.is_fuel_tank(index):
			continue
		var rect := internals.get_module(index).rect
		var centre := Vector3i(rect.get_center().x, rect.get_center().y, internals.get_module_deck(index))
		var score := _distance(from, centre) + (0.0 if not internals.is_module_operational(index) else 20.0)
		jobs.append([score, {"type": &"module", "index": index, "key": index}])
	if jobs.is_empty():
		return false
	jobs.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	# The nearest few: a job nobody can stand next to is struck off until the layout changes.
	for i in mini(jobs.size(), 4):
		var job: Dictionary = jobs[i][1]
		var target := _job_access(job, from)
		if target.x < 0:
			_unreachable[job.key] = true
			continue
		if body.walk_to(target):
			_claims[job.key] = body
			body.job = job
			return true
	return false


func release_job(body: CrewBody) -> void:
	if body.job.has("key") and _claims.get(body.job.key) == body:
		_claims.erase(body.job.key)
		# Unfinished work goes back on the board.
		var unfinished: bool = internals.is_breached(body.job.cell) if body.job.type == &"breach" \
			else internals.module_damage[body.job.index] > 0
		if unfinished:
			_bump_jobs()


func _bump_jobs() -> void:
	jobs_version += 1


## Where to stand for a job: the nearest walkable cell touching the module, or for a hole the hole itself (a hole in
## the deck) or the nearest open cell within two cells of it (crew reach over a module to patch the hull behind it).
## x < 0 when there is none.
func _job_access(job: Dictionary, from: Vector3i) -> Vector3i:
	var options: Array[Vector3i] = []
	if job.type == &"module":
		options = internals.get_access_cells(job.index)
	else:
		var cell: Vector3i = job.cell
		if internals.is_walkable(cell):
			return cell
		for reach in [1, 2]:
			for dy in range(-reach, reach + 1):
				for dx in range(-reach, reach + 1):
					var option := cell + Vector3i(dx, dy, 0)
					if maxi(absi(dx), absi(dy)) == reach and internals.is_walkable(option):
						options.append(option)
			if not options.is_empty():
				break
	var best := Vector3i(-1, -1, -1)
	var best_distance := INF
	for option in options:
		var distance := _distance(from, option)
		if distance < best_distance:
			best_distance = distance
			best = option
	return best


## Rough walking distance: straight line on the deck, plus a detour for every deck between.
func _distance(a: Vector3i, b: Vector3i) -> float:
	return Vector2(a.x - b.x, a.y - b.y).length() + absi(a.z - b.z) * 10.0

#endregion


#region Spacing

func _on_breach_opened(cell: Vector3i, kind: ShipInternals.BreachKind) -> void:
	_bump_jobs()
	if not ShipInternals.is_open_to_space(kind):
		return
	var hole := view.cell_to_local(cell)
	for body in bodies.duplicate():
		if not body.is_aboard() or body.deck != cell.z:
			continue
		var distance: float = body.position.distance_to(hole) / view.cell_size
		if distance > spacing_radius:
			continue
		# Full chance within a cell of the hole, none at spacing_radius.
		var falloff := clampf(inverse_lerp(spacing_radius, 1.0, distance), 0.0, 1.0) if spacing_radius > 1.0 else 1.0
		if rng.randf() < spacing_chance * falloff:
			space_crew(body, cell, kind)


## Blows a crew member out through the hole at `cell`. On a ship in space they drift off beside it; on a standalone
## internals they are just gone from the deck. Returns the spaced crew member.
func space_crew(body: CrewBody, cell: Vector3i, kind: ShipInternals.BreachKind) -> SpacedCrew:
	body.stop()
	body._set_state(CrewBody.State.SPACED)
	bodies.erase(body)
	var drifter := SpacedCrew.new()
	drifter.name = "Spaced_%s" % body.name.trim_prefix("Crew_")
	drifter.member = body.member
	drifter.survival_time = spaced_survival_time
	drifter.skip_frames = skip_frames
	drifter.died.connect(_on_spaced_died)
	if body.member:
		_off_ship[body.member.user_id] = true
	var world := _space_world()
	if world:
		var hull := internals.hull
		var facing := internals.get_hull_facing()
		var outward := _outward(cell, kind).rotated(facing)
		# The hole's place on the hull: the hull's hit circle spans its length.
		var span := hull.hit_radius * 2.0
		var along := ((cell.x + 0.5) / internals.length - 0.5) * span
		var across := ((cell.y + 0.5) / internals.diameter - 0.5) * span * internals.diameter / internals.length
		var at := hull.get_world_position() + Vector2(along, across).rotated(facing)
		var velocity := hull.get_world_velocity() + outward * eject_speed
		drifter.position = SpaceScale.to_map(at)
		drifter.linear_velocity = SpaceScale.to_map(velocity)
		world.add_child(drifter)
		drifter.global_position = SpaceScale.to_map(at)
	else:
		# Nowhere to drift: keep the record (and its air timer) here.
		drifter.freeze = true
		drifter.visible = false
		add_child(drifter)
	spaced.append(drifter)
	crew_spaced.emit(body, drifter)
	body.queue_free()
	return drifter


## Direction (hull frame, +x to the bow) out of the hull through a hole.
func _outward(cell: Vector3i, kind: ShipInternals.BreachKind) -> Vector2:
	if cell.x <= 0:
		return Vector2.LEFT
	if cell.x >= internals.length - 1:
		return Vector2.RIGHT
	if kind == ShipInternals.BreachKind.HULL:
		return Vector2.UP if cell.y < internals.diameter / 2.0 else Vector2.DOWN
	# Out through the top or bottom of the hull: straight up or down out of the plane, drifting a little sideways.
	return Vector2.from_angle(rng.randf() * TAU) * 0.3


## The node space objects live in (the scene root of the hull's world), or null on a standalone internals.
func _space_world() -> Node:
	if internals.hull == null or not internals.hull.is_inside_tree():
		return null
	var world: Node = internals.hull
	while world.get_parent() and not world.get_parent() is Viewport:
		world = world.get_parent()
	return world


func _on_spaced_died(drifter: SpacedCrew) -> void:
	spaced.erase(drifter)
	crew_died.emit(drifter.member)

#endregion


func _on_deck_shown(deck: int) -> void:
	for body in bodies:
		body.visible = body.deck == deck


func _on_layout_changed() -> void:
	# The decks were rebuilt: put everyone back on open deck.
	_claims.clear()
	_unreachable.clear()
	_bump_jobs()
	for body in bodies:
		body.stop()
		var cell := body.get_cell()
		if not internals.is_walkable(cell):
			cell = _spawn_cell()
		body.set_deck(cell.z)
		body.position = view.cell_to_local(cell)
