extends Node


## PanelRegistry - Autoload singleton for tracking and managing active panels
##
## Maintains a registry of all active WorkspacePanel instances in the scene.
## Provides panel creation, lookup, and lifecycle management.


const ProjectSpawnMenuScript = preload("res://components/spawn_menu/project_spawn_menu.gd")


## Emitted when a panel is registered
signal panel_registered(panel: WorkspacePanel)

## Emitted when a panel is unregistered
signal panel_unregistered(panel_id: int)

## Emitted when the active panel count changes
signal panel_count_changed(count: int)


## Panel type definitions with metadata
const PANEL_TYPES := {
	"workspace": {
		"name": "Workspace Panel",
		"description": "General purpose workspace panel",
		"scene": "res://components/workspace_panel/workspace_panel.tscn",
		"script": "res://components/workspace_panel/workspace_panel.gd",
		"default_size": Vector2(1.0, 0.75),
		"icon": "📋"
	},
	"terminal": {
		"name": "Terminal",
		"description": "Terminal output with ANSI support",
		"scene": "res://components/terminal_panel/terminal_panel.tscn",
		"script": "res://components/terminal_panel/terminal_panel.gd",
		"default_size": Vector2(1.2, 0.8),
		"icon": "💻"
	},
	"agent_spawn": {
		"name": "Spawn Agent",
		"description": "Spawn a new agent session with terminal",
		"scene": "res://components/spawn_menu/project_spawn_menu.gd",
		"script": "res://components/spawn_menu/project_spawn_menu.gd",
		"default_size": Vector2(0.6, 0.7),
		"icon": "🚀"
	},
	"demo": {
		"name": "Demo Panel",
		"description": "Interactive demo panel for testing",
		"scene": "res://components/workspace_panel/workspace_panel.tscn",
		"script": "res://components/workspace_panel/workspace_panel.gd",
		"content_scene": "res://components/workspace_panel/demo_content.tscn",
		"default_size": Vector2(1.2, 0.9),
		"icon": "🎮"
	}
}

## Default spawn distance from camera (meters)
const DEFAULT_SPAWN_DISTANCE := 1.5

## Default spawn height offset from camera (meters)
const DEFAULT_SPAWN_HEIGHT_OFFSET := -0.2

## Minimum distance between spawned panels
const MIN_PANEL_SPACING := 0.3


# Internal registry
var _panels: Dictionary = {}  # panel_id -> WeakRef
var _next_panel_id: int = 1
var _panel_positions: Array[Vector3] = []


func _ready() -> void:
	# Ensure we're set as autoload
	process_mode = Node.PROCESS_MODE_ALWAYS


## Register a panel with the registry
func register_panel(panel: WorkspacePanel) -> int:
	var panel_id := _next_panel_id
	_next_panel_id += 1

	_panels[panel_id] = weakref(panel)
	_panel_positions.append(panel.global_position)

	# Connect to panel closed signal for auto-unregister
	if not panel.closed.is_connected(_on_panel_closed.bind(panel_id)):
		panel.closed.connect(_on_panel_closed.bind(panel_id))

	# Store panel ID on the panel for later lookup
	panel.set_meta("panel_registry_id", panel_id)

	panel_registered.emit(panel)
	panel_count_changed.emit(get_panel_count())

	return panel_id


## Unregister a panel from the registry
func unregister_panel(panel_id: int) -> void:
	if _panels.has(panel_id):
		var panel_ref: WeakRef = _panels[panel_id]
		var panel = panel_ref.get_ref()
		if panel:
			var idx := _panel_positions.find(panel.global_position)
			if idx >= 0:
				_panel_positions.remove_at(idx)

		_panels.erase(panel_id)
		panel_unregistered.emit(panel_id)
		panel_count_changed.emit(get_panel_count())


## Get a panel by ID
func get_panel(panel_id: int) -> WorkspacePanel:
	if _panels.has(panel_id):
		var panel_ref: WeakRef = _panels[panel_id]
		return panel_ref.get_ref()
	return null


## Get all active panels
func get_all_panels() -> Array[WorkspacePanel]:
	var result: Array[WorkspacePanel] = []
	var to_remove: Array[int] = []

	for panel_id in _panels:
		var panel_ref: WeakRef = _panels[panel_id]
		var panel = panel_ref.get_ref()
		if panel:
			result.append(panel)
		else:
			to_remove.append(panel_id)

	# Clean up dead references
	for panel_id in to_remove:
		_panels.erase(panel_id)
		panel_unregistered.emit(panel_id)

	if to_remove.size() > 0:
		panel_count_changed.emit(get_panel_count())

	return result


## Get the number of active panels
func get_panel_count() -> int:
	_cleanup_dead_refs()
	return _panels.size()


## Get available panel types
func get_panel_types() -> Array[String]:
	var types: Array[String] = []
	for key in PANEL_TYPES:
		types.append(key)
	return types


## Get metadata for a panel type
func get_panel_type_info(type_key: String) -> Dictionary:
	if PANEL_TYPES.has(type_key):
		return PANEL_TYPES[type_key].duplicate()
	return {}


## Create and spawn a panel of the given type
func spawn_panel(type_key: String, spawn_transform: Transform3D, parent: Node3D = null) -> WorkspacePanel:
	if not PANEL_TYPES.has(type_key):
		push_error("PanelRegistry: Unknown panel type '%s'" % type_key)
		return null

	var type_info: Dictionary = PANEL_TYPES[type_key]
	var panel: WorkspacePanel = null

	# Create panel based on type
	if type_key == "terminal":
		panel = TerminalPanel.new()
	elif type_key == "agent_spawn":
		panel = ProjectSpawnMenuScript.new()
	else:
		panel = WorkspacePanel.new()
		if type_info.has("content_scene"):
			panel.content_scene = load(type_info["content_scene"])

	# Configure panel
	panel.panel_size = type_info.get("default_size", Vector2(1.0, 0.75))
	panel.title = type_info.get("name", "Panel")

	# Add to scene
	if parent:
		parent.add_child(panel)
	else:
		get_tree().current_scene.add_child(panel)

	# Set transform after adding to scene
	panel.global_transform = spawn_transform

	# Register the panel
	register_panel(panel)

	return panel


## Calculate spawn position in front of camera
func calculate_spawn_position(camera: XRCamera3D, distance: float = DEFAULT_SPAWN_DISTANCE) -> Transform3D:
	if not camera:
		push_error("PanelRegistry: Cannot calculate spawn position without camera")
		return Transform3D.IDENTITY

	# Get camera transform
	var camera_transform := camera.global_transform
	var forward := -camera_transform.basis.z.normalized()

	# Calculate spawn position in front of camera
	var spawn_pos := camera_transform.origin + forward * distance
	spawn_pos.y += DEFAULT_SPAWN_HEIGHT_OFFSET  # Slightly below eye level

	# Adjust for nearby panels
	spawn_pos = _find_clear_position(spawn_pos)

	# Create transform facing the camera
	var spawn_transform := Transform3D.IDENTITY
	spawn_transform.origin = spawn_pos

	# Face the camera (rotate to look at camera position, then flip)
	var look_dir := camera_transform.origin - spawn_pos
	look_dir.y = 0  # Keep panel upright
	if look_dir.length() > 0.01:
		look_dir = look_dir.normalized()
		spawn_transform = spawn_transform.looking_at(spawn_pos + look_dir, Vector3.UP)

	return spawn_transform


## Find a clear position that doesn't overlap with existing panels
func _find_clear_position(desired_pos: Vector3) -> Vector3:
	var pos := desired_pos
	var attempts := 0
	var max_attempts := 10

	while attempts < max_attempts:
		var too_close := false
		for existing_pos in _panel_positions:
			var distance := pos.distance_to(existing_pos)
			if distance < MIN_PANEL_SPACING:
				too_close = true
				break

		if not too_close:
			return pos

		# Offset position slightly to the right and down
		pos.x += MIN_PANEL_SPACING * 0.5
		pos.y -= MIN_PANEL_SPACING * 0.3
		attempts += 1

	return pos


## Close all panels
func close_all_panels() -> void:
	var panels := get_all_panels()
	for panel in panels:
		panel.close()


## Close a specific panel by ID
func close_panel(panel_id: int) -> void:
	var panel := get_panel(panel_id)
	if panel:
		panel.close()


func _on_panel_closed(panel_id: int) -> void:
	unregister_panel(panel_id)


func _cleanup_dead_refs() -> void:
	var to_remove: Array[int] = []
	for panel_id in _panels:
		var panel_ref: WeakRef = _panels[panel_id]
		if not panel_ref.get_ref():
			to_remove.append(panel_id)

	for panel_id in to_remove:
		_panels.erase(panel_id)
