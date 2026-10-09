extends ProgressBar

func _on_value_changed(_new_value:float) -> void:
	# Resizes the FuelReadoutPusher control to push the FuelTotalReadout and the FuelUnitLabel controls with the progress bar, but stops them being completely displaced.
	%FuelReadoutPusher.size.x = min(size.x * (1 - get_as_ratio()),size.x - (%FuelTotalDisplay.size.x + %FuelUnitLabel.size.x)) 
	# Todo: Update the FuelTotalDisplay text with the remaining total ∆v as a number in meters per second.
