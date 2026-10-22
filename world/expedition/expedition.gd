class_name Expedition
extends Node2D
## An expedition on a planet's surface (Expedition Gameplay): an action-adventure dungeon with loot to bring back to
## the entrance, prisoners to free in the lower levels, enemies that trickle back in, and a crew that follows its
## stances (set by Twitch chat or the crew panel). Also runs the intro dungeon and boarding actions on the ship.
##
## Reads Campaign.pending_expedition and reports back with Campaign.finish_expedition.

signal finished(result: Dictionary)
signal comms_line(sender: String, text: String, color: Color, kind: StringName)

enum Mode { EXPEDITION, INTRO, BOARDING }

const PLANET_COLORS := {
	PlanetType.Kind.URBAN: [Color(0.42, 0.42, 0.46), Color(0.18, 0.18, 0.22)],
	PlanetType.Kind.AQUATIC: [Color(0.3, 0.45, 0.5), Color(0.1, 0.2, 0.28)],
	PlanetType.Kind.LAVA: [Color(0.35, 0.27, 0.25), Color(0.15, 0.09, 0.08)],
	PlanetType.Kind.FROZEN: [Color(0.62, 0.7, 0.78), Color(0.3, 0.36, 0.45)],
	PlanetType.Kind.JUNGLE: [Color(0.3, 0.42, 0.25), Color(0.1, 0.2, 0.1)],
	PlanetType.Kind.WASTELAND: [Color(0.55, 0.47, 0.33), Color(0.28, 0.22, 0.14)],
	PlanetType.Kind.TOXIC: [Color(0.4, 0.45, 0.25), Color(0.18, 0.22, 0.1)],
	PlanetType.Kind.MYSTERY: [Color(0.3, 0.28, 0.4), Color(0.1, 0.08, 0.16)],
}
const SHIP_COLORS := [Color(0.38, 0.4, 0.45), Color(0.15, 0.16, 0.2)]
const ICE_HP := 40.0
const TRACER_TIME := 0.12
const EXTRACT_RADIUS := 140.0

@export var show_enemy_names: bool = true
## Keyboard and mouse drive the main character. Off for tests and demos, which steer it themselves.
@export var player_input_enabled: bool = true

var config: GameConfig
var campaign: Node
var site: PlanetSite
var plan: Dictionary = {}
var mode: Mode = Mode.EXPEDITION
var dungeon := DungeonGenerator.new()
var astar := AStarGrid2D.new()
var actors: Array[ExpeditionActor] = []
var player: ExpeditionActor
var loot: Array[LootPile] = []
var deposited := {"fuel": 0.0, "metal": 0.0, "supplies": 0.0, "cores": 0, "data": 0}
var elapsed: float = 0.0
var time_limit: float = 0.0
var eruption: float = 0.0
var eruption_countdown: float = -1.0
var toxic: bool = false
var lava_world: bool = false
## The ship has a working Combat Implant Station: the crew carry its implant.
var implants: bool = false
var is_over: bool = false
var outcome: String = ""
var tile_layer: TileMapLayer
var camera: Camera2D
var hud: Node
var rng := RandomNumberGenerator.new()

var _tracers: Array[Dictionary] = []
var _known_enemies: Dictionary = {}
var _ice_hp: Dictionary = {}
var _trickle_timer: float = 0.0
var _groups_cache: Dictionary = {}
var _groups_time: float = -1.0
var _floor_colors: Array = SHIP_COLORS
var _paused_menu := false


func _ready() -> void:
	campaign = get_node_or_null("/root/Campaign")
	config = campaign.config if campaign else GameConfig.new()
	if campaign and not campaign.active:
		campaign.listen_to_chat = true
		campaign.new_game()
	if campaign:
		plan = campaign.pending_expedition
		site = campaign.star_map.get_site(int(plan.get("site", 0)))
		campaign.crew_said.connect(_on_crew_said)
		campaign.retreat_requested.connect(_on_retreat_requested)
		campaign.stance_changed.connect(_on_stance_changed)
	if site == null:
		site = PlanetSite.generate(0, 1, Vector2.ZERO, PlanetType.Kind.URBAN)
	mode = Mode.INTRO if plan.get("intro", false) else (Mode.BOARDING if plan.get("boarding", false) else Mode.EXPEDITION)
	time_limit = float(plan.get("flyby_seconds", 0.0))
	toxic = PlanetRules.get_rule(site.kind, "needs_oxygen", false) and mode != Mode.BOARDING
	lava_world = PlanetRules.get_rule(site.kind, "eruption", false) and mode != Mode.BOARDING
	if campaign:
		implants = campaign.ship.has_working(ShipModule.Kind.IMPLANT_STATION)
	rng.seed = site.system_seed + (1000 if mode == Mode.BOARDING else 0) + int(campaign.orbital_time if campaign else 0)
	_build_dungeon()
	_build_tiles()
	_build_astar()
	_spawn_party()
	_spawn_loot()
	_spawn_enemies()
	camera = Camera2D.new()
	camera.zoom = Vector2(0.85, 0.85)
	camera.position_smoothing_enabled = true
	add_child(camera)
	camera.global_position = player.global_position
	hud = preload("res://world/expedition/expedition_hud.gd").new()
	hud.expedition = self
	add_child(hud)
	var start_text := {
		Mode.INTRO: "Fight through the facility. Free the prisoners and get to the ship (the pad by the entrance).",
		Mode.BOARDING: "Boarders on the ship! Repel them.",
		Mode.EXPEDITION: "Find loot and bring it back to the entrance pad. Press E on the pad to return to the ship.",
	}
	comms("Ship", start_text[mode], Color(0.6, 0.85, 1.0), &"system")
	if toxic:
		comms("Ship", "Toxic atmosphere: oxygen supply is on.", Color(0.8, 0.9, 0.4), &"system")
	if time_limit > 0.0:
		comms("Ship", "Low flyby: %d seconds before we lose the teleport window." % roundi(time_limit), Color(1.0, 0.7, 0.3), &"system")


#region Building

func _build_dungeon() -> void:
	if mode == Mode.BOARDING:
		dungeon.generate_ship(rng.randi(), 8)
		_floor_colors = SHIP_COLORS
		return
	var room_count := 9 if mode == Mode.INTRO else rng.randi_range(11, 15)
	dungeon.generate(rng.randi(), room_count, Vector2i(64, 48) if mode == Mode.INTRO else Vector2i(76, 56),
		PlanetRules.get_rule(site.kind, "ice_walls", false), lava_world)
	_floor_colors = PLANET_COLORS.get(site.kind, SHIP_COLORS)


func _build_tiles() -> void:
	var tile_set := TileSet.new()
	tile_set.tile_size = Vector2i(DungeonGenerator.CELL_SIZE, DungeonGenerator.CELL_SIZE)
	tile_set.add_physics_layer()
	tile_set.set_physics_layer_collision_layer(0, 1)
	var source := TileSetAtlasSource.new()
	source.texture = _make_tile_texture()
	source.texture_region_size = tile_set.tile_size
	tile_set.add_source(source, 0)
	var half := DungeonGenerator.CELL_SIZE / 2.0
	var square := PackedVector2Array([Vector2(-half, -half), Vector2(half, -half), Vector2(half, half), Vector2(-half, half)])
	for i: int in 4:
		source.create_tile(Vector2i(i, 0))
		if i == DungeonGenerator.Cell.WALL or i == DungeonGenerator.Cell.ICE:
			var data := source.get_tile_data(Vector2i(i, 0), 0)
			data.add_collision_polygon(0)
			data.set_collision_polygon_points(0, 0, square)
	tile_layer = TileMapLayer.new()
	tile_layer.tile_set = tile_set
	tile_layer.z_index = -10
	add_child(tile_layer)
	for x: int in dungeon.size.x:
		for y: int in dungeon.size.y:
			var cell := Vector2i(x, y)
			var value := dungeon.get_cell(cell)
			if value == DungeonGenerator.Cell.WALL and not _touches_floor(cell):
				continue
			tile_layer.set_cell(cell, 0, Vector2i(value, 0))
			if value == DungeonGenerator.Cell.ICE:
				_ice_hp[cell] = ICE_HP


func _touches_floor(cell: Vector2i) -> bool:
	for dx: int in range(-1, 2):
		for dy: int in range(-1, 2):
			if dungeon.get_cell(cell + Vector2i(dx, dy)) != DungeonGenerator.Cell.WALL:
				return true
	return false


## Floor, wall, ice and lava tiles, tinted for the planet.
func _make_tile_texture() -> ImageTexture:
	var s := DungeonGenerator.CELL_SIZE
	var image := Image.create(s * 4, s, false, Image.FORMAT_RGBA8)
	var noise := FastNoiseLite.new()
	noise.seed = site.system_seed
	noise.frequency = 0.08
	var floor_color: Color = _floor_colors[0]
	var wall_color: Color = _floor_colors[1]
	for x: int in s:
		for y: int in s:
			var n := noise.get_noise_2d(x, y) * 0.5 + 0.5
			var edge := x == 0 or y == 0
			image.set_pixel(x, y, floor_color.darkened(0.12 * n + (0.07 if edge else 0.0)))
			var wn := noise.get_noise_2d(x + 300, y) * 0.5 + 0.5
			var rim := x < 4 or y < 4 or x > s - 5 or y > s - 5
			image.set_pixel(x + s, y, wall_color.lightened(0.1 * wn + (0.15 if rim else 0.0)))
			image.set_pixel(x + s * 2, y, Color(0.7, 0.85, 1.0).darkened(0.25 * wn).lerp(Color.WHITE, 0.2 if rim else 0.0))
			var ln := noise.get_noise_2d(x * 2 + 900, y * 2) * 0.5 + 0.5
			image.set_pixel(x + s * 3, y, Color(1.0, 0.35 + 0.4 * ln, 0.05))
	return ImageTexture.create_from_image(image)


func _build_astar() -> void:
	astar.region = Rect2i(Vector2i.ZERO, dungeon.size)
	astar.cell_size = Vector2(DungeonGenerator.CELL_SIZE, DungeonGenerator.CELL_SIZE)
	astar.offset = astar.cell_size / 2.0
	astar.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	astar.update()
	for x: int in dungeon.size.x:
		for y: int in dungeon.size.y:
			var cell := Vector2i(x, y)
			var value := dungeon.get_cell(cell)
			# Ice walls can be broken, so paths may go through them (at a cost).
			astar.set_point_solid(cell, not dungeon.is_walkable(cell) and value != DungeonGenerator.Cell.ICE)
			if value == DungeonGenerator.Cell.LAVA:
				astar.set_point_weight_scale(cell, 12.0)
			elif value == DungeonGenerator.Cell.ICE:
				astar.set_point_weight_scale(cell, 6.0)


func _make_actor() -> ExpeditionActor:
	var actor := ExpeditionActor.new()
	actor.expedition = self
	return actor


func _add_actor(actor: ExpeditionActor, position: Vector2) -> void:
	actor.position = position
	actors.append(actor)
	add_child(actor)
	actor.went_down.connect(_on_actor_down)
	actor.died.connect(_on_actor_died)


func _spawn_party() -> void:
	var entrance := dungeon.rooms[0]
	var members: Array = plan.get("members", [])
	var armored: Array = plan.get("armored", [])
	var records: Array[CrewRecord] = []
	if campaign:
		for id: Variant in members:
			var record: CrewRecord = campaign.get_record(int(id))
			if record:
				records.append(record)
		if mode == Mode.BOARDING:
			records.clear()
			for record: CrewRecord in campaign.active_crew():
				records.append(record)
			records = records.slice(0, config.max_expedition_crew + 1)
	if records.is_empty():
		var hero := CrewRecord.new(config)
		hero.display_name = "Captain"
		hero.is_player = true
		records.append(hero)
	var index := 0
	for record: CrewRecord in records:
		var actor := _make_actor()
		actor.setup_crew(record, record.is_player)
		if mode == Mode.INTRO and record.is_player:
			actor.weapons = [&"claws"]
			actor.weapon_id = &"claws"
		if armored.has(record.id):
			actor.armor_factor = 0.65
		actor.has_oxygen = true
		var spot := entrance.world_center() + Vector2.from_angle(index * 0.9) * (40.0 + 14.0 * index)
		_add_actor(actor, spot)
		if record.is_player:
			player = actor
		index += 1
	if player == null:
		player = actors[0]
		player.role = ExpeditionActor.Role.PLAYER


func _spawn_loot() -> void:
	if mode == Mode.BOARDING:
		return
	var loot_rooms: Array[DungeonGenerator.Room] = []
	for room: DungeonGenerator.Room in dungeon.rooms:
		if room.tag == DungeonGenerator.RoomTag.LOOT or room.tag == DungeonGenerator.RoomTag.LAIR:
			loot_rooms.append(room)
	if loot_rooms.is_empty():
		loot_rooms.append(dungeon.rooms[dungeon.rooms.size() - 1])
	# Spread the planet's resources over crates, deeper rooms holding more.
	for resource: String in ["fuel", "metal", "supplies"]:
		var total: float = site.get(resource)
		if mode == Mode.INTRO:
			total *= 0.35
		var crates := clampi(int(total / 8.0), 1, 8)
		for i: int in crates:
			var room: DungeonGenerator.Room = loot_rooms[rng.randi() % loot_rooms.size()]
			_add_loot(LootPile.Kind.RESOURCE, room, resource, roundf(total / crates))
	for i: int in site.module_cores if mode != Mode.INTRO else 0:
		var room := _deepest_room([DungeonGenerator.RoomTag.LAIR, DungeonGenerator.RoomTag.LOOT])
		_add_loot(LootPile.Kind.CORE, room, "", 1.0)
	for room: DungeonGenerator.Room in dungeon.rooms:
		if room.tag == DungeonGenerator.RoomTag.TERMINAL and mode != Mode.INTRO:
			_add_loot(LootPile.Kind.TERMINAL, room, "", 1.0)
	# Prisoners in the lowest level.
	var prison := _deepest_room([DungeonGenerator.RoomTag.PRISON])
	var count := site.crew if campaign else 3
	if mode == Mode.INTRO:
		count = maxi(count, config.intro_rescued_crew)
	if count > 0 and prison:
		var cell := _add_loot(LootPile.Kind.CELL, prison, "", 0.0)
		var prng := RandomNumberGenerator.new()
		prng.seed = site.system_seed + 77
		for i: int in count:
			var record := CrewRecord.generate(config, prng, 0)
			PlanetRules.apply_crew_bonus(site.kind, record)
			# Captivity takes its toll.
			record.body.stamina = 50.0
			var actor := _make_actor()
			actor.setup_prisoner(record)
			actor.state = &"captive"
			_add_actor(actor, cell.global_position + Vector2(rng.randf_range(-28, 28), rng.randf_range(-28, 28)))
			cell.prisoners.append(actor)
	var surface_metal := float(PlanetRules.get_rule(site.kind, "surface_metal", 0.0))
	if surface_metal > 0.0 and mode == Mode.EXPEDITION:
		comms("Ship", "Scans show metal deposits on the surface.", Color(0.8, 0.8, 0.9), &"system")


func _deepest_room(tags: Array) -> DungeonGenerator.Room:
	var best: DungeonGenerator.Room = null
	for room: DungeonGenerator.Room in dungeon.rooms:
		if tags.has(room.tag) and (best == null or room.depth > best.depth):
			best = room
	if best == null:
		for room: DungeonGenerator.Room in dungeon.rooms:
			if best == null or room.depth > best.depth:
				best = room
	return best


func _add_loot(kind: LootPile.Kind, room: DungeonGenerator.Room, resource: String, amount: float) -> LootPile:
	var pile := LootPile.new()
	pile.kind = kind
	pile.resource = resource
	pile.amount = amount
	var cell := room.random_cell(rng, 1)
	for attempt: int in 10:
		if dungeon.get_cell(cell) == DungeonGenerator.Cell.FLOOR:
			break
		cell = room.random_cell(rng, 1)
	pile.position = DungeonGenerator.cell_to_world(cell)
	pile.z_index = -5
	loot.append(pile)
	add_child(pile)
	return pile


## Enemies for the planet's faction and type: deeper rooms hold more of them.
func _spawn_enemies() -> void:
	if mode == Mode.BOARDING:
		var airlock := dungeon.rooms[dungeon.rooms.size() - 1]
		var boarders := int(plan.get("boarders", 6))
		for i: int in boarders:
			_spawn_enemy(&"boarder", airlock)
		return
	for room: DungeonGenerator.Room in dungeon.rooms:
		if room.index == 0:
			continue
		var count := 0
		match room.tag:
			DungeonGenerator.RoomTag.LAIR:
				count = 3 + room.depth / 2
			DungeonGenerator.RoomTag.PRISON:
				count = 2 + room.depth / 3
			_:
				count = rng.randi_range(0, 1 + room.depth / 3)
		if mode == Mode.INTRO:
			count = mini(count, 2)
		for i: int in count:
			_spawn_enemy(_pick_enemy_kind(room), room)


func _pick_enemy_kind(room: DungeonGenerator.Room) -> StringName:
	var wildlife := float(PlanetRules.get_rule(site.kind, "wildlife", 1.0))
	if mode == Mode.INTRO:
		return &"bandit" if rng.randf() < 0.5 else &"beast"
	match site.faction:
		PlanetSite.Faction.PIRATES:
			return &"beast" if rng.randf() < 0.15 * wildlife else &"bandit"
		PlanetSite.Faction.VOID:
			if room.tag == DungeonGenerator.RoomTag.LAIR and rng.randf() < 0.35:
				return &"void_ogre"
			return &"void_crawler"
		PlanetSite.Faction.DARK_LIGHT:
			return &"dl_trooper" if rng.randf() < 0.8 else &"bandit"
	return &"beast" if rng.randf() < 0.6 * wildlife else &"bandit"


func _spawn_enemy(kind: StringName, room: DungeonGenerator.Room) -> ExpeditionActor:
	var actor := _make_actor()
	actor.setup_enemy(kind, config)
	actor.home_room = room.index
	var cell := room.random_cell(rng, 1)
	_add_actor(actor, DungeonGenerator.cell_to_world(cell))
	return actor

#endregion


#region Per frame

func _physics_process(delta: float) -> void:
	if is_over or _paused_menu:
		return
	elapsed += delta
	_handle_player_input(delta)
	_update_rooms()
	_update_tracers(delta)
	_deposit_loot()
	_check_emergencies()
	_trickle(delta)
	if time_limit > 0.0 and elapsed >= time_limit:
		comms("Ship", "Teleport window closing! Recalling everyone.", Color(1.0, 0.5, 0.3), &"system")
		end_expedition("flyby")
	if eruption_countdown >= 0.0:
		eruption_countdown -= delta
		if eruption_countdown <= 0.0:
			comms("Ship", "Eruption! Emergency teleport!", Color(1.0, 0.4, 0.2), &"system")
			end_expedition("eruption")
	if mode == Mode.BOARDING and enemies_left() == 0:
		comms("Ship", "Boarders repelled!", Color(0.5, 1.0, 0.6), &"system")
		end_expedition("repelled")
	queue_redraw()


func _process(_delta: float) -> void:
	if camera and player:
		camera.global_position = player.global_position


func _handle_player_input(_delta: float) -> void:
	if player == null or player.gone or not player_input_enabled:
		return
	var dir := Vector2.ZERO
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
		dir.y -= 1
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
		dir.y += 1
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
		dir.x -= 1
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
		dir.x += 1
	if player.is_down() or (hud and hud.is_minigame_active()):
		player.desired_velocity = Vector2.ZERO
		return
	if dir != Vector2.ZERO and player.busy_time > 0.0:
		# Moving cancels treatment.
		player.busy_time = 0.0
		player.busy_action = Callable()
	player.desired_velocity = dir.normalized() * player.get_speed()
	player.aim_point = get_global_mouse_position()
	if dir == Vector2.ZERO:
		player.facing = player.global_position.direction_to(player.aim_point)
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) and not (hud and hud.mouse_over_ui()):
		player_attack()


func _unhandled_input(event: InputEvent) -> void:
	if is_over:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_SPACE:
				var dir := player.desired_velocity if player.desired_velocity != Vector2.ZERO else player.facing
				player.dash(dir)
			KEY_E:
				player_interact()
			KEY_Q:
				var i := player.weapons.find(player.weapon_id)
				player.weapon_id = player.weapons[(i + 1) % player.weapons.size()]
				comms("You", "Switched to %s." % player.get_weapon().name, Color(0.8, 0.8, 0.8), &"system")
			KEY_F:
				var patient := _patient_under_mouse()
				if hud:
					hud.open_medical(patient)
			KEY_TAB:
				if hud:
					hud.toggle_comms()
			KEY_ESCAPE:
				if hud:
					hud.toggle_menu()
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			camera.zoom = (camera.zoom * 1.1).clamp(Vector2(0.4, 0.4), Vector2(2.0, 2.0))
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			camera.zoom = (camera.zoom / 1.1).clamp(Vector2(0.4, 0.4), Vector2(2.0, 2.0))
		elif event.button_index == MOUSE_BUTTON_RIGHT and hud:
			var clicked := _actor_at(get_global_mouse_position(), 40.0)
			if clicked and not clicked.is_enemy():
				hud.open_medical(clicked)


func player_attack() -> void:
	if player.cooldown > 0.0 or player.busy_time > 0.0:
		return
	var weapon := player.get_weapon()
	var aim := player.aim_point
	var best: ExpeditionActor = null
	var best_d := INF
	for other: ExpeditionActor in actors:
		if other.gone or other.faction == player.faction or other.body.dead:
			continue
		var to_cursor := other.global_position.distance_to(aim)
		var to_player := other.global_position.distance_to(player.global_position)
		if weapon.melee:
			# Melee hits whatever is in reach towards the cursor.
			var ahead := player.global_position.direction_to(aim).dot(player.global_position.direction_to(other.global_position))
			if to_player <= weapon.range + other.radius and ahead > 0.3 and to_player < best_d:
				best_d = to_player
				best = other
		elif to_cursor < 90.0 + other.radius and to_cursor < best_d:
			best_d = to_cursor
			best = other
	if best:
		player.attack(best)
		return
	# Swing or shoot at nothing (or at ice).
	player.facing = player.global_position.direction_to(aim)
	player.cooldown = weapon.cooldown
	var reach: float = weapon.range if weapon.melee else minf(weapon.range, player.global_position.distance_to(aim))
	var end := player.global_position + player.facing * reach
	if weapon.melee:
		add_swipe(player.global_position, end, player.color)
		_damage_ice(end, weapon.damage)
	elif player.ammo > 0:
		player.ammo -= 1
		add_tracer(player.global_position, end, Color(1.0, 0.9, 0.5))
		_damage_ice(end, weapon.damage)
		alert_noise(player.global_position, 700.0, player.faction)


func player_interact() -> void:
	if player.is_down():
		return
	if player.carried_actor:
		player.drop_carried()
		return
	if player.global_position.distance_to(entrance_position()) < EXTRACT_RADIUS:
		if hud:
			hud.confirm_extract()
		else:
			end_expedition("extracted")
		return
	var best: Node2D = null
	var best_d := ExpeditionActor.INTERACT_RANGE + 30.0
	for pile: LootPile in loot:
		if pile.used:
			continue
		var d := pile.global_position.distance_to(player.global_position)
		if d < best_d:
			best_d = d
			best = pile
	for other: ExpeditionActor in actors:
		if other == player or other.faction != player.faction or other.gone:
			continue
		var d := other.global_position.distance_to(player.global_position)
		if other.is_down() and not other.body.dead and d < best_d:
			best_d = d
			best = other
	if best is LootPile:
		_interact_loot(player, best)
	elif best is ExpeditionActor:
		player.pick_up(best)
		comms("You", "Carrying %s." % best.display_name, Color(0.8, 0.8, 0.8), &"system")


func _interact_loot(actor: ExpeditionActor, pile: LootPile) -> void:
	match pile.kind:
		LootPile.Kind.CELL:
			pile.used = true
			pile.queue_redraw()
			for prisoner: ExpeditionActor in pile.prisoners:
				prisoner.state = &"freed"
				prisoner.say("Thank you! Get us out of here!", 4.0)
			comms(actor.display_name, "Freed %d prisoner%s." % [pile.prisoners.size(), "s" if pile.prisoners.size() != 1 else ""],
				Color(0.6, 1.0, 0.6), &"report")
		LootPile.Kind.TERMINAL:
			pile.used = true
			pile.queue_redraw()
			deposited.data += 1
			comms(actor.display_name, "Downloaded the facility's records: cache locations for the ship log.",
				Color(0.6, 0.9, 1.0), &"report")
		_:
			take_loot(actor, pile)


## Picks up as much of a pile as the actor can carry.
func take_loot(actor: ExpeditionActor, pile: LootPile) -> void:
	if pile.used or not pile.is_pickup():
		return
	if pile.kind == LootPile.Kind.CORE:
		if actor.carry_free() < ExpeditionActor.CORE_WEIGHT:
			if actor.is_player():
				comms("You", "Too heavy, drop something at the entrance first.", Color(1, 0.7, 0.5), &"system")
			return
		actor.carried["cores"] = actor.carried.get("cores", 0) + 1
		pile.used = true
		pile.queue_free()
		loot.erase(pile)
		comms(actor.display_name, "Got a ship module core!", Color(0.6, 0.9, 1.0), &"report")
		return
	var units := floorf(minf(pile.amount, actor.carry_free() / ExpeditionActor.LOOT_WEIGHT))
	if units <= 0.0:
		if actor.is_player():
			comms("You", "Can't carry any more. Bring it to the entrance.", Color(1, 0.7, 0.5), &"system")
		return
	actor.carried[pile.resource] = actor.carried.get(pile.resource, 0.0) + units
	pile.amount -= units
	if not actor.is_player():
		comms(actor.display_name, "Picked up %.0f %s." % [units, pile.resource], Color(0.8, 0.9, 0.7), &"report", true)
	if pile.amount <= 0.0:
		pile.used = true
		pile.queue_free()
		loot.erase(pile)
	else:
		pile.queue_redraw()


func _deposit_loot() -> void:
	var pad := entrance_position()
	for actor: ExpeditionActor in actors:
		if actor.faction != ExpeditionActor.PLAYER_FACTION or actor.gone or actor.carried.is_empty():
			continue
		if actor.global_position.distance_to(pad) < EXTRACT_RADIUS:
			for key: Variant in actor.carried:
				deposited[key] = deposited.get(key, 0) + actor.carried[key]
			actor.carried.clear()
			if not actor.is_player():
				comms(actor.display_name, "Dropped loot at the entrance.", Color(0.8, 0.9, 0.7), &"report", true)


func _update_rooms() -> void:
	if Engine.get_physics_frames() % 10 != 0:
		return
	for actor: ExpeditionActor in actors:
		if actor.faction != ExpeditionActor.PLAYER_FACTION or actor.gone or actor.is_down():
			continue
		var room := dungeon.room_at(actor.global_position)
		if room and not room.explored:
			room.explored = true
			if room.tag == DungeonGenerator.RoomTag.PRISON and not actor.is_player():
				comms(actor.display_name, "Found prisoners in a cell block!", Color(0.6, 1.0, 0.6), &"report")
	# Enemies seen by anyone on the team are known to everyone (shared over the communicator).
	for actor: ExpeditionActor in actors:
		if actor.faction != ExpeditionActor.ENEMY_FACTION or actor.gone or actor.is_down():
			continue
		for ally: ExpeditionActor in actors:
			if ally.faction == ExpeditionActor.PLAYER_FACTION and not ally.is_down() and not ally.gone \
					and ally.global_position.distance_to(actor.global_position) < ExpeditionActor.SIGHT_RANGE \
					and dungeon.has_line_of_sight(ally.global_position, actor.global_position):
				_known_enemies[actor] = elapsed
				break


## Critical player or special characters are teleported out instead of dying; so are chat crew who typed !retreat.
func _check_emergencies() -> void:
	for actor: ExpeditionActor in actors:
		if actor.gone or actor.body.dead or actor.faction != ExpeditionActor.PLAYER_FACTION:
			continue
		var special := actor.is_player() or (actor.record and actor.record.special)
		if special and (actor.body.get_status() == MedicalBody.Status.DYING or not actor.body.is_conscious()):
			teleport_out(actor, "Emergency teleport!")
			if actor.is_player():
				comms("Ship", "The captain is down: emergency teleport. Recalling the team.", Color(1.0, 0.5, 0.3), &"system")
				end_expedition("captain_down")
				return


func _trickle(delta: float) -> void:
	if mode == Mode.BOARDING:
		return
	_trickle_timer += delta
	if _trickle_timer < config.enemy_trickle_seconds:
		return
	_trickle_timer = 0.0
	if enemies_left() > 24:
		return
	# Enemies slowly trickle back into explored rooms out of sight.
	var candidates: Array[DungeonGenerator.Room] = []
	for room: DungeonGenerator.Room in dungeon.rooms:
		if room.index != 0 and room.explored and not is_near_camera(room.world_center()):
			candidates.append(room)
	if candidates.is_empty():
		return
	var room: DungeonGenerator.Room = candidates[rng.randi() % candidates.size()]
	var enemy := _spawn_enemy(_pick_enemy_kind(room), room)
	enemy.alerted = true

#endregion


#region Ending

## Recalls the team to the ship and reports what was recovered. Reasons: extracted, flyby, eruption, captain_down,
## repelled, boarding_lost, abandoned.
func end_expedition(reason: String) -> void:
	if is_over:
		return
	is_over = true
	outcome = reason
	var result := {"fuel": float(deposited.fuel), "metal": float(deposited.metal), "supplies": float(deposited.supplies),
		"cores": int(deposited.cores), "cache_info": int(deposited.data), "completed": true, "reason": reason,
		"rescued_records": []}
	# Everyone still alive is teleported back with whatever they carry.
	for actor: ExpeditionActor in actors:
		if actor.faction != ExpeditionActor.PLAYER_FACTION or actor.body.dead:
			continue
		if actor.role == ExpeditionActor.Role.PRISONER:
			if actor.state == &"freed" or actor.state == &"extracted":
				result.rescued_records.append(actor.record)
			continue
		for key: Variant in actor.carried:
			result[key if key != "data" else "cache_info"] = result.get(key, 0) + actor.carried[key]
	result.crew_rescued = result.rescued_records.size()
	if mode == Mode.BOARDING:
		result.repelled = reason == "repelled"
	finished.emit(result)
	if hud:
		hud.show_summary(result)


## Called by the HUD once the player closes the summary.
func return_to_ship(result: Dictionary) -> void:
	if campaign == null:
		get_tree().quit()
		return
	if mode == Mode.BOARDING:
		campaign.finish_boarding(result)
	else:
		campaign.finish_expedition(result)
	campaign.go_to_phase_scene()


func teleport_out(actor: ExpeditionActor, text: String = "") -> void:
	if actor.gone:
		return
	if actor.carried_actor:
		actor.drop_carried()
	actor.gone = true
	actor.visible = false
	actor.set_physics_process(false)
	actor.collision_layer = 0
	add_tracer(actor.global_position, actor.global_position + Vector2(0, -400), Color(0.5, 0.8, 1.0))
	if text:
		comms(actor.display_name, text, Color(0.5, 0.8, 1.0), &"report")
	# Their loot goes with them.
	for key: Variant in actor.carried:
		deposited[key] = deposited.get(key, 0) + actor.carried[key]
	actor.carried.clear()


func despawn(actor: ExpeditionActor) -> void:
	actor.gone = true
	actor.visible = false
	actor.set_physics_process(false)
	actor.collision_layer = 0

#endregion


#region Events

func _on_actor_down(actor: ExpeditionActor) -> void:
	if actor.faction == ExpeditionActor.PLAYER_FACTION and not actor.is_player():
		comms(actor.display_name, "...", Color(1.0, 0.5, 0.4), &"down")
		comms("Ship", "%s is down (%s)." % [actor.display_name, actor.body.get_status_name()], Color(1.0, 0.5, 0.4), &"system")


func _on_actor_died(actor: ExpeditionActor) -> void:
	if actor.faction == ExpeditionActor.PLAYER_FACTION:
		comms("Ship", "We lost %s." % actor.display_name, Color(1.0, 0.3, 0.3), &"system")
		# Dropped loot stays where they fell.
		for key: Variant in actor.carried:
			if key in ["fuel", "metal", "supplies"]:
				var pile := LootPile.new()
				pile.kind = LootPile.Kind.RESOURCE
				pile.resource = key
				pile.amount = actor.carried[key]
				pile.position = actor.global_position
				pile.z_index = -5
				loot.append(pile)
				add_child(pile)
		actor.carried.clear()


func on_actor_hit(actor: ExpeditionActor, part: StringName, amount: float, _attacker: ExpeditionActor) -> void:
	if actor.is_player() and hud:
		hud.flash_damage(amount)
	if actor.faction == ExpeditionActor.PLAYER_FACTION and amount > 12.0 and not actor.is_player():
		actor.say("Agh! My %s!" % MedicalBody.PART_LABELS.get(part, "body").to_lower(), 2.5)


## Any explosion makes the area less stable (Lava worlds' eruption gauge).
func on_explosion(_position: Vector2, scale: float = 1.0) -> void:
	if not lava_world or eruption_countdown >= 0.0:
		return
	eruption = minf(100.0, eruption + config.eruption_per_explosion * scale)
	if eruption >= 100.0:
		eruption_countdown = config.eruption_countdown_seconds
		comms("Ship", "The ground is giving way! Eruption in %d seconds!" % roundi(eruption_countdown),
			Color(1.0, 0.4, 0.2), &"system")


## Gunfire wakes up enemies within earshot.
func alert_noise(position: Vector2, radius: float, source_faction: StringName) -> void:
	for actor: ExpeditionActor in actors:
		if actor.faction != source_faction and actor.is_enemy() and not actor.alerted and not actor.gone \
				and actor.global_position.distance_to(position) < radius:
			actor.alerted = true


func alert_room(actor: ExpeditionActor) -> void:
	for other: ExpeditionActor in actors:
		if other.is_enemy() and other.home_room == actor.home_room:
			other.alerted = true


func _on_crew_said(record: CrewRecord, text: String) -> void:
	for actor: ExpeditionActor in actors:
		if actor.record == record:
			if actor.body.dead and elapsed > actor.last_words_until:
				return
			actor.say(text)
			comms(actor.display_name, text, actor.color, &"chat")
			return
	# Crew aboard the ship still talk on the communicator.
	comms(record.get_shown_name() + " (ship)", text, record.color, &"chat")


func _on_retreat_requested(record: CrewRecord) -> void:
	for actor: ExpeditionActor in actors:
		if actor.record == record and not actor.gone and not actor.body.dead:
			teleport_out(actor, "Retreating to the ship!")


func _on_stance_changed(record: CrewRecord) -> void:
	for actor: ExpeditionActor in actors:
		if actor.record == record:
			actor.state = &"idle"
			comms(actor.display_name, "Stance: %s%s" % [CrewRecord.STANCE_NAMES[record.stance],
				" (group of %d)" % record.explore_group if record.stance == CrewRecord.Stance.EXPLORE and record.explore_group > 1 else ""],
				actor.color, &"report")
	_groups_time = -1.0


## Communicator line. NPC reports only show when the sender is off screen (unless `always`).
func comms(sender: String, text: String, color: Color = Color.WHITE, kind: StringName = &"report", quiet: bool = false) -> void:
	if quiet and kind == &"report":
		kind = &"minor"
	comms_line.emit(sender, text, color, kind)


func comms_report(actor: ExpeditionActor, text: String, remark: bool = false) -> void:
	if remark and is_near_camera(actor.global_position):
		return
	comms(actor.display_name, text, actor.color, &"report")

#endregion


#region Queries used by the AI and HUD

func find_path(from: Vector2, to: Vector2) -> PackedVector2Array:
	var a := DungeonGenerator.world_to_cell(from)
	var b := DungeonGenerator.world_to_cell(to)
	if not astar.is_in_boundsv(a) or not astar.is_in_boundsv(b):
		return PackedVector2Array()
	if astar.is_point_solid(b):
		b = _nearest_open(b)
	if astar.is_point_solid(a):
		a = _nearest_open(a)
	var points := astar.get_point_path(a, b, true)
	if points.size() > 1:
		points.remove_at(0)
	return points


func _nearest_open(cell: Vector2i) -> Vector2i:
	for radius: int in range(1, 4):
		for dx: int in range(-radius, radius + 1):
			for dy: int in range(-radius, radius + 1):
				var c := cell + Vector2i(dx, dy)
				if astar.is_in_boundsv(c) and not astar.is_point_solid(c):
					return c
	return cell


func is_near_camera(point: Vector2) -> bool:
	if camera == null:
		return true
	var view := get_viewport_rect().size / camera.zoom
	return Rect2(camera.global_position - view / 2.0, view).grow(200.0).has_point(point)


func is_lava(point: Vector2) -> bool:
	return lava_world and dungeon.get_cell(DungeonGenerator.world_to_cell(point)) == DungeonGenerator.Cell.LAVA


func entrance_position() -> Vector2:
	return dungeon.rooms[0].world_center()


func allies(include_down: bool = false) -> Array[ExpeditionActor]:
	var result: Array[ExpeditionActor] = []
	for actor: ExpeditionActor in actors:
		if actor.faction == ExpeditionActor.PLAYER_FACTION and not actor.gone and not actor.body.dead \
				and (include_down or not actor.is_down()) and actor.state != &"captive":
			result.append(actor)
	return result


func enemies_near(point: Vector2, radius: float) -> Array[ExpeditionActor]:
	var result: Array[ExpeditionActor] = []
	for actor: ExpeditionActor in actors:
		if actor.is_enemy() and not actor.gone and not actor.is_down() \
				and actor.global_position.distance_to(point) < radius:
			result.append(actor)
	return result


func enemies_left() -> int:
	var count := 0
	for actor: ExpeditionActor in actors:
		if actor.is_enemy() and not actor.gone and not actor.is_down():
			count += 1
	return count


func actors_near(point: Vector2, radius: float) -> Array[ExpeditionActor]:
	var result: Array[ExpeditionActor] = []
	for actor: ExpeditionActor in actors:
		if not actor.gone and actor.global_position.distance_to(point) < radius:
			result.append(actor)
	return result


func nearest_known_enemy(point: Vector2) -> ExpeditionActor:
	var best: ExpeditionActor = null
	var best_d := INF
	for actor: Variant in _known_enemies.keys():
		if not is_instance_valid(actor) or actor.gone or actor.is_down() or elapsed - _known_enemies[actor] > 30.0:
			_known_enemies.erase(actor)
			continue
		var d: float = actor.global_position.distance_to(point)
		if d < best_d:
			best_d = d
			best = actor
	return best


func nearest_medic(point: Vector2, exclude: ExpeditionActor) -> ExpeditionActor:
	var best: ExpeditionActor = null
	var best_d := INF
	for actor: ExpeditionActor in allies():
		if actor == exclude or actor.record == null or actor.record.stance != CrewRecord.Stance.MEDIC:
			continue
		var d := actor.global_position.distance_to(point)
		if d < best_d:
			best_d = d
			best = actor
	return best


func nearest_loot(point: Vector2, radius: float) -> LootPile:
	var best: LootPile = null
	var best_d := radius
	for pile: LootPile in loot:
		if pile.used or not pile.is_pickup():
			continue
		var d := pile.global_position.distance_to(point)
		if d < best_d and dungeon.has_line_of_sight(point, pile.global_position):
			best_d = d
			best = pile
	return best


func nearest_unexplored_room(point: Vector2) -> DungeonGenerator.Room:
	var best: DungeonGenerator.Room = null
	var best_d := INF
	for room: DungeonGenerator.Room in dungeon.rooms:
		if room.explored:
			continue
		var d := room.world_center().distance_to(point)
		if d < best_d:
			best_d = d
			best = room
	return best


func farthest_room_from(point: Vector2) -> DungeonGenerator.Room:
	var best: DungeonGenerator.Room = null
	var best_d := -1.0
	for room: DungeonGenerator.Room in dungeon.rooms:
		var d := room.world_center().distance_to(point)
		if d > best_d:
			best_d = d
			best = room
	return best


## Explorers band together in groups of the size they asked for (!explore N). The first of a group leads it.
func explore_group_of(actor: ExpeditionActor) -> Array:
	_refresh_groups()
	return _groups_cache.get(actor, [actor])


func explore_leader(actor: ExpeditionActor) -> ExpeditionActor:
	var group := explore_group_of(actor)
	for member: ExpeditionActor in group:
		if member.is_active():
			return member
	return actor


func _refresh_groups() -> void:
	if elapsed - _groups_time < 0.5:
		return
	_groups_time = elapsed
	_groups_cache.clear()
	var by_size := {}
	for actor: ExpeditionActor in actors:
		if actor.record and actor.record.stance == CrewRecord.Stance.EXPLORE and not actor.gone and not actor.body.dead \
				and actor.role == ExpeditionActor.Role.CREW:
			var n: int = maxi(1, actor.record.explore_group)
			if not by_size.has(n):
				by_size[n] = []
			by_size[n].append(actor)
	for n: int in by_size:
		var list: Array = by_size[n]
		for i: int in range(0, list.size(), n):
			var group := list.slice(i, i + n)
			for member: ExpeditionActor in group:
				_groups_cache[member] = group


func _actor_at(point: Vector2, radius: float) -> ExpeditionActor:
	for actor: ExpeditionActor in actors:
		if not actor.gone and actor.global_position.distance_to(point) < radius + actor.radius:
			return actor
	return null


func _patient_under_mouse() -> ExpeditionActor:
	var under := _actor_at(get_global_mouse_position(), 30.0)
	if under and not under.is_enemy() and under.global_position.distance_to(player.global_position) <= ExpeditionActor.INTERACT_RANGE * 1.5:
		return under
	return player


func bubble_length() -> int:
	var settings: Node = get_node_or_null("/root/GameSettings")
	if settings and settings.has_method("get_speech_bubble_length"):
		return settings.get_speech_bubble_length()
	return 64

#endregion


#region Effects

func add_tracer(from: Vector2, to: Vector2, color: Color) -> void:
	_tracers.append({"from": from, "to": to, "color": color, "time": TRACER_TIME})


func add_swipe(from: Vector2, to: Vector2, color: Color) -> void:
	_tracers.append({"from": from.lerp(to, 0.4), "to": to, "color": color.lightened(0.4), "time": TRACER_TIME, "swipe": true})


func _update_tracers(delta: float) -> void:
	for i: int in range(_tracers.size() - 1, -1, -1):
		_tracers[i].time -= delta
		if _tracers[i].time <= 0.0:
			_tracers.remove_at(i)


func is_ice(point: Vector2) -> bool:
	return _ice_hp.has(DungeonGenerator.world_to_cell(point))


func damage_ice(point: Vector2, damage: float) -> void:
	_damage_ice(point, damage)


func _damage_ice(point: Vector2, damage: float) -> void:
	var cell := DungeonGenerator.world_to_cell(point)
	if not _ice_hp.has(cell):
		return
	_ice_hp[cell] -= damage
	if _ice_hp[cell] <= 0.0:
		_ice_hp.erase(cell)
		dungeon.set_cell(cell, DungeonGenerator.Cell.FLOOR)
		tile_layer.set_cell(cell, 0, Vector2i(DungeonGenerator.Cell.FLOOR, 0))
		astar.set_point_solid(cell, false)
		comms("Ship", "An ice wall shatters.", Color(0.7, 0.85, 1.0), &"minor")


func _draw() -> void:
	# The entrance pad, where loot is recovered and the team teleports out.
	var pad := entrance_position()
	draw_circle(pad, EXTRACT_RADIUS, Color(0.3, 0.7, 1.0, 0.12))
	draw_arc(pad, EXTRACT_RADIUS, 0, TAU, 48, Color(0.4, 0.8, 1.0, 0.7), 3.0)
	var font := ThemeDB.fallback_font
	var label := "SHIP" if mode == Mode.INTRO else ("AIRLOCK" if mode == Mode.BOARDING else "TELEPORT PAD")
	draw_string(font, pad + Vector2(-40, -EXTRACT_RADIUS - 8), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(0.6, 0.9, 1.0))
	for tracer: Dictionary in _tracers:
		var alpha: float = tracer.time / TRACER_TIME
		draw_line(tracer.from, tracer.to, Color(tracer.color, alpha), 6.0 if tracer.get("swipe", false) else 2.0)

#endregion
