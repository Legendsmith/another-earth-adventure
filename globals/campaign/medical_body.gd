class_name MedicalBody
extends RefCounted
## The body simulation that replaces hit points (Expedition Gameplay, Medical and Hitpoints; inspired by Casualties
## Unknown). Injuries open bleeding wounds and cause pain; blood carries oxygen to the brain; the brain only dies when
## it is starved of oxygen for long enough. Death does not come easily: a character is far more likely to end up
## unconscious and bleeding, waiting for someone to patch them up.
##
## Robots (the Robot trait) use a simpler model: consciousness, body integrity and a battery.
##
## step() takes the time since the last update, so off-screen characters can be updated every few frames.

enum Status { STABLE, BLEEDING, CRITICAL, DYING, DEAD }
enum Awareness { AWAKE, UNCONSCIOUS, COMATOSE }
enum DamageType { BLUNT, PIERCE, CUT, BURN, EXPLOSIVE, ELECTRIC, EMP, TOXIC }

const STATUS_NAMES := ["Stable", "Bleeding", "Critical", "Dying", "Dead"]
const AWARENESS_NAMES := ["Awake", "Unconscious", "Comatose"]

const HEAD := &"head"
const THORAX := &"thorax"
const ABDOMEN := &"abdomen"
const ARM_L := &"arm_l"
const ARM_R := &"arm_r"
const LEG_L := &"leg_l"
const LEG_R := &"leg_r"

## name -> [max hp, chance to be hit standing, pain weight, bleed multiplier]
const PART_DEFS := {
	HEAD: [25.0, 0.10, 1.4, 1.2],
	THORAX: [50.0, 0.28, 1.2, 1.3],
	ABDOMEN: [40.0, 0.20, 1.2, 1.2],
	ARM_L: [30.0, 0.11, 0.8, 0.8],
	ARM_R: [30.0, 0.11, 0.8, 0.8],
	LEG_L: [40.0, 0.10, 0.9, 0.9],
	LEG_R: [40.0, 0.10, 0.9, 0.9],
}
const PART_LABELS := {
	HEAD: "Head", THORAX: "Thorax", ABDOMEN: "Abdomen", ARM_L: "Left arm", ARM_R: "Right arm",
	LEG_L: "Left leg", LEG_R: "Right leg",
}
## Bleeding (litres per minute) opened per point of damage of each type.
const BLEED_PER_DAMAGE := {
	DamageType.BLUNT: 0.006, DamageType.PIERCE: 0.035, DamageType.CUT: 0.045, DamageType.BURN: 0.0,
	DamageType.EXPLOSIVE: 0.03, DamageType.ELECTRIC: 0.0, DamageType.EMP: 0.0, DamageType.TOXIC: 0.0,
}
## Blood oxygen (%) the brain needs in each state of awareness (awake, unconscious/asleep, comatose).
const BRAIN_O2_NEED := [80.0, 70.0, 50.0]
## Brain integrity lost per second per point of blood oxygen below the need.
const BRAIN_DAMAGE_RATE := 0.012
const BRAIN_SLUR_THRESHOLD := 80.0
## Below this, a ship medical bay cannot restore the brain: it needs bionic augmentation.
const BRAIN_MEDBAY_FLOOR := 50.0
const DRESSING_SECONDS := 150.0
## Body part HP a dressing restores per second while it holds.
const DRESSING_HEAL_RATE := 0.12
## Natural healing, as a share of the part's max HP per second.
const NATURAL_HEAL_RATE := 0.0004


class Part:
	extends RefCounted
	var id: StringName
	var max_hp: float
	var hp: float
	## Litres per minute.
	var bleed: float = 0.0
	## Seconds the dressing on this part still holds.
	var dressing: float = 0.0
	var amputated: bool = false
	## Replaced by an augmentation (counts as healthy, costs metal at the medical bay).
	var bionic: bool = false

	func is_disabled() -> bool:
		return amputated or hp <= 0.0

	func damage_fraction() -> float:
		if amputated:
			return 1.0
		return clampf(1.0 - hp / max_hp, 0.0, 1.5)

	func to_dict() -> Dictionary:
		return {"hp": hp, "bleed": bleed, "dressing": dressing, "amputated": amputated, "bionic": bionic,
			"max_hp": max_hp}


var config: GameConfig
var is_robot: bool = false
## Resilience attribute (baseline 10): resists injury, pain and shock.
var resilience: float = 10.0

var parts: Dictionary[StringName, Part] = {}
var blood: float = 5.0
var blood_o2: float = 98.0
var brain: float = 100.0
var pain: float = 0.0
var shock: float = 0.0
var heart_rate: float = 70.0
var adrenaline: float = 0.0
var stamina: float = 100.0
var stimulant: float = 0.0
var painkiller: float = 0.0
var sedative: float = 0.0
var toxin: float = 0.0
## Extra oxygen from a combat implant or an oxygen supply, 0..1 of what breathing can't provide.
var oxygen_support: float = 0.0
var consciousness: float = 100.0
var cardiac_arrest: bool = false
var dead: bool = false
var awareness: Awareness = Awareness.AWAKE

## Robot only.
var battery: float = 100.0
var consciousness_cap: float = 100.0

var rng := RandomNumberGenerator.new()


func _init(game_config: GameConfig = null, robot: bool = false, resilience_attribute: float = 10.0) -> void:
	config = game_config if game_config else GameConfig.new()
	is_robot = robot
	resilience = resilience_attribute
	blood = config.blood_volume
	rng.randomize()
	for id: StringName in PART_DEFS:
		var part := Part.new()
		part.id = id
		part.max_hp = PART_DEFS[id][0]
		part.hp = part.max_hp
		parts[id] = part


#region Simulation

## Advances the body by `dt` seconds at an activity level of 0 (resting) to 1 (sprinting, fighting).
func step(dt: float, activity: float = 0.0) -> void:
	if dead or dt <= 0.0:
		return
	if is_robot:
		_step_robot(dt, activity)
		return
	var effective_activity := activity if awareness == Awareness.AWAKE else 0.0
	_step_wounds(dt)
	_step_blood(dt, effective_activity)
	_step_drugs(dt)
	_step_pain_and_shock(dt, effective_activity)
	_step_heart(dt, effective_activity)
	_step_brain(dt)
	_update_awareness()
	stamina = clampf(stamina + (12.0 - effective_activity * 30.0) * dt, 0.0, 100.0)


func _step_wounds(dt: float) -> void:
	var clot := pow(0.5, dt / config.clot_half_life)
	var healthy := blood_o2 > 85.0
	for part: Part in parts.values():
		if part.bleed > 0.0:
			part.bleed *= clot
			if part.dressing > 0.0:
				# A dressing presses the wound shut quickly.
				part.bleed *= pow(0.5, dt / 6.0)
			if part.bleed < 0.002:
				part.bleed = 0.0
		if part.amputated:
			continue
		if part.dressing > 0.0:
			part.dressing = maxf(0.0, part.dressing - dt)
			part.hp = minf(part.max_hp, part.hp + DRESSING_HEAL_RATE * dt)
		elif healthy and part.bleed <= 0.0:
			part.hp = minf(part.max_hp, part.hp + part.max_hp * NATURAL_HEAL_RATE * dt)


func _step_blood(dt: float, activity: float) -> void:
	# A racing heart pumps blood out faster.
	var pressure := 0.0 if cardiac_arrest else clampf(heart_rate / 80.0, 0.4, 1.8)
	blood = maxf(0.0, blood - total_bleed() * pressure * dt / 60.0)
	blood = minf(config.blood_volume, blood + 0.00012 * dt)
	var volume := blood / config.blood_volume
	var breathing := 1.0 - parts[THORAX].damage_fraction() * 0.45 - toxin / 200.0
	breathing = clampf(breathing + oxygen_support * (1.0 - breathing), 0.0, 1.0)
	var circulation := 0.0 if cardiac_arrest else clampf((volume - 0.35) / 0.45, 0.0, 1.0)
	var target := 99.0 * breathing * circulation - activity * 4.0
	# Oxygen falls quickly when the heart stops and recovers quickly when it beats again.
	var tau := 12.0 if target < blood_o2 else 6.0
	blood_o2 = clampf(lerpf(blood_o2, target, 1.0 - exp(-dt / tau)), 0.0, 100.0)


func _step_drugs(dt: float) -> void:
	stimulant *= exp(-dt / 120.0)
	painkiller *= exp(-dt / 300.0)
	sedative *= exp(-dt / 180.0)
	adrenaline *= exp(-dt / 45.0)
	toxin = maxf(0.0, toxin - 0.05 * dt)
	oxygen_support = maxf(0.0, oxygen_support - dt / 60.0)


func _step_pain_and_shock(dt: float, activity: float) -> void:
	var injury := 0.0
	for part: Part in parts.values():
		if part.bionic:
			continue
		injury += part.damage_fraction() * _def(part.id)[2] * 22.0
		if part.amputated:
			injury += 12.0
	# Using an injured leg hurts.
	injury += activity * (parts[LEG_L].damage_fraction() + parts[LEG_R].damage_fraction()) * 15.0
	injury += toxin * 0.3
	var target := clampf(injury * 10.0 / resilience, 0.0, 100.0)
	var tau := 2.0 if target > pain else 20.0
	pain = lerpf(pain, target, 1.0 - exp(-dt / tau))
	var felt := effective_pain()
	var volume := blood / config.blood_volume
	var shock_gain := maxf(0.0, felt - 55.0) * 0.05 + maxf(0.0, 0.7 - volume) * 12.0
	if shock_gain > 0.0:
		shock += shock_gain * dt * 10.0 / resilience
	else:
		shock -= 1.5 * dt
	shock = clampf(shock, 0.0, 100.0)


func _step_heart(dt: float, activity: float) -> void:
	if cardiac_arrest:
		heart_rate = 0.0
		return
	var volume := blood / config.blood_volume
	var target := 65.0 + activity * 55.0 + adrenaline * 0.5 + stimulant * 0.6 - sedative * 0.4
	target += maxf(0.0, 95.0 - blood_o2) * 0.8 + maxf(0.0, 0.85 - volume) * 160.0
	target = clampf(target, 35.0, 230.0)
	heart_rate = lerpf(heart_rate, target, 1.0 - exp(-dt / 5.0))
	if heart_rate > config.fibrillation_heart_rate:
		var chance := config.fibrillation_chance * (heart_rate - config.fibrillation_heart_rate) / 40.0
		if rng.randf() < chance * dt:
			cardiac_arrest = true
	# Bleeding out stops the heart eventually.
	if volume < 0.4 and rng.randf() < (0.4 - volume) * 0.2 * dt:
		cardiac_arrest = true


func _step_brain(dt: float) -> void:
	var need: float = BRAIN_O2_NEED[awareness]
	if blood_o2 < need:
		brain -= (need - blood_o2) * BRAIN_DAMAGE_RATE * dt
	elif brain > BRAIN_MEDBAY_FLOOR and blood_o2 > 90.0:
		brain = minf(100.0, brain + 0.01 * dt)
	if brain <= 0.0:
		brain = 0.0
		die()


func _update_awareness() -> void:
	var c := 100.0
	c -= maxf(0.0, shock - 40.0) * 1.4
	c -= maxf(0.0, 75.0 - blood_o2) * 2.0
	c -= sedative * 0.9
	c += stimulant * 0.3
	c -= (100.0 - brain) * 0.4
	consciousness = clampf(c, 0.0, 100.0)
	if cardiac_arrest or consciousness < 10.0 or brain < 15.0:
		awareness = Awareness.COMATOSE
	elif consciousness < 35.0:
		awareness = Awareness.UNCONSCIOUS
	else:
		awareness = Awareness.AWAKE


func _step_robot(dt: float, activity: float) -> void:
	battery = maxf(0.0, battery - (0.01 + activity * 0.03) * dt)
	consciousness_cap = minf(100.0, consciousness_cap + 0.05 * dt)
	consciousness = minf(consciousness_cap, consciousness + 2.0 * dt)
	if integrity() <= 0.0 or parts[HEAD].hp <= -parts[HEAD].max_hp:
		die()
		return
	if battery <= 0.0 or consciousness < 30.0:
		awareness = Awareness.UNCONSCIOUS
	else:
		awareness = Awareness.AWAKE


func die() -> void:
	dead = true
	cardiac_arrest = not is_robot
	heart_rate = 0.0
	awareness = Awareness.COMATOSE

#endregion


#region Injury and treatment

## Picks the body part a hit lands on. A character lying down is harder to hit with projectiles but melee hits land on
## the head and chest more often.
func random_part(lying_down: bool = false, melee: bool = false) -> StringName:
	var ids: Array[StringName] = []
	var weights := PackedFloat32Array()
	for id: StringName in parts:
		var part := parts[id]
		if part.amputated:
			continue
		var weight: float = _def(id)[1]
		if lying_down and melee and (id == HEAD or id == THORAX):
			weight *= 2.5
		ids.append(id)
		weights.append(weight)
	if ids.is_empty():
		return THORAX
	return ids[rng.rand_weighted(weights)]


## Applies a hit. `huge` hits (big explosions, huge enemies) can take off a limb. Returns the part hit.
func take_damage(amount: float, type: DamageType = DamageType.BLUNT, part_id: StringName = &"", huge: bool = false) -> StringName:
	if dead or amount <= 0.0:
		return part_id
	if part_id.is_empty() or not parts.has(part_id) or parts[part_id].amputated:
		part_id = random_part()
	var part := parts[part_id]
	if is_robot:
		_robot_damage(part, amount, type)
		return part_id
	if type == DamageType.TOXIC:
		toxin = minf(100.0, toxin + amount)
		return part_id
	amount *= 10.0 / resilience
	part.hp -= amount
	part.bleed += amount * BLEED_PER_DAMAGE.get(type, 0.01) * _def(part_id)[3]
	pain = minf(100.0, pain + amount * 1.2 * 10.0 / resilience)
	adrenaline = minf(100.0, adrenaline + amount * 2.0)
	if huge and part_id in [ARM_L, ARM_R, LEG_L, LEG_R] and part.hp <= -part.max_hp * 0.5:
		amputate(part_id)
	elif part_id == HEAD and part.hp < 0.0:
		# Trauma to the head goes straight to the brain.
		brain = maxf(0.0, brain + part.hp * 1.5)
		part.hp = 0.0
		if brain <= 0.0:
			die()
	part.hp = maxf(part.hp, -part.max_hp)
	return part_id


func amputate(part_id: StringName) -> void:
	var part := parts[part_id]
	part.amputated = true
	part.hp = 0.0
	part.bleed += 0.6
	part.dressing = 0.0
	pain = 100.0


func _robot_damage(part: Part, amount: float, type: DamageType) -> void:
	match type:
		DamageType.ELECTRIC:
			battery = maxf(0.0, battery - amount * 3.0)
		DamageType.EMP:
			consciousness_cap = maxf(0.0, consciousness_cap - amount)
			consciousness = maxf(0.0, consciousness - amount * 2.0)
		DamageType.TOXIC:
			pass
		_:
			part.hp = maxf(-part.max_hp, part.hp - amount * 10.0 / resilience)


## A wound dressing on the part: stops most bleeding and heals the part while it holds. Quality scales its duration.
func apply_dressing(part_id: StringName, quality: float = 1.0) -> void:
	var part := parts.get(part_id) as Part
	if part == null:
		return
	part.dressing = DRESSING_SECONDS * quality
	part.bleed *= 0.35


## Stimulants decrease pain and increase consciousness and heart rate.
func give_stimulant(dose: float = 50.0) -> void:
	stimulant = minf(100.0, stimulant + dose)
	painkiller = minf(100.0, painkiller + dose * 0.4)
	shock = maxf(0.0, shock - dose * 0.5)


func give_painkiller(dose: float = 50.0) -> void:
	painkiller = minf(100.0, painkiller + dose)


func give_sedative(dose: float = 50.0) -> void:
	sedative = minf(100.0, sedative + dose)


## CPR and a stimulant to restart a stopped heart. Returns whether it worked.
func resuscitate(medical_skill: float) -> bool:
	if dead or not cardiac_arrest:
		return not dead
	var chance := config.resuscitation_chance + config.resuscitation_chance_per_skill * medical_skill
	if rng.randf() < chance:
		cardiac_arrest = false
		heart_rate = 90.0
		give_stimulant(30.0)
		return true
	return false


## The combat implant: stimulants, painkillers and oxygenated blood in a dire situation.
func implant_injection() -> void:
	give_stimulant(40.0)
	give_painkiller(40.0)
	oxygen_support = 1.0
	blood_o2 = maxf(blood_o2, 85.0)

#endregion


#region Ship medical bay

## Heals `points` of damage at the medical bay: blood, then wounds, then body parts, then the brain (only above 50).
## Returns the points actually used.
func medbay_heal(points: float) -> float:
	var used := 0.0
	if is_robot:
		battery = 100.0
		consciousness_cap = 100.0
	for part: Part in parts.values():
		part.bleed = 0.0
	if not is_robot and blood < config.blood_volume:
		var litres := minf(config.blood_volume - blood, points / 20.0)
		blood += litres
		used += litres * 20.0
	for part: Part in parts.values():
		if used >= points:
			break
		if part.amputated:
			continue
		var heal := minf(part.max_hp - part.hp, points - used)
		part.hp += heal
		used += heal
	if not is_robot and brain >= BRAIN_MEDBAY_FLOOR and brain < 100.0 and used < points:
		var heal := minf(100.0 - brain, points - used)
		brain += heal
		used += heal
	if used < points:
		pain = 0.0
		shock = 0.0
		toxin = 0.0
		cardiac_arrest = false
		heart_rate = 70.0
		blood_o2 = 98.0
		_update_awareness()
	return used


## Healing points still needed to be fully healed at the medical bay (ignoring amputations and brain below 50).
func healing_needed() -> float:
	var need := 0.0
	if not is_robot:
		need += (config.blood_volume - blood) * 20.0
		if brain >= BRAIN_MEDBAY_FLOOR:
			need += 100.0 - brain
	for part: Part in parts.values():
		if not part.amputated:
			need += part.max_hp - part.hp
	if pain > 1.0 or shock > 1.0 or cardiac_arrest:
		need += 1.0
	return maxf(0.0, need)


## Needs a bionic augmentation (metal) to recover: a lost limb, or a brain below what the medical bay can restore.
func needs_augmentation() -> bool:
	if not is_robot and brain < BRAIN_MEDBAY_FLOOR:
		return true
	for part: Part in parts.values():
		if part.amputated:
			return true
	return false


## Fits a bionic replacement for every lost limb and restores the brain to the medical bay floor.
func augment() -> void:
	for part: Part in parts.values():
		if part.amputated:
			part.amputated = false
			part.bionic = true
			part.hp = part.max_hp
			part.bleed = 0.0
	if brain < BRAIN_MEDBAY_FLOOR:
		brain = BRAIN_MEDBAY_FLOOR

#endregion


#region Queries

func total_bleed() -> float:
	var total := 0.0
	for part: Part in parts.values():
		total += part.bleed
	return total


## Pain that is actually felt: adrenaline and painkillers mask it.
func effective_pain() -> float:
	return maxf(0.0, pain - adrenaline * 0.6 - painkiller * 0.8)


func integrity() -> float:
	var hp := 0.0
	var max_hp := 0.0
	for part: Part in parts.values():
		hp += maxf(part.hp, 0.0)
		max_hp += part.max_hp
	return hp / max_hp if max_hp > 0.0 else 0.0


func is_conscious() -> bool:
	return not dead and awareness == Awareness.AWAKE


func is_incapacitated() -> bool:
	return dead or awareness != Awareness.AWAKE or (not can_use_weapons() and not can_walk())


func get_status() -> Status:
	if dead:
		return Status.DEAD
	if is_robot:
		if integrity() < 0.25 or battery < 10.0:
			return Status.DYING
		if awareness != Awareness.AWAKE or integrity() < 0.5:
			return Status.CRITICAL
		return Status.STABLE
	var need: float = BRAIN_O2_NEED[awareness]
	if cardiac_arrest or blood_o2 < need or blood < config.blood_volume * 0.5:
		return Status.DYING
	if awareness != Awareness.AWAKE or blood < config.blood_volume * 0.7 or brain < BRAIN_SLUR_THRESHOLD \
			or total_bleed() > 0.25:
		return Status.CRITICAL
	if total_bleed() > 0.01:
		return Status.BLEEDING
	return Status.STABLE


func get_status_name() -> String:
	return STATUS_NAMES[get_status()]


## Speech gets slurred or distorted below 80 brain integrity.
func is_slurred() -> bool:
	return not is_robot and brain < BRAIN_SLUR_THRESHOLD


func can_walk() -> bool:
	return not (parts[LEG_L].is_disabled() and parts[LEG_R].is_disabled())


func can_use_weapons() -> bool:
	return not (parts[ARM_L].is_disabled() and parts[ARM_R].is_disabled())


## Movement speed multiplier from legs, stamina and pain.
func move_multiplier() -> float:
	if not is_conscious():
		return 0.0
	var mult := 1.0
	for id: StringName in [LEG_L, LEG_R]:
		var part := parts[id]
		if part.is_disabled():
			mult -= 0.4
		else:
			mult -= part.damage_fraction() * 0.15
	if not can_walk():
		mult = 0.15 # crawling
	mult *= lerpf(0.6, 1.0, stamina / 100.0)
	mult *= 1.0 - effective_pain() / 400.0
	return clampf(mult, 0.1, 1.2)


## Aim steadiness multiplier: a disabled arm spoils two-handed accuracy.
func aim_multiplier() -> float:
	var mult := 1.0
	for id: StringName in [ARM_L, ARM_R]:
		if parts[id].is_disabled():
			mult *= 0.55
		else:
			mult *= 1.0 - parts[id].damage_fraction() * 0.2
	if heart_rate > 140.0:
		mult *= 0.85
	return mult


## Reload and item use speed multiplier. Both hands out makes item use very slow.
func handling_multiplier() -> float:
	var disabled := 0
	for id: StringName in [ARM_L, ARM_R]:
		if parts[id].is_disabled():
			disabled += 1
	return [1.0, 0.6, 0.15][disabled]


## A short line a crew member says about their state outside combat, or "" if there is nothing to say.
func remark() -> String:
	match get_status():
		Status.DYING:
			return "I... can't breathe..."
		Status.CRITICAL:
			if not is_conscious():
				return ""
			return "I'm hurt bad, I need a medic!"
		Status.BLEEDING:
			return "I'm bleeding!"
	if effective_pain() > 50.0:
		return "Argh, this hurts..."
	return ""


func readout() -> String:
	if is_robot:
		return "Integrity %d%%  Battery %d%%  Consciousness %d/%d  %s" % [
			roundi(integrity() * 100.0), roundi(battery), roundi(consciousness), roundi(consciousness_cap),
			get_status_name()]
	return "%s | Brain %d  Blood %.1fL  O2 %d%%  HR %d  Pain %d  Shock %d  %s" % [
		get_status_name(), roundi(brain), blood, roundi(blood_o2), roundi(heart_rate), roundi(effective_pain()),
		roundi(shock), AWARENESS_NAMES[awareness]]

#endregion


#region Saving

func to_dict() -> Dictionary:
	var part_data := {}
	for id: StringName in parts:
		part_data[String(id)] = parts[id].to_dict()
	return {
		"robot": is_robot, "resilience": resilience, "parts": part_data, "blood": blood, "blood_o2": blood_o2,
		"brain": brain, "pain": pain, "shock": shock, "heart_rate": heart_rate, "adrenaline": adrenaline,
		"stamina": stamina, "stimulant": stimulant, "painkiller": painkiller, "sedative": sedative, "toxin": toxin,
		"consciousness": consciousness, "cardiac_arrest": cardiac_arrest, "dead": dead, "awareness": awareness,
		"battery": battery, "consciousness_cap": consciousness_cap,
	}


func load_dict(data: Dictionary) -> void:
	is_robot = bool(data.get("robot", false))
	resilience = float(data.get("resilience", 10.0))
	var part_data: Dictionary = data.get("parts", {})
	for key: Variant in part_data:
		var id := StringName(key)
		if not parts.has(id):
			# Characters with extra limbs.
			var extra := Part.new()
			extra.id = id
			parts[id] = extra
		var entry: Dictionary = part_data[key]
		var part := parts[id]
		part.max_hp = float(entry.get("max_hp", part.max_hp))
		part.hp = float(entry.get("hp", part.max_hp))
		part.bleed = float(entry.get("bleed", 0.0))
		part.dressing = float(entry.get("dressing", 0.0))
		part.amputated = bool(entry.get("amputated", false))
		part.bionic = bool(entry.get("bionic", false))
	for key: String in ["blood", "blood_o2", "brain", "pain", "shock", "heart_rate", "adrenaline", "stamina",
			"stimulant", "painkiller", "sedative", "toxin", "consciousness", "battery", "consciousness_cap"]:
		if data.has(key):
			set(key, float(data[key]))
	cardiac_arrest = bool(data.get("cardiac_arrest", false))
	dead = bool(data.get("dead", false))
	awareness = int(data.get("awareness", Awareness.AWAKE)) as Awareness

#endregion


## Definition of a body part; extra limbs some characters have use the arm's.
static func _def(id: StringName) -> Array:
	return PART_DEFS.get(id, PART_DEFS[ARM_L])
