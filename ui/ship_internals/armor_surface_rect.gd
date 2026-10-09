class_name ArmorSurfaceRect
extends TextureRect
## Shows a ShipInternals armor surface: the hull unrolled, length across and circumference down, one pixel per armor
## column. White is intact armor, darker is a deeper pit, black is a hole through. Scaled with nearest-neighbour
## filtering so every column stays a sharp block at any size.

@export var internals: ShipInternals


func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	if stretch_mode == TextureRect.STRETCH_SCALE:
		stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	bind(internals)


func bind(new_internals: ShipInternals) -> void:
	internals = new_internals
	texture = null
	if internals == null:
		return
	if not internals.is_node_ready():
		await internals.ready
	# The armor's ImageTexture is updated in place, so the rect follows the damage on its own.
	texture = internals.armor.texture
