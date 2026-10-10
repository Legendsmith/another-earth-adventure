class_name CrewBody
extends RigidBody2D
## A crew member aboard the ship: a light physics body in a ShipInternalsView's deck space, tied to a CrewMember of the
## crew manifest (a Twitch chatter).
##
## Built to run by the hundred. The physics engine does the collision work (walls and modules on the same deck, and
## other crew there when ShipCrew.crew_collide is on, see ShipInternalsView.get_deck_layer); every frame the body only steers towards its next waypoint, and its
## decisions (picking a job, pathfinding, working) run once every `skip_frames + 1` physics frames, staggered by a random
## tick offset so the crew spread their thinking over different frames. Idle bodies sleep.
##
## Paths come from ShipInternals.find_path and may ride elevators: stepping onto an elevator whose next waypoint is on
## another deck moves the body to that deck. Jobs (patching holes, repairing modules) are handed out by the ShipCrew.

signal state_changed(state: State)

enum State { IDLE, MOVING, WORKING, SPACED, DEAD }

## Collision radius in deck cells.
const RADIUS_CELLS := 0.3
## Distance (px) at which a waypoint counts as reached.
const ARRIVE_DISTANCE := 3.0
## Thinks without getting closer to the waypoint before the body gives up on its path.
const STUCK_THINKS := 6

static var _placeholder: Texture2D

## Walking speed in deck cells per second.
@export var speed_cells: float = 3.0
## Physics frames skipped between decisions.
@export var skip_frames: int = 8
## Module damage repaired per second of work.
@export var repair_rate: float = 1.0
## Seconds of work to patch a hole.
@export var patch_time: float = 3.0

var member: CrewMember
var crew: ShipCrew
var deck := 0
var state: State = State.IDLE
var path: Array[Vector3i] = []
var path_index := 0
## What the body is doing: {} or {"type": &"module", "index": int} / {"type": &"breach", "cell": Vector3i}.
var job: Dictionary = {}
var tick_offset: int

var _work := 0.0
## Where the current waypoint is, in the view's coordinates.
var _waypoint := Vector2.ZERO
## The crew's jobs_version when this body last looked for work and found none.
var _idle_version := -1
var _best_distance := INF
var _stuck := 0
var _sprite: Sprite2D


func _init() -> void:
	gravity_scale = 0.0
	lock_rotation = true
	linear_damp_mode = RigidBody2D.DAMP_MODE_REPLACE
	linear_damp = 0.0
	can_sleep = true
	mass = 1.0


func _ready() -> void:
	tick_offset = randi() % Engine.physics_ticks_per_second
	var cell_size := crew.view.cell_size if crew and crew.view else 16.0
	var shape := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = cell_size * RADIUS_CELLS
	shape.shape = circle
	add_child(shape)
	_sprite = Sprite2D.new()
	_sprite.texture = _get_placeholder()
	_sprite.scale = Vector2.ONE * (cell_size * RADIUS_CELLS * 2.0) / _sprite.texture.get_width()
	if member and member.color_hex:
		_sprite.modulate = Color.from_string(member.color_hex, Color.WHITE)
	add_child(_sprite)
	set_deck(deck)


## Puts the body on a deck: it collides with that deck only, and shows only while the view shows it.
func set_deck(new_deck: int) -> void:
	deck = new_deck
	if crew and crew.view:
		collision_layer = crew.view.get_crew_layer(deck)
		collision_mask = crew.view.get_deck_layer(deck) | (collision_layer if crew.crew_collide else 0)
		visible = deck == crew.view.deck


func get_cell() -> Vector3i:
	return crew.view.local_to_cell(position, deck)


func get_display_name() -> String:
	return member.display_name if member else name


func is_aboard() -> bool:
	return state != State.SPACED and state != State.DEAD


## Walks to `target` (any deck). Returns false when there is no way there.
func walk_to(target: Vector3i) -> bool:
	var route := crew.internals.find_path(get_cell(), target)
	if route.is_empty():
		return false
	path = route
	path_index = 0
	_waypoint = crew.view.cell_to_local(route[0])
	_best_distance = INF
	_stuck = 0
	_set_state(State.MOVING)
	sleeping = false
	_steer(true)
	return true


## Drops the job and the path.
func stop() -> void:
	if not job.is_empty() and crew:
		crew.release_job(self)
	job = {}
	path.clear()
	linear_velocity = Vector2.ZERO
	if is_aboard():
		_set_state(State.IDLE)


func _physics_process(_delta: float) -> void:
	if not is_aboard() or crew == null:
		return
	var tick := (Engine.get_physics_frames() + tick_offset) % (skip_frames + 1) == 0
	if state == State.MOVING:
		_steer(tick)
	if tick:
		_think((skip_frames + 1) / float(Engine.physics_ticks_per_second))


## Every frame while moving: checks for the next waypoint, riding elevators between decks. The velocity is only set
## when the waypoint changes and on think ticks (to recover from bumping a wall), which keeps the per-frame cost down.
func _steer(tick: bool) -> void:
	if path_index >= path.size():
		_arrive()
		return
	var target := _waypoint
	if position.distance_squared_to(target) <= ARRIVE_DISTANCE * ARRIVE_DISTANCE:
		path_index += 1
		_best_distance = INF
		if path_index >= path.size():
			_arrive()
			return
		var waypoint := path[path_index]
		if waypoint.z != deck:
			# On the elevator: ride it to the waypoint's deck.
			set_deck(waypoint.z)
		_waypoint = crew.view.cell_to_local(waypoint)
		tick = true
	if tick:
		linear_velocity = position.direction_to(_waypoint) * speed_cells * crew.view.cell_size


func _arrive() -> void:
	linear_velocity = Vector2.ZERO
	path.clear()
	if job.is_empty():
		_set_state(State.IDLE)
	else:
		_work = 0.0
		_set_state(State.WORKING)


## Every skip_frames + 1 frames: the decisions.
func _think(elapsed: float) -> void:
	match state:
		State.IDLE:
			# Look for work only when the work on the ship changed since the last fruitless look.
			if crew.auto_jobs and _idle_version != crew.jobs_version:
				_idle_version = crew.jobs_version
				crew.assign_job(self)
		State.MOVING:
			# Give up a path that stopped getting anywhere (a crowd in a doorway, a module placed in the way).
			if path_index < path.size():
				var distance := position.distance_to(_waypoint)
				if distance < _best_distance - 0.5:
					_best_distance = distance
					_stuck = 0
				else:
					_stuck += 1
					if _stuck >= STUCK_THINKS:
						stop()
		State.WORKING:
			_do_work(elapsed)


func _do_work(elapsed: float) -> void:
	var internals := crew.internals
	_work += elapsed
	match job.get("type"):
		&"module":
			var index: int = job.index
			while _work >= 1.0 / repair_rate and internals.module_damage[index] > 0:
				_work -= 1.0 / repair_rate
				internals.repair_module(index)
			if internals.module_damage[index] <= 0:
				stop()
		&"breach":
			if not internals.is_breached(job.cell):
				stop()
			elif _work >= patch_time:
				internals.patch_breach(job.cell)
				stop()
		_:
			stop()


func _set_state(new_state: State) -> void:
	if state == new_state:
		return
	state = new_state
	state_changed.emit(state)


## A shared stand-in sprite (a white disc) until the crew art is in.
static func _get_placeholder() -> Texture2D:
	if _placeholder == null:
		var image := Image.create_empty(16, 16, false, Image.FORMAT_RGBA8)
		for y in 16:
			for x in 16:
				var inside := Vector2(x + 0.5, y + 0.5).distance_to(Vector2(8, 8)) <= 7.5
				image.set_pixel(x, y, Color.WHITE if inside else Color.TRANSPARENT)
		_placeholder = ImageTexture.create_from_image(image)
	return _placeholder
