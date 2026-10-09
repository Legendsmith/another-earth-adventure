extends ProgressBar


func _ready() -> void:
	value_changed.connect(_on_value_changed)
	resized.connect(_on_value_changed.bind(value))


func _on_value_changed(_new_value:float) -> void:
	# Resizes the FuelReadoutPusher control to push the FuelTotalReadout and the FuelUnitLabel controls with the progress bar, but stops them being completely displaced.
	%FuelReadoutPusher.custom_minimum_size.x = maxf(min(size.x * (1 - get_as_ratio()),size.x - (%FuelTotalDisplay.size.x + %FuelUnitLabel.size.x)), 0.0)
