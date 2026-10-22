class_name ExpeditionAI
extends RefCounted
## Decisions for expedition characters. Crew follow their stance (Expedition Gameplay, Twitch Chat crewmembers):
## Defend escorts the main character, Explore breaks off (in groups for !explore N) and stops at a safe distance from
## enemies, Attack hunts enemies and reports on the fight, Rescue drags the wounded to medics, Medic patches people up
## (the main character and special characters first). Enemies hunt, and most flee when badly hurt.

const DEFEND_RADIUS := 170.0
const DEFEND_LEASH := 380.0
const SAFE_DISTANCE := 500.0
const SELF_DEFENCE := 160.0
const REPORT_INTERVAL := 20.0


#region Crew

static func think_crew(a: ExpeditionActor, _dt: float) -> void:
	var ex: Node = a.expedition
	if ex == null or ex.player == null:
		return
	if a.busy_time > 0.0:
		return
	if a.role == ExpeditionActor.Role.PRISONER:
		_think_prisoner(a)
		return
	if a.carried_actor:
		_carry_to_safety(a)
		return
	var enemy := nearest_visible_enemy(a, ExpeditionActor.SIGHT_RANGE)
	_pick_weapon(a, enemy)
	# Anyone defends themselves at close range.
	if enemy and a.global_position.distance_to(enemy.global_position) < SELF_DEFENCE and a.can_attack(enemy):
		a.attack(enemy)
		return
	if enemy == null:
		a.remark(a.body.remark())
		# Patch yourself up when it is quiet.
		if a.body.total_bleed() > 0.06 and a.dressings > 0 and not ex.enemies_near(a.global_position, 450.0):
			a.begin_treatment(a)
			return
	match a.record.stance if a.record else CrewRecord.Stance.DEFEND:
		CrewRecord.Stance.ATTACK:
			_think_attack(a, enemy)
		CrewRecord.Stance.EXPLORE:
			_think_explore(a, enemy)
		CrewRecord.Stance.RESCUE:
			if not _think_rescue(a):
				_think_medic(a, enemy)
		CrewRecord.Stance.MEDIC:
			_think_medic(a, enemy)
		_:
			_think_defend(a, enemy)


static func _think_prisoner(a: ExpeditionActor) -> void:
	var ex: Node = a.expedition
	if not a.state == &"freed":
		a.stop()
		return
	var enemy := nearest_visible_enemy(a, 220.0)
	if enemy and a.can_attack(enemy):
		a.attack(enemy)
		return
	_follow(a, ex.player, 110.0 + (a.get_index() % 5) * 20.0)


static func _think_defend(a: ExpeditionActor, enemy: ExpeditionActor) -> void:
	var ex: Node = a.expedition
	var player: ExpeditionActor = ex.player
	if enemy and enemy.global_position.distance_to(player.global_position) < DEFEND_LEASH + 150.0:
		if a.global_position.distance_to(player.global_position) < DEFEND_LEASH:
			_engage(a, enemy)
			return
	if not _treat_nearby(a, 260.0, enemy == null):
		_follow(a, player, DEFEND_RADIUS)


static func _think_attack(a: ExpeditionActor, enemy: ExpeditionActor) -> void:
	var ex: Node = a.expedition
	# Retreat when heavily injured.
	if a.body.get_status() >= MedicalBody.Status.CRITICAL or a.body.total_bleed() > 0.3:
		if a.state != &"retreating":
			a.state = &"retreating"
			ex.comms_report(a, "I'm hit bad, falling back!")
		if enemy and a.can_attack(enemy):
			a.attack(enemy)
		_follow(a, ex.player, DEFEND_RADIUS)
		return
	if a.state == &"retreating":
		a.state = &"idle"
	var quarry: ExpeditionActor = enemy if enemy else ex.nearest_known_enemy(a.global_position)
	if quarry == null:
		if a.state == &"fighting":
			a.state = &"idle"
			ex.comms_report(a, "Area clear.")
		_follow(a, ex.player, DEFEND_RADIUS + 60.0)
		return
	if a.state != &"fighting":
		a.state = &"fighting"
		a.report_cooldown = REPORT_INTERVAL
		ex.comms_report(a, "Engaging %s!" % quarry.display_name)
	elif a.report_cooldown <= 0.0:
		a.report_cooldown = REPORT_INTERVAL
		var hostiles: int = ex.enemies_near(a.global_position, 700.0).size()
		ex.comms_report(a, "Still fighting, %d hostile%s left here. %s" % [hostiles, "s" if hostiles != 1 else "",
			a.body.get_status_name()])
	_engage(a, quarry)


static func _think_explore(a: ExpeditionActor, enemy: ExpeditionActor) -> void:
	var ex: Node = a.expedition
	var leader := ex.explore_leader(a) as ExpeditionActor
	# Explorers rescue each other.
	for mate: ExpeditionActor in ex.explore_group_of(a):
		if mate != a and mate.needs_medical() and not mate.body.dead and enemy == null:
			if a.global_position.distance_to(mate.global_position) <= ExpeditionActor.INTERACT_RANGE:
				a.begin_treatment(mate)
			else:
				a.move_to(mate.global_position, ExpeditionActor.INTERACT_RANGE * 0.8)
			return
	if enemy:
		var distance := a.global_position.distance_to(enemy.global_position)
		if a.state != &"contact" and a.report_cooldown <= 0.0:
			a.report_cooldown = 15.0
			var room: DungeonGenerator.Room = ex.dungeon.room_at(enemy.global_position)
			ex.comms_report(a, "Contact: %d %s%s, holding back." % [ex.enemies_near(enemy.global_position, 400.0).size(),
				enemy.display_name, " in room %d" % room.index if room else ""])
		a.state = &"contact"
		if enemy.global_position.distance_to(a.global_position) < SAFE_DISTANCE * 0.6 and a.can_attack(enemy):
			a.attack(enemy)
		elif distance < SAFE_DISTANCE:
			a.move_to(a.global_position + enemy.global_position.direction_to(a.global_position) * 120.0, 10.0)
		else:
			a.stop()
		return
	if a.state == &"contact":
		a.state = &"idle"
	if leader and leader != a:
		_follow(a, leader, 90.0)
		return
	# Full: bring the loot home.
	if a.carry_free() < ExpeditionActor.LOOT_WEIGHT * 5.0:
		a.move_to(ex.entrance_position(), 40.0)
		return
	var loot: Node2D = ex.nearest_loot(a.global_position, 700.0)
	if loot:
		if a.move_to(loot.global_position, 40.0):
			ex.take_loot(a, loot)
		return
	var room: DungeonGenerator.Room = ex.nearest_unexplored_room(a.global_position)
	if room:
		a.move_to(room.world_center(), 60.0)
	elif a.carry_weight() > 0.0:
		a.move_to(ex.entrance_position(), 40.0)
	else:
		_follow(a, ex.player, DEFEND_RADIUS)


## Rescue: carries a downed ally to the nearest medic or the entrance. Returns false when nobody needs rescuing.
static func _think_rescue(a: ExpeditionActor) -> bool:
	var ex: Node = a.expedition
	var best: ExpeditionActor = null
	var best_d := INF
	for ally: ExpeditionActor in ex.allies():
		if ally == a or not ally.is_down() or ally.body.dead or ally.carried_by:
			continue
		if ex.enemies_near(ally.global_position, 250.0).is_empty() or a.record.stance == CrewRecord.Stance.RESCUE:
			var d := a.global_position.distance_to(ally.global_position)
			if d < best_d:
				best_d = d
				best = ally
	if best == null:
		return false
	if best_d <= ExpeditionActor.INTERACT_RANGE:
		a.pick_up(best)
		ex.comms_report(a, "Got %s, moving them out." % best.display_name)
	else:
		a.move_to(best.global_position, ExpeditionActor.INTERACT_RANGE * 0.8)
	return true


static func _carry_to_safety(a: ExpeditionActor) -> void:
	var ex: Node = a.expedition
	var medic := ex.nearest_medic(a.global_position, a) as ExpeditionActor
	var goal: Vector2 = medic.global_position if medic else ex.entrance_position()
	if a.move_to(goal, 70.0) or not ex.enemies_near(a.global_position, 500.0) and a.global_position.distance_to(goal) < 140.0:
		var patient := a.carried_actor
		a.drop_carried()
		if patient and patient.needs_medical() and a.dressings > 0:
			a.begin_treatment(patient)


static func _think_medic(a: ExpeditionActor, enemy: ExpeditionActor) -> void:
	if not _treat_nearby(a, 1400.0, true):
		if enemy and a.global_position.distance_to(enemy.global_position) < 300.0:
			_engage(a, enemy)
		else:
			_follow(a, a.expedition.player, DEFEND_RADIUS)


## Finds the most urgent patient within `radius` (the main character and special characters first) and treats them.
static func _treat_nearby(a: ExpeditionActor, radius: float, allow: bool) -> bool:
	if not allow or (a.dressings <= 0 and a.stimulants <= 0):
		return false
	var ex: Node = a.expedition
	var best: ExpeditionActor = null
	var best_score := -INF
	for ally: ExpeditionActor in ex.allies(true):
		if not ally.needs_medical() or ally.gone:
			continue
		var d := a.global_position.distance_to(ally.global_position)
		if d > radius:
			continue
		var score := ally.body.total_bleed() * 10.0 + (30.0 if ally.body.cardiac_arrest else 0.0)
		score += 8.0 if not ally.body.is_conscious() else 0.0
		if ally.is_player() or (ally.record and ally.record.special):
			score += 20.0
		score -= d / 200.0
		if score > best_score:
			best_score = score
			best = ally
	if best == null:
		return false
	if a.global_position.distance_to(best.global_position) <= ExpeditionActor.INTERACT_RANGE or best == a:
		a.begin_treatment(best)
	else:
		a.move_to(best.global_position, ExpeditionActor.INTERACT_RANGE * 0.7)
	return true


static func _follow(a: ExpeditionActor, leader: ExpeditionActor, distance: float) -> void:
	if leader == null:
		a.stop()
		return
	# Spread followers around the leader so they don't stack.
	var angle := float(a.get_instance_id() % 360) * PI / 180.0
	var spot := leader.global_position + Vector2.from_angle(angle) * distance * 0.6
	if a.global_position.distance_to(leader.global_position) > distance:
		a.move_to(spot, 30.0)
	else:
		a.stop()


static func _engage(a: ExpeditionActor, enemy: ExpeditionActor) -> void:
	var weapon := a.get_weapon()
	var distance := a.global_position.distance_to(enemy.global_position)
	var in_sight: bool = a.expedition.dungeon.has_line_of_sight(a.global_position, enemy.global_position)
	if distance > weapon.range * 0.85 or not in_sight:
		a.move_to(enemy.global_position, weapon.range * 0.5)
	else:
		a.stop()
		a.facing = a.global_position.direction_to(enemy.global_position)
		a.attack(enemy)


static func _pick_weapon(a: ExpeditionActor, enemy: ExpeditionActor) -> void:
	if a.weapons.size() < 2:
		return
	var close := enemy != null and a.global_position.distance_to(enemy.global_position) < 80.0
	if a.ammo <= 0 or close:
		for id: StringName in a.weapons:
			if ExpeditionActor.WEAPONS[id].melee:
				a.weapon_id = id
				return
	for id: StringName in a.weapons:
		if not ExpeditionActor.WEAPONS[id].melee:
			a.weapon_id = id
			return

#endregion


#region Enemies

static func think_enemy(a: ExpeditionActor, _dt: float) -> void:
	var ex: Node = a.expedition
	var def: Dictionary = ExpeditionActor.ENEMY_KINDS[a.enemy_kind]
	if def.get("flees", false) and not a.fleeing and (a.body.get_status() >= MedicalBody.Status.CRITICAL
			or a.body.integrity() < 0.45):
		a.fleeing = true
		a.target = null
	if a.fleeing:
		_flee(a)
		return
	if a.target == null or not is_instance_valid(a.target) or a.target.gone or a.target.body.dead \
			or (a.target.is_down() and a.enemy_kind != &"beast"):
		a.target = _find_prey(a)
	if a.target == null and a.enemy_kind == &"boarder":
		# Boarders push into the ship looking for the crew.
		a.alerted = true
		a.target = _nearest_ally(a)
	if a.target == null:
		_wander(a)
		return
	if not a.alerted:
		a.alerted = true
		ex.alert_room(a)
	var weapon := a.get_weapon()
	var distance := a.global_position.distance_to(a.target.global_position)
	var in_sight: bool = ex.dungeon.has_line_of_sight(a.global_position, a.target.global_position)
	if weapon.melee:
		if distance <= weapon.range + a.target.radius:
			a.stop()
			a.attack(a.target)
		else:
			a.move_to(a.target.global_position, weapon.range * 0.6)
	else:
		if not in_sight or distance > weapon.range * 0.8:
			a.move_to(a.target.global_position, weapon.range * 0.5)
		elif distance < 220.0:
			a.move_to(a.global_position + a.target.global_position.direction_to(a.global_position) * 150.0, 10.0)
			a.attack(a.target)
		else:
			a.stop()
			a.attack(a.target)


static func _find_prey(a: ExpeditionActor) -> ExpeditionActor:
	var ex: Node = a.expedition
	var best: ExpeditionActor = null
	var best_d := INF
	var sight := ExpeditionActor.SIGHT_RANGE * (1.6 if a.alerted else 1.0)
	for ally: ExpeditionActor in ex.allies(true):
		if ally.gone or ally.body.dead or (ally.is_down() and a.enemy_kind != &"beast"):
			continue
		var d := a.global_position.distance_to(ally.global_position)
		if d < best_d and d < sight and (a.alerted and d < 400.0 or ex.dungeon.has_line_of_sight(a.global_position, ally.global_position)):
			best_d = d
			best = ally
	return best


static func _nearest_ally(a: ExpeditionActor) -> ExpeditionActor:
	var best: ExpeditionActor = null
	var best_d := INF
	for ally: ExpeditionActor in a.expedition.allies():
		var d := a.global_position.distance_to(ally.global_position)
		if d < best_d:
			best_d = d
			best = ally
	return best


static func _wander(a: ExpeditionActor) -> void:
	var ex: Node = a.expedition
	if a.path.is_empty() or a.path_index >= a.path.size():
		var room: DungeonGenerator.Room = ex.dungeon.rooms[a.home_room] if a.home_room >= 0 \
			else ex.dungeon.room_at(a.global_position)
		if room and a.rng.randf() < 0.3:
			a.move_to(DungeonGenerator.cell_to_world(room.random_cell(a.rng)), 20.0)
		else:
			a.stop()
	else:
		a.move_to(a.path_goal, 20.0)


static func _flee(a: ExpeditionActor) -> void:
	var ex: Node = a.expedition
	if a.state != &"fleeing":
		a.state = &"fleeing"
		var far: DungeonGenerator.Room = ex.farthest_room_from(ex.player.global_position)
		a.path_goal = far.world_center() if far else a.global_position
		a.path.clear()
	if a.move_to(a.path_goal, 60.0) or (ex.player.global_position.distance_to(a.global_position) > 1400.0
			and not ex.is_near_camera(a.global_position)):
		# Disengaged: gone from the fight.
		ex.despawn(a)

#endregion


## The nearest enemy this actor can see.
static func nearest_visible_enemy(a: ExpeditionActor, max_distance: float) -> ExpeditionActor:
	var ex: Node = a.expedition
	var best: ExpeditionActor = null
	var best_d := max_distance
	for other: ExpeditionActor in ex.actors:
		if other.gone or other.faction == a.faction or other.is_down():
			continue
		var d := a.global_position.distance_to(other.global_position)
		if d < best_d and ex.dungeon.has_line_of_sight(a.global_position, other.global_position):
			best_d = d
			best = other
	return best
