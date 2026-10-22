class_name ExpeditionActor
extends CharacterBody2D
## A character on an expedition: the main character, a crewmember, a freed prisoner or an enemy. Its health is a
## MedicalBody, so it bleeds, passes out and can be patched up rather than losing hit points.
##
## Built to run in numbers: off-screen actors think (AI and medical simulation) only every few physics frames,
## staggered by a random tick offset, and catch up on the time they skipped (Expedition Gameplay).

signal went_down(actor: ExpeditionActor)
signal died(actor: ExpeditionActor)

enum Role { PLAYER, CREW, PRISONER, ENEMY }

const PLAYER_FACTION := &"player"
const ENEMY_FACTION := &"enemy"
const SPRITE_CREW := preload("res://texture/soldier_gecko_16.png")
const SPRITE_PLAIN := preload("res://texture/gecko_16.png")
const RADIUS := 16.0
## Seconds between thoughts on screen and off screen.
const THINK_ON_SCREEN := 0.1
const SIGHT_RANGE := 560.0
const INTERACT_RANGE := 72.0
const DASH_SPEED := 1100.0
const DASH_TIME := 0.16
const DASH_COOLDOWN := 1.1
## Loot weight per resource unit (carry capacity is in the same weight units).
const LOOT_WEIGHT := 0.1
const CORE_WEIGHT := 2.0

## Enemy and weapon definitions. damage_type is a MedicalBody.DamageType.
const WEAPONS := {
	&"claws": {"name": "Claws", "melee": true, "damage": 14.0, "type": MedicalBody.DamageType.CUT, "range": 70.0,
		"cooldown": 0.42, "accuracy": 0.9},
	&"knife": {"name": "Knife", "melee": true, "damage": 9.0, "type": MedicalBody.DamageType.CUT, "range": 60.0,
		"cooldown": 0.5, "accuracy": 0.8},
	&"rifle": {"name": "Rifle", "melee": false, "damage": 10.0, "type": MedicalBody.DamageType.PIERCE,
		"range": 650.0, "cooldown": 0.32, "accuracy": 0.6},
	&"pistol": {"name": "Pistol", "melee": false, "damage": 8.0, "type": MedicalBody.DamageType.PIERCE,
		"range": 500.0, "cooldown": 0.45, "accuracy": 0.55},
	&"bandit_rifle": {"name": "Rifle", "melee": false, "damage": 8.0, "type": MedicalBody.DamageType.PIERCE,
		"range": 600.0, "cooldown": 0.6, "accuracy": 0.42},
	&"bite": {"name": "Bite", "melee": true, "damage": 10.0, "type": MedicalBody.DamageType.CUT, "range": 58.0,
		"cooldown": 0.8, "accuracy": 0.75},
	&"void_claw": {"name": "Crystal claw", "melee": true, "damage": 9.0, "type": MedicalBody.DamageType.CUT,
		"range": 60.0, "cooldown": 0.7, "accuracy": 0.75},
	&"ogre_hammer": {"name": "Hammer fists", "melee": true, "damage": 30.0, "type": MedicalBody.DamageType.BLUNT,
		"range": 95.0, "cooldown": 1.6, "accuracy": 0.7, "huge": true, "splash": 70.0},
	&"dl_rifle": {"name": "Military rifle", "melee": false, "damage": 12.0, "type": MedicalBody.DamageType.PIERCE,
		"range": 700.0, "cooldown": 0.38, "accuracy": 0.62},
}
const ENEMY_KINDS := {
	&"bandit": {"name": "Bandit", "weapon": &"bandit_rifle", "speed": 190.0, "hp": 1.0, "color": Color(0.85, 0.45, 0.35),
		"flees": true, "sprite": true},
	&"beast": {"name": "Beast", "weapon": &"bite", "speed": 255.0, "hp": 0.8, "color": Color(0.6, 0.75, 0.3),
		"flees": true, "shape": "beast"},
	&"void_crawler": {"name": "Void crawler", "weapon": &"void_claw", "speed": 225.0, "hp": 0.7,
		"color": Color(0.55, 0.3, 0.85), "flees": false, "shape": "crystal"},
	&"void_ogre": {"name": "Void Ogre", "weapon": &"ogre_hammer", "speed": 140.0, "hp": 3.5,
		"color": Color(0.35, 0.15, 0.55), "flees": false, "shape": "ogre", "radius": 30.0},
	&"dl_trooper": {"name": "Dark Light trooper", "weapon": &"dl_rifle", "speed": 205.0, "hp": 1.3,
		"color": Color(0.25, 0.25, 0.35), "flees": true, "sprite": true, "armor": 0.6},
	&"boarder": {"name": "Boarder", "weapon": &"bandit_rifle", "speed": 195.0, "hp": 1.0,
		"color": Color(0.85, 0.55, 0.3), "flees": true, "sprite": true},
}

var role: Role = Role.CREW
var record: CrewRecord
var body: MedicalBody
var faction: StringName = PLAYER_FACTION
var enemy_kind: StringName = &""
var display_name: String = ""
var color: Color = Color.WHITE
var weapon_id: StringName = &"rifle"
var weapons: Array[StringName] = []
var ammo: int = 120
var dressings: int = 3
var stimulants: int = 1
var painkillers: int = 2
var sedatives: int = 1
var has_oxygen: bool = true
var armor_factor: float = 1.0
var base_speed: float = 210.0
var radius: float = RADIUS
var expedition: Node

var desired_velocity := Vector2.ZERO
var facing := Vector2.RIGHT
var aim_point := Vector2.ZERO
var path := PackedVector2Array()
var path_index: int = 0
var path_goal := Vector2.INF
var target: ExpeditionActor
var cooldown: float = 0.0
var busy_time: float = 0.0
var busy_action: Callable = Callable()
var busy_label: String = ""

## Loot: resource id -> units, plus "cores" and "data".
var carried: Dictionary = {}
var carried_actor: ExpeditionActor
var carried_by: ExpeditionActor

var state: StringName = &"idle"
var home_room: int = -1
var alerted: bool = false
var fleeing: bool = false
var gone: bool = false
## Twitch crewmembers keep speaking for a while after death (last words).
var last_words_until: float = -1.0
var bubble_text: String = ""
var bubble_time: float = 0.0
var remark_cooldown: float = 0.0
var report_cooldown: float = 0.0
var group_leader: ExpeditionActor
var dash_time: float = 0.0
var dash_cooldown: float = 0.0
var dash_direction := Vector2.ZERO
var tick_offset: int = 0
var _think_accumulator: float = 0.0
var _sim_accumulator: float = 0.0
var _activity: float = 0.0
var _was_down := false
var _died_emitted := false
var _steering := false
var _arrive_distance := 24.0
var _anim_time := 0.0
var _sprite: Sprite2D
var rng := RandomNumberGenerator.new()


func setup_crew(crew_record: CrewRecord, as_player: bool) -> void:
	record = crew_record
	body = crew_record.body
	role = Role.PLAYER if as_player else Role.CREW
	faction = PLAYER_FACTION
	display_name = crew_record.get_shown_name()
	color = crew_record.color
	base_speed = 215.0 * crew_record.move_speed_multiplier()
	weapons.clear()
	if as_player:
		weapons.append_array([&"claws", &"pistol"])
	else:
		weapons.append_array([&"rifle", &"knife"])
	weapon_id = weapons[0]


func setup_prisoner(crew_record: CrewRecord) -> void:
	record = crew_record
	body = crew_record.body
	role = Role.PRISONER
	faction = PLAYER_FACTION
	display_name = crew_record.get_shown_name()
	color = crew_record.color
	weapons.clear()
	weapons.append(&"knife")
	weapon_id = &"knife"
	dressings = 0
	stimulants = 0
	ammo = 0
	base_speed = 190.0


func setup_enemy(kind: StringName, config: GameConfig) -> void:
	var def: Dictionary = ENEMY_KINDS[kind]
	role = Role.ENEMY
	faction = ENEMY_FACTION
	enemy_kind = kind
	display_name = def.name
	color = def.color
	weapon_id = def.weapon
	weapons.clear()
	weapons.append(weapon_id)
	base_speed = def.speed
	armor_factor = def.get("armor", 1.0)
	radius = def.get("radius", RADIUS)
	body = MedicalBody.new(config, false, 10.0)
	for part: MedicalBody.Part in body.parts.values():
		part.max_hp *= def.hp
		part.hp = part.max_hp
	ammo = 999


func _ready() -> void:
	rng.randomize()
	tick_offset = rng.randi() % 7
	collision_layer = 2
	collision_mask = 1
	motion_mode = CharacterBody2D.MOTION_MODE_FLOATING
	var shape := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = radius
	shape.shape = circle
	add_child(shape)
	var def: Dictionary = ENEMY_KINDS.get(enemy_kind, {})
	if role != Role.ENEMY or def.get("sprite", false):
		_sprite = Sprite2D.new()
		_sprite.texture = SPRITE_PLAIN if role == Role.ENEMY or role == Role.PRISONER else SPRITE_CREW
		_sprite.hframes = 3
		_sprite.vframes = 4
		_sprite.scale = Vector2(3.0, 3.0)
		_sprite.offset = Vector2(0, -10)
		_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		_sprite.modulate = color.lerp(Color.WHITE, 0.35)
		add_child(_sprite)
	_was_down = is_down()


#region Queries

func is_player() -> bool:
	return role == Role.PLAYER


func is_enemy() -> bool:
	return role == Role.ENEMY


func is_alive() -> bool:
	return not body.dead


## Unconscious, unable to move or fight, or dead: lies on the floor.
func is_down() -> bool:
	return body.dead or not body.is_conscious()


func is_active() -> bool:
	return not gone and not is_down() and carried_by == null


func is_hostile_to(other: ExpeditionActor) -> bool:
	return other != null and other.faction != faction


func get_weapon() -> Dictionary:
	return WEAPONS.get(weapon_id, WEAPONS[&"knife"])


func carry_capacity() -> float:
	if record:
		return record.carry_capacity()
	return 4.0


func carry_weight() -> float:
	var weight := 0.0
	for key: Variant in carried:
		weight += carried[key] * (CORE_WEIGHT if key == "cores" else LOOT_WEIGHT)
	return weight


func carry_free() -> float:
	return maxf(0.0, carry_capacity() - carry_weight())


func get_speed() -> float:
	var speed := base_speed * body.move_multiplier()
	if carried_actor:
		speed *= 0.55
	speed *= lerpf(1.0, 0.7, clampf(carry_weight() / maxf(carry_capacity(), 0.1), 0.0, 1.0))
	return speed


func needs_medical() -> bool:
	if body.dead:
		return false
	return body.total_bleed() > 0.03 or body.cardiac_arrest or not body.is_conscious()


func skill(name: StringName) -> float:
	if record:
		return record.skills.get(name, 0.0)
	return 1.0 if role == Role.ENEMY and enemy_kind == &"dl_trooper" else 0.0


func skill_speed(name: StringName) -> float:
	return record.skill_speed(name) if record else 1.0

#endregion


#region Physics

func _physics_process(delta: float) -> void:
	if gone:
		return
	if carried_by:
		global_position = carried_by.global_position + Vector2(0, -6)
		_simulate(delta, false)
		queue_redraw()
		return
	cooldown = maxf(0.0, cooldown - delta)
	dash_cooldown = maxf(0.0, dash_cooldown - delta)
	bubble_time = maxf(0.0, bubble_time - delta)
	remark_cooldown = maxf(0.0, remark_cooldown - delta)
	report_cooldown = maxf(0.0, report_cooldown - delta)
	var on_screen: bool = expedition.is_near_camera(global_position) if expedition else true
	_simulate(delta, on_screen)
	if busy_time > 0.0 and not is_down():
		busy_time -= delta
		desired_velocity = Vector2.ZERO
		if busy_time <= 0.0 and busy_action.is_valid():
			var action := busy_action
			busy_action = Callable()
			busy_label = ""
			action.call()
	if is_down():
		desired_velocity = Vector2.ZERO
		busy_time = 0.0
	if not is_down() and busy_time <= 0.0:
		_steer()
	if dash_time > 0.0:
		dash_time -= delta
		velocity = dash_direction * DASH_SPEED
	else:
		var speed := get_speed()
		var want := desired_velocity.limit_length(speed)
		velocity = velocity.move_toward(want, speed * 8.0 * delta)
	if velocity.length_squared() > 1.0:
		move_and_slide()
		if desired_velocity.length_squared() > 1.0:
			facing = desired_velocity.normalized()
	_activity = clampf(velocity.length() / 250.0, 0.0, 1.0)
	if target and is_instance_valid(target) and not is_down():
		_activity = maxf(_activity, 0.7)
	_animate(delta)
	queue_redraw()


## Medical simulation and AI, every frame on screen and every few frames off screen, catching up on skipped time.
func _simulate(delta: float, on_screen: bool) -> void:
	_sim_accumulator += delta
	_think_accumulator += delta
	var skip: int = expedition.config.actor_skip_frames if expedition else 3
	if on_screen or (Engine.get_physics_frames() + tick_offset) % (skip + 1) == 0:
		_step_body(_sim_accumulator)
		_sim_accumulator = 0.0
	var interval := THINK_ON_SCREEN if on_screen else THINK_ON_SCREEN * (skip + 1)
	if _think_accumulator >= interval:
		var dt := _think_accumulator
		_think_accumulator = 0.0
		if not gone and not body.dead and carried_by == null:
			think(dt)


func _step_body(dt: float) -> void:
	if body.dead:
		return
	if expedition and expedition.toxic and not has_oxygen and role != Role.ENEMY:
		body.take_damage(0.4 * dt, MedicalBody.DamageType.TOXIC)
	if expedition and expedition.is_lava(global_position):
		body.take_damage(10.0 * dt, MedicalBody.DamageType.BURN, [MedicalBody.LEG_L, MedicalBody.LEG_R][rng.randi() % 2])
	body.step(dt, _activity)
	var down := is_down()
	if down and not _was_down:
		_on_went_down()
	_was_down = down
	if body.dead and not _died_emitted:
		_died_emitted = true
		_on_died()


func _on_went_down() -> void:
	velocity = Vector2.ZERO
	path.clear()
	if carried_actor:
		drop_carried()
	went_down.emit(self)


func _on_died() -> void:
	if carried_actor:
		drop_carried()
	if record and record.is_chat_controlled() and expedition:
		last_words_until = expedition.elapsed + expedition.config.last_words_seconds
	died.emit(self)

#endregion


#region Movement

## Walks toward a world point along a grid path. Returns true when there. The path is followed every physics frame
## (see _steer), so actors that think rarely still turn at each waypoint.
func move_to(point: Vector2, arrive_distance: float = 24.0) -> bool:
	if global_position.distance_to(point) <= arrive_distance:
		stop()
		return true
	if path.is_empty() or path_goal.distance_to(point) > 48.0 or path_index >= path.size():
		path = expedition.find_path(global_position, point) if expedition else PackedVector2Array([point])
		path_goal = point
		path_index = 0
	_arrive_distance = arrive_distance
	_steering = true
	_steer()
	return false


func _steer() -> void:
	if not _steering:
		return
	if global_position.distance_to(path_goal) <= _arrive_distance:
		stop()
		return
	while path_index < path.size() and global_position.distance_to(path[path_index]) < 20.0:
		path_index += 1
	var next: Vector2 = path[path_index] if path_index < path.size() else path_goal
	# An ice wall in the way: break it.
	if expedition and expedition.is_ice(next) and global_position.distance_to(next) < 90.0:
		desired_velocity = Vector2.ZERO
		facing = global_position.direction_to(next)
		if cooldown <= 0.0 and not is_player():
			var weapon := get_weapon()
			cooldown = weapon.cooldown
			expedition.add_swipe(global_position, next, color)
			expedition.damage_ice(next, weapon.damage)
		return
	desired_velocity = global_position.direction_to(next) * get_speed()


func stop() -> void:
	desired_velocity = Vector2.ZERO
	path.clear()
	_steering = false


func dash(direction: Vector2) -> void:
	if dash_cooldown > 0.0 or is_down() or direction == Vector2.ZERO:
		return
	dash_direction = direction.normalized()
	dash_time = DASH_TIME
	dash_cooldown = DASH_COOLDOWN
	body.stamina = maxf(0.0, body.stamina - 15.0)

#endregion


#region Combat

func can_attack(other: ExpeditionActor) -> bool:
	if other == null or other.gone or is_down() or cooldown > 0.0 or busy_time > 0.0:
		return false
	if not body.can_use_weapons():
		return false
	var weapon := get_weapon()
	var distance := global_position.distance_to(other.global_position)
	if distance > weapon.range + other.radius:
		return false
	if not weapon.melee and expedition and not expedition.dungeon.has_line_of_sight(global_position, other.global_position):
		return false
	if not weapon.melee and ammo <= 0:
		return false
	return true


## Attacks another actor with the current weapon. Returns true when the attack was made.
func attack(other: ExpeditionActor) -> bool:
	if not can_attack(other):
		return false
	var weapon := get_weapon()
	facing = global_position.direction_to(other.global_position)
	cooldown = weapon.cooldown / body.handling_multiplier() / (1.0 + skill(CrewRecord.COMBAT) * 0.08)
	body.adrenaline = maxf(body.adrenaline, 55.0)
	if not weapon.melee:
		ammo -= 1
	var chance: float = weapon.accuracy * body.aim_multiplier() * (1.0 + skill(CrewRecord.COMBAT) * 0.07)
	var distance := global_position.distance_to(other.global_position)
	if not weapon.melee:
		chance *= 1.0 - 0.45 * distance / weapon.range
		# Someone lying down is harder to hit with projectiles.
		if other.is_down():
			chance *= 0.5
	var hit := rng.randf() < clampf(chance, 0.05, 0.97)
	var end := other.global_position
	if not hit:
		end += Vector2(rng.randf_range(-40, 40), rng.randf_range(-40, 40))
	if expedition:
		if weapon.melee:
			expedition.add_swipe(global_position, end, color)
		else:
			expedition.add_tracer(global_position + facing * radius, end, Color(1.0, 0.9, 0.5) if faction == PLAYER_FACTION else Color(1.0, 0.45, 0.35))
			expedition.alert_noise(global_position, 700.0, faction)
	if hit:
		other.take_hit(weapon.damage * rng.randf_range(0.8, 1.2), weapon.type, weapon.melee, self, weapon.get("huge", false))
		if record:
			record.train(CrewRecord.COMBAT, 1.0)
	if weapon.has("splash") and expedition:
		for nearby: ExpeditionActor in expedition.actors_near(end, weapon.splash):
			if nearby != other and nearby.faction != faction:
				nearby.take_hit(weapon.damage * 0.5, MedicalBody.DamageType.BLUNT, true, self, false)
		expedition.on_explosion(end, 0.5)
	return true


## A hit lands on this actor. The body part depends on pose: lying down, melee hits find the head and chest.
func take_hit(damage: float, type: MedicalBody.DamageType, melee: bool, attacker: ExpeditionActor = null,
		huge: bool = false) -> void:
	if gone or body.dead:
		return
	var part := body.random_part(is_down(), melee)
	var amount := damage
	if part == MedicalBody.THORAX or part == MedicalBody.ABDOMEN:
		amount *= armor_factor
	body.take_damage(amount, type, part, huge)
	if record:
		record.train(CrewRecord.RESILIENCE, amount * 0.3)
	if attacker and not attacker.gone and is_hostile_to(attacker):
		if target == null or not is_instance_valid(target) or target.is_down():
			target = attacker
		alerted = true
	if expedition:
		expedition.on_actor_hit(self, part, amount, attacker)


func drop_carried() -> void:
	if carried_actor:
		carried_actor.carried_by = null
		carried_actor.global_position = global_position + Vector2(rng.randf_range(-20, 20), 20)
		carried_actor = null


func pick_up(other: ExpeditionActor) -> void:
	if other.carried_by or carried_actor:
		return
	carried_actor = other
	other.carried_by = self
	other.stop()

#endregion


#region Medical aid

## Starts treating a patient (or self). Takes time, faster with Medical skill and slower with injured hands.
func begin_treatment(patient: ExpeditionActor) -> bool:
	if busy_time > 0.0 or is_down() or patient == null or patient.body.dead:
		return false
	if global_position.distance_to(patient.global_position) > INTERACT_RANGE + patient.radius and patient != self:
		return false
	var duration := 4.5 / skill_speed(CrewRecord.MEDICAL) / maxf(body.handling_multiplier(), 0.1)
	busy_time = duration
	busy_label = "Treating %s" % ("self" if patient == self else patient.display_name)
	busy_action = _finish_treatment.bind(patient)
	stop()
	return true


func _finish_treatment(patient: ExpeditionActor) -> void:
	if patient == null or patient.gone or patient.body.dead:
		return
	if global_position.distance_to(patient.global_position) > INTERACT_RANGE * 1.6 + patient.radius and patient != self:
		return
	var treated := false
	if patient.body.cardiac_arrest:
		var ok := patient.body.resuscitate(skill(CrewRecord.MEDICAL))
		if expedition:
			expedition.comms_report(self, "Got a pulse back on %s!" % patient.display_name if ok else "CPR on %s, no pulse yet..." % patient.display_name)
		treated = true
	else:
		var worst: MedicalBody.Part = null
		for part: MedicalBody.Part in patient.body.parts.values():
			if part.bleed > 0.0 and part.dressing <= 0.0 and (worst == null or part.bleed > worst.bleed):
				worst = part
		if worst and dressings > 0:
			dressings -= 1
			patient.body.apply_dressing(worst.id, 0.8 + skill(CrewRecord.MEDICAL) * 0.1)
			treated = true
		if not patient.body.is_conscious() and stimulants > 0 and not patient.body.cardiac_arrest:
			stimulants -= 1
			patient.body.give_stimulant()
			treated = true
	if treated and record:
		record.train(CrewRecord.MEDICAL, 3.0)

#endregion


#region Thinking

func think(dt: float) -> void:
	if is_down():
		_think_down(dt)
		return
	match role:
		Role.PLAYER:
			pass
		Role.ENEMY:
			ExpeditionAI.think_enemy(self, dt)
		_:
			ExpeditionAI.think_crew(self, dt)


func _think_down(_dt: float) -> void:
	stop()
	target = null


## Speech bubble over the head (Twitch chat or a remark). Slurred when the brain is hurt.
func say(text: String, seconds: float = 5.0) -> void:
	var limit: int = expedition.bubble_length() if expedition else 64
	var shown := text.substr(0, limit)
	if body.is_slurred() and not body.dead:
		shown = _slur(shown)
	bubble_text = shown
	bubble_time = seconds


func _slur(text: String) -> String:
	var out := ""
	var severity := clampf((80.0 - body.brain) / 60.0, 0.1, 0.9)
	for i: int in text.length():
		var ch := text[i]
		if ch != " " and rng.randf() < severity * 0.35:
			out += ch + ch if rng.randf() < 0.5 else "~"
		else:
			out += ch
	return out


func remark(text: String) -> void:
	if remark_cooldown > 0.0 or text.is_empty():
		return
	remark_cooldown = 25.0
	say(text, 4.0)
	if expedition:
		expedition.comms_report(self, text, true)

#endregion


#region Drawing

func _animate(delta: float) -> void:
	if _sprite == null:
		return
	var dir := _facing_index()
	if is_down():
		_sprite.rotation = PI / 2.0
		_sprite.frame = [0, 4, 7, 10][dir]
		_sprite.modulate.a = 0.75 if not body.dead else 0.5
		return
	_sprite.rotation = 0.0
	if velocity.length_squared() > 100.0:
		_anim_time += delta * clampf(velocity.length() / 150.0, 0.5, 2.0)
		var cycle := [0, 1, 2, 1]
		_sprite.frame = dir * 3 + cycle[int(_anim_time * 10.0) % 4]
	else:
		_sprite.frame = [0, 4, 7, 10][dir]


func _facing_index() -> int:
	var v := Vector2(facing.x, facing.y * 0.84)
	var angle := v.angle()
	if angle < 0.0:
		angle += TAU
	return int((angle + PI / 4.0) / (PI / 2.0)) % 4


func _draw() -> void:
	var def: Dictionary = ENEMY_KINDS.get(enemy_kind, {})
	var shape: String = def.get("shape", "")
	var alpha := 0.5 if body.dead else 1.0
	if _sprite == null:
		var c := Color(color, alpha)
		match shape:
			"crystal":
				var pts := PackedVector2Array([Vector2(0, -radius * 1.3), Vector2(radius, 0), Vector2(0, radius),
					Vector2(-radius, 0)])
				draw_colored_polygon(pts, c)
				draw_polyline(pts + PackedVector2Array([pts[0]]), Color(0.9, 0.85, 1.0, alpha), 2.0)
			"ogre":
				draw_circle(Vector2.ZERO, radius, c)
				draw_circle(facing.rotated(0.9) * radius, radius * 0.45, c.darkened(0.3))
				draw_circle(facing.rotated(-0.9) * radius, radius * 0.45, c.darkened(0.3))
				draw_circle(facing * radius * 0.5, 4.0, Color(0.9, 0.9, 1.0, alpha))
			_:
				draw_circle(Vector2.ZERO, radius, c)
				draw_circle(facing * radius * 0.8, radius * 0.5, c.darkened(0.25))
	# Health status ring.
	var status := body.get_status()
	var ring: Color = [Color(0.3, 0.9, 0.4), Color(1.0, 0.8, 0.2), Color(1.0, 0.45, 0.1), Color(1.0, 0.1, 0.1), Color(0.4, 0.4, 0.4)][status]
	if role != Role.ENEMY or status > MedicalBody.Status.STABLE:
		draw_arc(Vector2(0, 4), radius + 4.0, 0, TAU, 24, Color(ring, 0.8 * alpha), 2.0)
	if role == Role.PLAYER:
		draw_arc(Vector2(0, 4), radius + 8.0, 0, TAU, 24, Color(1.0, 0.85, 0.3, 0.6), 1.5)
	var font := ThemeDB.fallback_font
	if role != Role.ENEMY or expedition == null or expedition.show_enemy_names:
		var label := display_name
		var size := font.get_string_size(label, HORIZONTAL_ALIGNMENT_CENTER, -1, 13)
		draw_string(font, Vector2(-size.x / 2.0, -radius - 34.0), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 13,
			Color(color.lightened(0.3), alpha))
	if busy_time > 0.0:
		draw_string(font, Vector2(-40, radius + 20.0), busy_label, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.8, 0.9, 1.0))
	if carry_weight() > 0.0:
		draw_rect(Rect2(radius - 4.0, -radius, 10, 10), Color(0.9, 0.75, 0.3))
	if bubble_time > 0.0 and not bubble_text.is_empty():
		var size := font.get_multiline_string_size(bubble_text, HORIZONTAL_ALIGNMENT_LEFT, 220, 13)
		var box := Rect2(Vector2(-size.x / 2.0 - 6.0, -radius - 60.0 - size.y), size + Vector2(12, 8))
		draw_rect(box, Color(0.05, 0.05, 0.1, 0.85))
		draw_rect(box, Color(color, 0.9), false, 1.5)
		draw_multiline_string(font, box.position + Vector2(6, 15), bubble_text, HORIZONTAL_ALIGNMENT_LEFT, 220, 13,
			-1, Color.WHITE)

#endregion
