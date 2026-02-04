class_name SpawnMenu
extends WorkspacePanel


## SpawnMenu - A floating menu panel for spawning new workspace panels
##
## Appears when the user presses the menu button on their VR controller.
## Displays available panel types and spawns them at comfortable viewing distance.


const SpawnMenuContentScript = preload("res://components/spawn_menu/spawn_menu_content.gd")


## Emitted when a panel is spawned from this menu
signal panel_spawned(panel: WorkspacePanel, type_key: String)


## Spawn menu content reference
var _menu_content: Control  # SpawnMenuContent instance


func _init() -> void:
	# Configure as a smaller, menu-style panel
	panel_size = Vector2(0.5, 0.6)
	title = "Spawn Panel"
	viewport_size = Vector2(400, 480)
	resizable = false
	billboard_mode = true


func _ready() -> void:
	# Set content scene before parent _ready
	content_scene = load("res://components/spawn_menu/spawn_menu_content.tscn")

	super._ready()

	# Connect to menu content after setup
	_connect_menu_content()


func _connect_menu_content() -> void:
	if not is_inside_tree():
		return

	await get_tree().process_frame

	var content_instance := get_content_scene_instance()
	if content_instance and content_instance.has_signal("panel_type_selected"):
		_menu_content = content_instance
		_menu_content.panel_type_selected.connect(_on_panel_type_selected)
		_menu_content.close_requested.connect(_on_close_requested)


func _on_panel_type_selected(type_key: String) -> void:
	_spawn_panel_of_type(type_key)


func _on_close_requested() -> void:
	close()


func _spawn_panel_of_type(type_key: String) -> void:
	if not _xr_camera:
		_find_xr_camera()

	if not _xr_camera:
		push_error("SpawnMenu: Cannot spawn panel without XR camera reference")
		return

	# Calculate spawn position
	var spawn_transform := PanelRegistry.calculate_spawn_position(_xr_camera)

	# Get the main scene as parent
	var parent := get_tree().current_scene

	# Spawn the panel
	var panel := PanelRegistry.spawn_panel(type_key, spawn_transform, parent)

	if panel:
		panel_spawned.emit(panel, type_key)

	# Close the menu after spawning
	close()


## Set the XR camera reference (for spawn position calculation)
func set_xr_camera(camera: XRCamera3D) -> void:
	_xr_camera = camera


## Refresh the menu content (useful if panel types change)
func refresh() -> void:
	if _menu_content:
		_menu_content.refresh_panel_list()
