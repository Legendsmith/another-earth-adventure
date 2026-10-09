extends TabContainer

func _on_tab_changed(tab_index:int):
	if tab_index == -1:
		visible = false
	if tab_index >-1:
		visible = true
