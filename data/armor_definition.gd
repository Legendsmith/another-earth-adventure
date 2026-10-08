class_name ArmorDefinition
extends Resource
## An armor technology. Armor is a grid of boxes (see ArmorGrid): the hull surface sets the number of columns and the
## armor mass buys layers. Better armor has lighter boxes, so the same armor mass buys more layers.

## Name of the armor as it appears to the player.
@export var name: String = "Armor"
## Mass of one armor box. Layers = armor mass / (columns * box_mass).
@export var box_mass: float = 0.05
## Colour of intact boxes on the damage readout.
@export var color: Color = Color(0.7, 0.75, 0.8)


## Whole layers that `armor_mass` buys over a hull `columns` boxes wide.
func layers_for(armor_mass: float, columns: int) -> int:
	if box_mass <= 0.0 or columns <= 0:
		return 0
	return floori(armor_mass / (box_mass * columns) + 1e-6)
