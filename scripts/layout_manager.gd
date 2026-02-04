extends Node


## LayoutManager - Autoload singleton for persisting and restoring workspace layouts
##
## Manages named layouts that store panel positions, sizes, types, and agent bindings.
## Layouts are saved to user://layouts/ as JSON files.


## Emitted when a layout is saved
signal layout_saved(layout_name: String)

## Emitted when a layout is loaded
signal layout_loaded(layout_name: String)

## Emitted when a layout is deleted
signal layout_deleted(layout_name: String)

## Emitted when layout list changes
signal layouts_changed


## Default layout name for new projects
const DEFAULT_LAYOUT_NAME := "default"

## Layout file extension
const LAYOUT_EXTENSION := ".layout.json"

## Layout directory
const LAYOUTS_DIR := "user://layouts/"


## Panel state for serialization
class PanelState:
	var panel_type: String = ""
	var position: Vector3 = Vector3.ZERO
	var rotation: Vector3 = Vector3.ZERO  # Euler angles
	var panel_size: Vector2 = Vector2(1.0, 0.75)
	var viewport_size: Vector2 = Vector2(800, 600)
	var title: String = "Panel"
	var bound_agent_id: String = ""  # For terminals - reference only, not auto-reconnect
	var is_minimized: bool = false
	var custom_data: Dictionary = {}  # For panel-specific state

	func to_dict() -> Dictionary:
		return {
			"panel_type": panel_type,
			"position": {"x": position.x, "y": position.y, "z": position.z},
			"rotation": {"x": rotation.x, "y": rotation.y, "z": rotation.z},
			"panel_size": {"x": panel_size.x, "y": panel_size.y},
			"viewport_size": {"x": viewport_size.x, "y": viewport_size.y},
			"title": title,
			"bound_agent_id": bound_agent_id,
			"is_minimized": is_minimized,
			"custom_data": custom_data
		}

	static func from_dict(data: Dictionary) -> PanelState:
		var state := PanelState.new()
		state.panel_type = data.get("panel_type", "")

		var pos: Dictionary = data.get("position", {})
		state.position = Vector3(pos.get("x", 0.0), pos.get("y", 0.0), pos.get("z", 0.0))

		var rot: Dictionary = data.get("rotation", {})
		state.rotation = Vector3(rot.get("x", 0.0), rot.get("y", 0.0), rot.get("z", 0.0))

		var ps: Dictionary = data.get("panel_size", {})
		state.panel_size = Vector2(ps.get("x", 1.0), ps.get("y", 0.75))

		var vs: Dictionary = data.get("viewport_size", {})
		state.viewport_size = Vector2(vs.get("x", 800), vs.get("y", 600))

		state.title = data.get("title", "Panel")
		state.bound_agent_id = data.get("bound_agent_id", "")
		state.is_minimized = data.get("is_minimized", false)
		state.custom_data = data.get("custom_data", {})

		return state


## Layout definition containing all panel states
class Layout:
	var name: String = ""
	var created_at: int = 0  # Unix timestamp
	var modified_at: int = 0  # Unix timestamp
	var panels: Array[PanelState] = []
	var metadata: Dictionary = {}  # Layout-level metadata

	func to_dict() -> Dictionary:
		var panels_array: Array = []
		for panel in panels:
			panels_array.append(panel.to_dict())

		return {
			"name": name,
			"created_at": created_at,
			"modified_at": modified_at,
			"panels": panels_array,
			"metadata": metadata,
			"version": 1  # For future format migrations
		}

	static func from_dict(data: Dictionary) -> Layout:
		var layout := Layout.new()
		layout.name = data.get("name", "")
		layout.created_at = data.get("created_at", 0)
		layout.modified_at = data.get("modified_at", 0)
		layout.metadata = data.get("metadata", {})

		var panels_array: Array = data.get("panels", [])
		for panel_data in panels_array:
			layout.panels.append(PanelState.from_dict(panel_data))

		return layout


# Cached layout names
var _layout_names: Array[String] = []


func _ready() -> void:
	# Ensure layouts directory exists
	_ensure_layouts_dir()

	# Load layout names
	_refresh_layout_names()

	# Create default layout if it doesn't exist
	if not has_layout(DEFAULT_LAYOUT_NAME):
		_create_default_layout()


func _ensure_layouts_dir() -> void:
	var dir := DirAccess.open("user://")
	if dir and not dir.dir_exists("layouts"):
		dir.make_dir("layouts")


func _refresh_layout_names() -> void:
	_layout_names.clear()

	var dir := DirAccess.open(LAYOUTS_DIR)
	if not dir:
		return

	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if not dir.current_is_dir() and file_name.ends_with(LAYOUT_EXTENSION):
			var layout_name := file_name.trim_suffix(LAYOUT_EXTENSION)
			_layout_names.append(layout_name)
		file_name = dir.get_next()
	dir.list_dir_end()

	_layout_names.sort()


func _create_default_layout() -> void:
	# Create a minimal default layout
	var layout := Layout.new()
	layout.name = DEFAULT_LAYOUT_NAME
	layout.created_at = int(Time.get_unix_time_from_system())
	layout.modified_at = layout.created_at
	layout.metadata = {"description": "Default workspace layout"}

	# Default layout has no panels - fresh start
	_save_layout_to_file(layout)
	_refresh_layout_names()


func _get_layout_path(layout_name: String) -> String:
	return LAYOUTS_DIR + layout_name + LAYOUT_EXTENSION


func _save_layout_to_file(layout: Layout) -> Error:
	var path := _get_layout_path(layout.name)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if not file:
		push_error("LayoutManager: Failed to open file for writing: %s" % path)
		return FileAccess.get_open_error()

	var json_string := JSON.stringify(layout.to_dict(), "\t")
	file.store_string(json_string)
	file.close()

	return OK


func _load_layout_from_file(layout_name: String) -> Layout:
	var path := _get_layout_path(layout_name)
	if not FileAccess.file_exists(path):
		push_error("LayoutManager: Layout file not found: %s" % path)
		return null

	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		push_error("LayoutManager: Failed to open layout file: %s" % path)
		return null

	var json_string := file.get_as_text()
	file.close()

	var json := JSON.new()
	var parse_result := json.parse(json_string)
	if parse_result != OK:
		push_error("LayoutManager: Failed to parse layout JSON: %s" % json.get_error_message())
		return null

	return Layout.from_dict(json.data)


## Get the panel type key for a given panel instance
func _get_panel_type(panel: WorkspacePanel) -> String:
	# Check specific panel types first
	if panel is TerminalPanel:
		return "terminal"

	# Check for script-based types
	var script = panel.get_script()
	if script:
		var script_path: String = script.resource_path

		# Match against known panel types
		for type_key in PanelRegistry.PANEL_TYPES:
			var type_info: Dictionary = PanelRegistry.PANEL_TYPES[type_key]
			if type_info.get("script", "") == script_path:
				return type_key

		# Check if it's a spawnable panel type by scene
		for type_key in PanelRegistry.PANEL_TYPES:
			var type_info: Dictionary = PanelRegistry.PANEL_TYPES[type_key]
			if type_info.get("scene", "") == script_path:
				return type_key

	# Default to workspace panel
	return "workspace"


## Capture the current state of a panel
func _capture_panel_state(panel: WorkspacePanel) -> PanelState:
	var state := PanelState.new()

	state.panel_type = _get_panel_type(panel)
	state.position = panel.global_position
	state.rotation = panel.global_rotation
	state.panel_size = panel.panel_size
	state.viewport_size = panel.viewport_size
	state.title = panel.title
	state.is_minimized = panel._is_minimized

	# Capture agent binding for terminal panels
	if panel is TerminalPanel:
		var terminal: TerminalPanel = panel
		state.bound_agent_id = terminal.get_bound_agent_id()

	return state


## Restore a panel from saved state
func _restore_panel(state: PanelState, parent: Node3D = null) -> WorkspacePanel:
	# Skip panels we can't restore (agent_spawn is a menu, not a panel to persist)
	if state.panel_type == "agent_spawn":
		return null

	# Create transform from saved state
	var transform := Transform3D.IDENTITY
	transform.origin = state.position
	transform.basis = Basis.from_euler(state.rotation)

	# Spawn the panel
	var panel := PanelRegistry.spawn_panel(state.panel_type, transform, parent)
	if not panel:
		push_warning("LayoutManager: Failed to spawn panel of type: %s" % state.panel_type)
		return null

	# Apply saved properties
	panel.panel_size = state.panel_size
	panel.viewport_size = state.viewport_size

	# Only restore title if it's not the default
	if state.title != "Panel" and state.title != "Terminal":
		panel.title = state.title

	# Restore minimized state
	if state.is_minimized:
		panel.minimize()

	# Note: We don't auto-bind agents since they may not exist in a new session
	# The bound_agent_id is stored for reference/display purposes

	return panel


# =============================================================================
# Public API
# =============================================================================

## Get list of all available layout names
func get_layout_names() -> Array[String]:
	return _layout_names.duplicate()


## Check if a layout exists
func has_layout(layout_name: String) -> bool:
	return layout_name in _layout_names


## Save the current workspace layout
func save_layout(layout_name: String) -> Error:
	var layout := Layout.new()
	layout.name = layout_name
	layout.modified_at = int(Time.get_unix_time_from_system())

	# Set created_at for new layouts
	if has_layout(layout_name):
		var existing := _load_layout_from_file(layout_name)
		if existing:
			layout.created_at = existing.created_at
		else:
			layout.created_at = layout.modified_at
	else:
		layout.created_at = layout.modified_at

	# Capture all panel states
	var panels := PanelRegistry.get_all_panels()
	for panel in panels:
		var state := _capture_panel_state(panel)
		layout.panels.append(state)

	# Save to file
	var error := _save_layout_to_file(layout)
	if error == OK:
		_refresh_layout_names()
		layout_saved.emit(layout_name)
		layouts_changed.emit()
		print("LayoutManager: Saved layout '%s' with %d panels" % [layout_name, layout.panels.size()])

	return error


## Load a layout and restore panels
func load_layout(layout_name: String, close_existing: bool = true) -> Error:
	if not has_layout(layout_name):
		push_error("LayoutManager: Layout not found: %s" % layout_name)
		return ERR_FILE_NOT_FOUND

	var layout := _load_layout_from_file(layout_name)
	if not layout:
		return ERR_PARSE_ERROR

	# Close existing panels if requested
	if close_existing:
		PanelRegistry.close_all_panels()
		# Wait a frame for cleanup
		await get_tree().process_frame

	# Restore panels from layout
	var restored_count := 0
	for state in layout.panels:
		var panel := _restore_panel(state)
		if panel:
			restored_count += 1

	layout_loaded.emit(layout_name)
	print("LayoutManager: Loaded layout '%s' with %d panels" % [layout_name, restored_count])

	return OK


## Delete a layout
func delete_layout(layout_name: String) -> Error:
	if not has_layout(layout_name):
		return ERR_FILE_NOT_FOUND

	# Don't allow deleting the default layout
	if layout_name == DEFAULT_LAYOUT_NAME:
		push_warning("LayoutManager: Cannot delete the default layout")
		return ERR_CANT_ACQUIRE_RESOURCE

	var path := _get_layout_path(layout_name)
	var dir := DirAccess.open(LAYOUTS_DIR)
	if not dir:
		return ERR_FILE_CANT_OPEN

	var error := dir.remove(layout_name + LAYOUT_EXTENSION)
	if error == OK:
		_refresh_layout_names()
		layout_deleted.emit(layout_name)
		layouts_changed.emit()
		print("LayoutManager: Deleted layout '%s'" % layout_name)

	return error


## Rename a layout
func rename_layout(old_name: String, new_name: String) -> Error:
	if not has_layout(old_name):
		return ERR_FILE_NOT_FOUND

	if has_layout(new_name):
		return ERR_ALREADY_EXISTS

	# Don't allow renaming the default layout
	if old_name == DEFAULT_LAYOUT_NAME:
		push_warning("LayoutManager: Cannot rename the default layout")
		return ERR_CANT_ACQUIRE_RESOURCE

	# Load existing layout
	var layout := _load_layout_from_file(old_name)
	if not layout:
		return ERR_PARSE_ERROR

	# Update name and save as new
	layout.name = new_name
	layout.modified_at = int(Time.get_unix_time_from_system())

	var error := _save_layout_to_file(layout)
	if error != OK:
		return error

	# Delete old file
	error = delete_layout(old_name)
	if error != OK:
		# Rollback: delete the new file
		DirAccess.open(LAYOUTS_DIR).remove(new_name + LAYOUT_EXTENSION)
		return error

	_refresh_layout_names()
	layouts_changed.emit()

	return OK


## Duplicate a layout
func duplicate_layout(source_name: String, new_name: String) -> Error:
	if not has_layout(source_name):
		return ERR_FILE_NOT_FOUND

	if has_layout(new_name):
		return ERR_ALREADY_EXISTS

	# Load existing layout
	var layout := _load_layout_from_file(source_name)
	if not layout:
		return ERR_PARSE_ERROR

	# Update name and timestamps
	layout.name = new_name
	layout.created_at = int(Time.get_unix_time_from_system())
	layout.modified_at = layout.created_at

	var error := _save_layout_to_file(layout)
	if error == OK:
		_refresh_layout_names()
		layout_saved.emit(new_name)
		layouts_changed.emit()

	return error


## Get layout info without loading all panel data
func get_layout_info(layout_name: String) -> Dictionary:
	if not has_layout(layout_name):
		return {}

	var layout := _load_layout_from_file(layout_name)
	if not layout:
		return {}

	return {
		"name": layout.name,
		"created_at": layout.created_at,
		"modified_at": layout.modified_at,
		"panel_count": layout.panels.size(),
		"metadata": layout.metadata
	}


## Quick save current layout to default
func quick_save() -> Error:
	return save_layout(DEFAULT_LAYOUT_NAME)


## Quick load default layout
func quick_load() -> Error:
	return await load_layout(DEFAULT_LAYOUT_NAME)


## Save current layout and store for auto-restore on next session
func save_session_layout() -> Error:
	return save_layout("_session")


## Restore session layout if it exists
func restore_session_layout() -> Error:
	if has_layout("_session"):
		return await load_layout("_session")
	elif has_layout(DEFAULT_LAYOUT_NAME):
		return await load_layout(DEFAULT_LAYOUT_NAME)
	return ERR_FILE_NOT_FOUND
