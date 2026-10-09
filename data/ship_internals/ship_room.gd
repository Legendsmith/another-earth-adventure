class_name ShipRoom
extends Resource
## A named zone of a ShipLayout's deck. Zones hold no systems: rounds through them only hole the deck and walls. Their
## type says what the space is for (crew will use it: where to sleep, eat or stow cargo).

enum Zone { GENERAL, CARGO, CREW_QUARTERS, MESS, CORRIDOR }

const ZONE_NAMES := ["General", "Cargo", "Crew Quarters", "Mess", "Corridor"]
## Tint of each zone on the deck plan.
const ZONE_COLORS := [Color(0.0, 0.0, 0.0, 0.0), Color(0.75, 0.6, 0.3, 0.14), Color(0.35, 0.55, 0.95, 0.14),
	Color(0.4, 0.85, 0.45, 0.14), Color(0.0, 0.0, 0.0, 0.0)]

@export var name: String = "Room"
@export var zone: Zone = Zone.GENERAL
@export var rect: Rect2i = Rect2i(0, 0, 1, 1)
