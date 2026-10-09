class_name CombatExplosion
extends Node2D
## Expanding, fading ring for detonations and destroyed hulls. Frees itself.
##
## An explosion is also a sensor contact: a bright flash whose passive signature scales with the damage it carries
## (`SIGNATURE_PER_DAMAGE`), so it is seen from much further than the munition or ship that made it. When the player's
## sensors see it, the SensorNetwork drops the track of whatever blew up (`source`) and keeps a brief ghost of the flash.

const GROUP := &"combat_explosions"
## Passive signature per point of warhead damage (or hull structure for a destroyed ship).
const SIGNATURE_PER_DAMAGE := 25.0

@export var radius: float = 20.0
@export var duration: float = 1.0
@export var color: Color = Color(1.0, 0.75, 0.4)
## Passive sensor signature of the flash.
@export var signature: float = 0.0
## What the sensor plot calls it.
@export var description: String = "Explosion"

## Instance id of the SensorSuite or Munition that blew up, whose track ends with this flash. 0 if it carries on
## (a canister burst). An id rather than a reference: the source is usually freed in the same tick.
var source_id := 0

var _age := 0.0


## Spawns an explosion of `damage` points at `at` under `parent`.
static func spawn(parent: Node, at: Vector2, blast_radius: float, damage: float, what: String, from: Object = null,
		blast_color: Color = Color(1.0, 0.75, 0.4)) -> CombatExplosion:
	var blast := CombatExplosion.new()
	blast.radius = blast_radius
	blast.color = blast_color
	blast.signature = maxf(damage, 1.0) * SIGNATURE_PER_DAMAGE
	blast.description = what
	blast.source_id = from.get_instance_id() if from else 0
	parent.add_child(blast)
	blast.global_position = at
	return blast


func _enter_tree() -> void:
	add_to_group(GROUP)


func _process(delta: float) -> void:
	_age += delta
	if _age >= duration:
		queue_free()
		return
	queue_redraw()


func get_world_position() -> Vector2:
	return global_position


func _draw() -> void:
	var t := _age / duration
	var scale_factor := maxf(1.0, 1.0 / get_canvas_transform().get_scale().x)
	var r := radius * (0.3 + 0.7 * t) * scale_factor
	draw_circle(Vector2.ZERO, r * (1.0 - t), Color(1.0, 0.95, 0.8, 0.8 * (1.0 - t)))
	draw_arc(Vector2.ZERO, r, 0.0, TAU, 32, Color(color, 1.0 - t), 2.0 * scale_factor)
