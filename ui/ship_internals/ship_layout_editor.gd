class_name ShipLayoutEditor
extends Control
## Editor for ShipLayout resources: paint walls, place doors, drag out modules and zones, and save the result as a
## .tres. The deck is shown live by a ShipInternalsView in a SubViewport, so what you build is what the game uses.
##
## Tools (keys 1-6):
## - Select: click a module or zone to edit its properties in the side panel, drag it to move it.
## - Wall: drag to paint walls, right-drag to erase them.
## - Door: click a wall to turn it into a door (or a door back into a wall).
## - Module: drag a rectangle over open deck to place a module with the panel's settings.
## - Zone: drag a rectangle to mark a zone (cargo, crew quarters, mess...).
## - Erase: click to remove the module, door, wall or zone under the cursor, in that order.
## Ctrl+Z undoes, Delete removes the selection.

enum Tool { SELECT, WALL, DOOR, MODULE, ZONE, ERASE }

const TOOL_NAMES := ["Select", "Wall", "Door", "Module", "Zone", "Erase"]
const COMPONENTS_DIR := "res://data/components/"
const DEFAULT_PATH := "res://data/ship_internals/layouts/gunship.tres"
const UNDO_LIMIT := 50
const MODULE_COLORS := {
	ShipComponent.Kind.MAIN_ENGINE: Color(0.85, 0.55, 0.3),
	ShipComponent.Kind.REACTOR: Color(0.4, 0.85, 0.5),
	ShipComponent.Kind.FUEL_TANK: Color(0.75, 0.7, 0.3),
	ShipComponent.Kind.SENSORS: Color(0.6, 0.5, 0.9),
	ShipComponent.Kind.WEAPON: Color(0.5, 0.6, 0.9),
	ShipComponent.Kind.MAGAZINE: Color(0.85, 0.35, 0.35),
	ShipComponent.Kind.BRIDGE: Color(0.55, 0.8, 0.95),
}

var layout: ShipLayout
var tool: Tool = Tool.SELECT
## Selected module or zone (ShipModule or ShipRoom), or null.
var selected: Resource

var _view: ShipInternalsView
var _viewport_container: SubViewportContainer
var _overlay: Node2D
var _tool_buttons: Array[Button] = []
var _presets: Array[ShipComponent] = []
var _undo: Array[ShipLayout] = []
var _hover := Vector2i(-1, -1)
var _drag_start := Vector2i(-1, -1)
var _dragging := false
var _drag_erase := false
## Offset from the cursor cell to a moved item's corner while dragging it with Select.
var _move_offset := Vector2i.ZERO
var _move_original := Rect2i()
var _updating_panel := false

var _length: SpinBox
var _diameter: SpinBox
var _thickness: SpinBox
var _preset: OptionButton
var _module_type: OptionButton
var _module_name: LineEdit
var _module_component: LineEdit
var _module_hit_points: SpinBox
var _module_color: ColorPickerButton
var _zone_type: OptionButton
var _zone_name: LineEdit
var _path: LineEdit
var _status: Label
var _selection_label: Label


func _ready() -> void:
	_build_ui()
	_load_presets()
	var start: ShipLayout = null
	if ResourceLoader.exists(DEFAULT_PATH):
		start = ResourceLoader.load(DEFAULT_PATH, "", ResourceLoader.CACHE_MODE_IGNORE) as ShipLayout
	_set_layout(start.duplicate(true) if start else ShipLayout.create_default())
	_set_tool(Tool.SELECT)
	resized.connect(_fit_view)


#region Editing

func _set_layout(new_layout: ShipLayout) -> void:
	layout = new_layout
	selected = null
	_refresh()
	_sync_hull_fields()
	_fit_view.call_deferred()


## Saves an undo step. Call before changing the layout.
func _push_undo() -> void:
	_undo.append(layout.duplicate(true))
	if _undo.size() > UNDO_LIMIT:
		_undo.pop_front()


func undo() -> void:
	if _undo.is_empty():
		_set_status("Nothing to undo")
		return
	var index := _selected_index()
	var was_module := selected is ShipModule
	layout = _undo.pop_back()
	selected = null
	if index >= 0:
		var list: Array = layout.modules if was_module else layout.rooms
		if index < list.size():
			selected = list[index]
	_sync_hull_fields()
	_refresh()


## Rebuilds the preview from the layout.
func _refresh() -> void:
	if _view and _view.internals:
		_view.internals.set_layout(layout)
	_update_selection_panel()
	if _overlay:
		_overlay.queue_redraw()


func _paint_wall(cell: Vector2i, erase: bool) -> void:
	if not _is_interior(cell):
		return
	var walls := layout.get_wall_cells()
	if erase:
		if not walls.has(cell):
			return
		walls.erase(cell)
		layout.doors.erase(cell)
	else:
		if walls.has(cell) or _module_at(cell) != null:
			return
		walls[cell] = true
	layout.set_wall_cells(walls)
	_refresh()


func _toggle_door(cell: Vector2i) -> void:
	if not layout.get_wall_cells().has(cell):
		_set_status("Doors go in walls")
		return
	_push_undo()
	if layout.doors.has(cell):
		layout.doors.erase(cell)
	else:
		layout.doors.append(cell)
	_refresh()


func _place_module(rect: Rect2i) -> void:
	var problem := _module_rect_problem(rect, null)
	if problem:
		_set_status(problem)
		return
	_push_undo()
	var module := ShipModule.new()
	_apply_module_fields(module)
	module.rect = rect
	layout.modules.append(module)
	selected = module
	_refresh()


func _place_zone(rect: Rect2i) -> void:
	rect = rect.intersection(_interior())
	if rect.size.x <= 0 or rect.size.y <= 0:
		return
	_push_undo()
	var room := ShipRoom.new()
	room.zone = _zone_type.selected as ShipRoom.Zone
	room.name = _zone_name.text if _zone_name.text else ShipRoom.ZONE_NAMES[room.zone]
	room.rect = rect
	layout.rooms.append(room)
	selected = room
	_refresh()


func _erase_at(cell: Vector2i) -> void:
	var module := _module_at(cell)
	if module:
		_push_undo()
		layout.modules.erase(module)
	elif layout.doors.has(cell):
		_push_undo()
		layout.doors.erase(cell)
	elif layout.get_wall_cells().has(cell):
		_push_undo()
		_paint_wall(cell, true)
	else:
		var room := _room_at(cell)
		if room == null:
			return
		_push_undo()
		layout.rooms.erase(room)
	if selected and not (selected in layout.modules or selected in layout.rooms):
		selected = null
	_refresh()


func delete_selected() -> void:
	if selected == null:
		return
	_push_undo()
	if selected is ShipModule:
		layout.modules.erase(selected)
	else:
		layout.rooms.erase(selected)
	selected = null
	_refresh()


## Moves the selection so its corner is at `corner`, if it fits there.
func _move_selected(corner: Vector2i) -> void:
	var rect := Rect2i(corner, selected.rect.size)
	if selected is ShipModule:
		if _module_rect_problem(rect, selected):
			return
	elif not _interior().encloses(rect):
		return
	selected.rect = rect
	_refresh()


func _resize_hull() -> void:
	if _updating_panel:
		return
	_push_undo()
	layout.length = int(_length.value)
	layout.diameter = int(_diameter.value)
	layout.armor_thickness = int(_thickness.value)
	# Drop whatever no longer fits inside the hull.
	var interior := _interior()
	var walls := layout.get_wall_cells()
	for cell in walls.keys():
		if not interior.has_point(cell):
			walls.erase(cell)
	layout.set_wall_cells(walls)
	layout.doors = layout.doors.filter(func(cell: Vector2i) -> bool: return interior.has_point(cell))
	layout.modules = layout.modules.filter(func(m: ShipModule) -> bool: return interior.encloses(m.rect))
	for room in layout.rooms:
		room.rect = room.rect.intersection(interior)
	layout.rooms = layout.rooms.filter(func(r: ShipRoom) -> bool: return r.rect.size.x > 0 and r.rect.size.y > 0)
	if selected and not (selected in layout.modules or selected in layout.rooms):
		selected = null
	_refresh()
	_fit_view()


## Why a module cannot go at `rect` (empty when it can). `ignore` is a module being moved.
func _module_rect_problem(rect: Rect2i, ignore: ShipModule) -> String:
	if not _interior().encloses(rect):
		return "Modules go inside the hull"
	var walls := layout.get_wall_cells()
	for y in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			if walls.has(Vector2i(x, y)):
				return "Modules can't cover walls or doors"
	for module in layout.modules:
		if module != ignore and module.rect.intersects(rect):
			return "Modules can't overlap"
	return ""

#endregion


#region Queries

func _interior() -> Rect2i:
	return Rect2i(1, 1, layout.length - 2, layout.diameter - 2)


func _is_interior(cell: Vector2i) -> bool:
	return _interior().has_point(cell)


func _module_at(cell: Vector2i) -> ShipModule:
	for module in layout.modules:
		if module.rect.has_point(cell):
			return module
	return null


## The smallest zone under the cell (zones may nest).
func _room_at(cell: Vector2i) -> ShipRoom:
	var best: ShipRoom = null
	for room in layout.rooms:
		if room.rect.has_point(cell) and (best == null or room.rect.get_area() < best.rect.get_area()):
			best = room
	return best


func _selected_index() -> int:
	if selected is ShipModule:
		return layout.modules.find(selected)
	if selected is ShipRoom:
		return layout.rooms.find(selected)
	return -1


func _cell_under_mouse(position_in_container: Vector2) -> Vector2i:
	return _view.local_to_cell(_view.get_global_transform().affine_inverse() * position_in_container)


func _drag_rect(a: Vector2i, b: Vector2i) -> Rect2i:
	var start := Vector2i(mini(a.x, b.x), mini(a.y, b.y))
	return Rect2i(start, (a - b).abs() + Vector2i.ONE)

#endregion


#region Input

func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	if key.keycode == KEY_Z and key.is_command_or_control_pressed():
		undo()
	elif key.keycode == KEY_DELETE or key.keycode == KEY_BACKSPACE:
		delete_selected()
	elif key.keycode >= KEY_1 and key.keycode < KEY_1 + Tool.size():
		_set_tool((key.keycode - KEY_1) as Tool)
	else:
		return
	get_viewport().set_input_as_handled()


func _on_view_input(event: InputEvent) -> void:
	var motion := event as InputEventMouseMotion
	if motion:
		var cell := _cell_under_mouse(motion.position)
		if cell != _hover:
			_hover = cell
			_on_drag_to(cell)
			_overlay.queue_redraw()
		return
	var button := event as InputEventMouseButton
	if button == null or (button.button_index != MOUSE_BUTTON_LEFT and button.button_index != MOUSE_BUTTON_RIGHT):
		return
	var cell := _cell_under_mouse(button.position)
	if button.pressed:
		_on_press(cell, button.button_index == MOUSE_BUTTON_RIGHT)
	elif _dragging:
		_on_release(cell)
	_overlay.queue_redraw()


func _on_press(cell: Vector2i, right: bool) -> void:
	_dragging = true
	_drag_start = cell
	_drag_erase = right
	match tool:
		Tool.SELECT:
			var hit: Resource = _module_at(cell)
			if hit == null:
				hit = _room_at(cell)
			selected = hit
			if selected:
				_push_undo()
				_move_offset = cell - selected.rect.position
				_move_original = selected.rect
			_update_selection_panel()
		Tool.WALL:
			_push_undo()
			_paint_wall(cell, right)
		Tool.DOOR:
			_dragging = false
			_toggle_door(cell)
		Tool.ERASE:
			_dragging = false
			_erase_at(cell)


func _on_drag_to(cell: Vector2i) -> void:
	if not _dragging:
		return
	match tool:
		Tool.WALL:
			_paint_wall(cell, _drag_erase)
		Tool.SELECT:
			if selected:
				_move_selected(cell - _move_offset)


func _on_release(cell: Vector2i) -> void:
	_dragging = false
	match tool:
		Tool.MODULE:
			_place_module(_drag_rect(_drag_start, cell))
		Tool.ZONE:
			_place_zone(_drag_rect(_drag_start, cell))
		Tool.SELECT:
			# A click without a move leaves no undo step behind.
			if selected and selected.rect == _move_original and not _undo.is_empty():
				_undo.pop_back()

#endregion


#region Panel

func _set_tool(new_tool: Tool) -> void:
	tool = new_tool
	for i in _tool_buttons.size():
		_tool_buttons[i].set_pressed_no_signal(i == tool)
	_set_status(["Click to select, drag to move", "Drag to paint walls, right-drag to erase",
		"Click a wall to make a door", "Drag a rectangle over open deck", "Drag a rectangle to mark a zone",
		"Click to remove what's under the cursor"][tool])
	if _overlay:
		_overlay.queue_redraw()


func _set_status(text: String) -> void:
	if _status:
		_status.text = text


func _load_presets() -> void:
	_presets.clear()
	_preset.clear()
	_preset.add_item("Custom")
	var dir := DirAccess.open(COMPONENTS_DIR)
	if dir == null:
		return
	var files := Array(dir.get_files())
	files.sort()
	for listed: String in files:
		# Exported builds list resources as .remap files.
		var file := listed.trim_suffix(".remap")
		if not file.ends_with(".tres"):
			continue
		var component := load(COMPONENTS_DIR + file) as ShipComponent
		# Thrusters are spread through the hull, and crew spaces are zones: neither is a module.
		if component == null or component.kind in [ShipComponent.Kind.THRUSTERS, ShipComponent.Kind.CREW,
				ShipComponent.Kind.STRUCTURE]:
			continue
		_presets.append(component)
		_preset.add_item(component.name)


func _on_preset_selected(index: int) -> void:
	if index <= 0:
		return
	var component := _presets[index - 1]
	_updating_panel = true
	_module_name.text = component.name
	_module_component.text = component.name
	_module_hit_points.value = component.hit_to_kill
	_module_type.select(ShipModule.Type.FUEL_TANK if component.kind == ShipComponent.Kind.FUEL_TANK
		else ShipModule.Type.SYSTEM)
	_module_color.color = MODULE_COLORS.get(component.kind, Color(0.45, 0.6, 0.75))
	_updating_panel = false
	_on_module_fields_changed()


func _apply_module_fields(module: ShipModule) -> void:
	module.name = _module_name.text if _module_name.text else "Module"
	module.component_name = _module_component.text
	module.type = _module_type.selected as ShipModule.Type
	module.hit_points = int(_module_hit_points.value)
	module.color = _module_color.color


## Panel edits apply to the selected module (and set up the next one placed).
func _on_module_fields_changed(_value: Variant = null) -> void:
	if _updating_panel or not selected is ShipModule:
		return
	_push_undo()
	_apply_module_fields(selected)
	_refresh()


func _on_zone_fields_changed(_value: Variant = null) -> void:
	if _updating_panel or not selected is ShipRoom:
		return
	_push_undo()
	selected.zone = _zone_type.selected as ShipRoom.Zone
	selected.name = _zone_name.text
	_refresh()


func _update_selection_panel() -> void:
	if _selection_label == null:
		return
	_updating_panel = true
	if selected is ShipModule:
		var module: ShipModule = selected
		_selection_label.text = "Selected module: %s  (%d x %d)" % [module.name, module.rect.size.x, module.rect.size.y]
		_module_name.text = module.name
		_module_component.text = module.component_name
		_module_type.select(module.type)
		_module_hit_points.value = module.hit_points
		_module_color.color = module.color
	elif selected is ShipRoom:
		var room: ShipRoom = selected
		_selection_label.text = "Selected zone: %s  (%d x %d)" % [room.name, room.rect.size.x, room.rect.size.y]
		_zone_type.select(room.zone)
		_zone_name.text = room.name
	else:
		_selection_label.text = "Nothing selected"
	_updating_panel = false


func _sync_hull_fields() -> void:
	_updating_panel = true
	_length.value = layout.length
	_diameter.value = layout.diameter
	_thickness.value = layout.armor_thickness
	_updating_panel = false


func save_layout(path: String) -> Error:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var saved := layout.duplicate(true)
	var error := ResourceSaver.save(saved, path)
	_set_status("Saved %s" % path if error == OK else "Could not save %s (%s)" % [path, error_string(error)])
	return error


func load_layout(path: String) -> void:
	var loaded := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as ShipLayout
	if loaded == null:
		_set_status("No ship layout at %s" % path)
		return
	_push_undo()
	_set_layout(loaded.duplicate(true))
	_set_status("Loaded %s" % path)


func _new_layout(empty: bool) -> void:
	_push_undo()
	var fresh := ShipLayout.create_default()
	if empty:
		fresh.walls.clear()
		fresh.doors.clear()
		fresh.modules.clear()
		fresh.rooms.clear()
	_set_layout(fresh)


## Scales the deck to fill the view area, in whole steps so cells stay crisp.
func _fit_view() -> void:
	if _view == null or _viewport_container == null or layout == null:
		return
	var available := _viewport_container.size
	var deck := Vector2(layout.length, layout.diameter) * _view.cell_size
	var zoom := maxf(floorf(minf(available.x / deck.x, available.y / deck.y) * 4.0) / 4.0, 0.5)
	_view.scale = Vector2.ONE * zoom
	_view.position = ((available - deck * zoom) / 2.0).floor()

#endregion


#region Build

func _build_ui() -> void:
	var background := ColorRect.new()
	background.color = Color(0.05, 0.06, 0.08)
	background.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(background)
	var split := HSplitContainer.new()
	split.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(split)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size.x = 300
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	split.add_child(scroll)
	var panel := VBoxContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(panel)

	_heading(panel, "Tools")
	var tools := GridContainer.new()
	tools.columns = 3
	panel.add_child(tools)
	for i in TOOL_NAMES.size():
		var button := Button.new()
		button.text = "%d %s" % [i + 1, TOOL_NAMES[i]]
		button.toggle_mode = true
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.pressed.connect(_set_tool.bind(i))
		tools.add_child(button)
		_tool_buttons.append(button)
	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.modulate = Color(0.75, 0.85, 1.0)
	panel.add_child(_status)

	_heading(panel, "Hull")
	_length = _spin(panel, "Length", 8, 200)
	_diameter = _spin(panel, "Diameter", 5, 60)
	_thickness = _spin(panel, "Armor depth (standalone)", 0, 255)
	for spin in [_length, _diameter, _thickness]:
		spin.value_changed.connect(func(_v: float) -> void: _resize_hull())

	_heading(panel, "Module")
	_preset = _option(panel, "Preset", [])
	_preset.item_selected.connect(_on_preset_selected)
	_module_type = _option(panel, "Type", ShipModule.TYPE_NAMES)
	_module_type.item_selected.connect(_on_module_fields_changed)
	_module_name = _line(panel, "Name", "Module")
	_module_name.text_changed.connect(_on_module_fields_changed)
	_module_component = _line(panel, "Hull component", "")
	_module_component.text_changed.connect(_on_module_fields_changed)
	_module_hit_points = _spin(panel, "Hit points (no component)", 1, 99)
	_module_hit_points.value_changed.connect(_on_module_fields_changed)
	_module_color = ColorPickerButton.new()
	_module_color.custom_minimum_size.y = 24
	_module_color.color = Color(0.45, 0.6, 0.75)
	_module_color.color_changed.connect(_on_module_fields_changed)
	_row(panel, "Colour", _module_color)

	_heading(panel, "Zone")
	_zone_type = _option(panel, "Type", ShipRoom.ZONE_NAMES)
	_zone_type.item_selected.connect(_on_zone_fields_changed)
	_zone_name = _line(panel, "Name", "")
	_zone_name.text_changed.connect(_on_zone_fields_changed)

	_heading(panel, "Selection")
	_selection_label = Label.new()
	_selection_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	panel.add_child(_selection_label)
	_button(panel, "Delete selected", delete_selected)
	_button(panel, "Undo (Ctrl+Z)", undo)

	_heading(panel, "File")
	_path = LineEdit.new()
	_path.text = DEFAULT_PATH
	panel.add_child(_path)
	var file_row := HBoxContainer.new()
	panel.add_child(file_row)
	_button(file_row, "Save", func() -> void: save_layout(_path.text))
	_button(file_row, "Load", func() -> void: load_layout(_path.text))
	var new_row := HBoxContainer.new()
	panel.add_child(new_row)
	_button(new_row, "Default ship", _new_layout.bind(false))
	_button(new_row, "Empty hull", _new_layout.bind(true))

	_viewport_container = SubViewportContainer.new()
	_viewport_container.stretch = true
	_viewport_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_viewport_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_viewport_container.mouse_filter = Control.MOUSE_FILTER_STOP
	_viewport_container.gui_input.connect(_on_view_input)
	_viewport_container.resized.connect(_fit_view)
	split.add_child(_viewport_container)
	var viewport := SubViewport.new()
	viewport.handle_input_locally = false
	viewport.transparent_bg = true
	_viewport_container.add_child(viewport)
	_view = ShipInternalsView.new()
	viewport.add_child(_view)
	_overlay = Node2D.new()
	_overlay.draw.connect(_draw_overlay)
	_view.add_child(_overlay)


func _heading(parent: Control, text: String) -> void:
	var label := Label.new()
	label.text = text
	label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.5))
	parent.add_child(HSeparator.new())
	parent.add_child(label)


func _row(parent: Control, text: String, control: Control) -> void:
	var row := HBoxContainer.new()
	var label := Label.new()
	label.text = text
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(label)
	row.add_child(control)
	parent.add_child(row)


func _spin(parent: Control, text: String, low: int, high: int) -> SpinBox:
	var spin := SpinBox.new()
	spin.min_value = low
	spin.max_value = high
	spin.step = 1
	spin.value = low
	_row(parent, text, spin)
	return spin


func _option(parent: Control, text: String, items: Array) -> OptionButton:
	var option := OptionButton.new()
	for item: String in items:
		option.add_item(item)
	_row(parent, text, option)
	return option


func _line(parent: Control, text: String, value: String) -> LineEdit:
	var line := LineEdit.new()
	line.text = value
	_row(parent, text, line)
	return line


func _button(parent: Control, text: String, action: Callable) -> void:
	var button := Button.new()
	button.text = text
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.pressed.connect(action)
	parent.add_child(button)

#endregion


func _draw_overlay() -> void:
	var cell := _view.cell_size
	if selected:
		var rect: Rect2i = selected.rect
		_overlay.draw_rect(Rect2(Vector2(rect.position) * cell, Vector2(rect.size) * cell).grow(1.0),
			Color(1.0, 0.9, 0.3), false, 2.0)
	if _dragging and (tool == Tool.MODULE or tool == Tool.ZONE):
		var rect := _drag_rect(_drag_start, _hover)
		var valid := tool == Tool.ZONE or _module_rect_problem(rect, null).is_empty()
		var color := Color(0.4, 1.0, 0.5) if valid else Color(1.0, 0.35, 0.3)
		_overlay.draw_rect(Rect2(Vector2(rect.position) * cell, Vector2(rect.size) * cell), Color(color, 0.2))
		_overlay.draw_rect(Rect2(Vector2(rect.position) * cell, Vector2(rect.size) * cell), color, false, 2.0)
	elif _hover.x >= 0 and layout and Rect2i(0, 0, layout.length, layout.diameter).has_point(_hover):
		_overlay.draw_rect(Rect2(Vector2(_hover) * cell, Vector2.ONE * cell), Color(1.0, 1.0, 1.0, 0.6), false, 1.0)
