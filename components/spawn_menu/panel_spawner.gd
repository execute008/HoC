class_name PanelSpawner
extends Node3D


## PanelSpawner - Manages spawn menu display and panel spawning from VR controllers
##
## Listens for menu button input on VR controllers and shows/hides the spawn menu.
## Handles positioning the menu at a comfortable distance in front of the user.


const SpawnMenuScript = preload("res://components/spawn_menu/spawn_menu.gd")
const ProjectSpawnMenuScript = preload("res://components/spawn_menu/project_spawn_menu.gd")


## Emitted when the spawn menu is opened
signal menu_opened

## Emitted when the spawn menu is closed
signal menu_closed

## Emitted when a panel is spawned
signal panel_spawned(panel: WorkspacePanel, type_key: String)

## Emitted when an agent is spawned
signal agent_spawned(agent_id: String, terminal: TerminalPanel)


## The controller that triggers the spawn menu (left or right)
@export_enum("left", "right") var trigger_controller: String = "left"

## The action name for the menu button
@export var menu_action: String = "by_button"

## Distance from camera to spawn the menu (meters)
@export var menu_spawn_distance: float = 0.8

## Height offset for menu spawn position (meters)
@export var menu_height_offset: float = 0.0

## Which menu to show: project spawn menu (agents) or basic panel spawn menu
@export_enum("project", "basic") var menu_type: String = "project"


# Internal state
var _spawn_menu: Node3D = null  # SpawnMenu or ProjectSpawnMenu instance
var _xr_camera: XRCamera3D = null
var _controller: XRController3D = null
var _menu_button_pressed: bool = false


func _ready() -> void:
	_find_xr_nodes()


func _process(_delta: float) -> void:
	if not _controller:
		return

	# Check for menu button press
	var is_pressed := _controller.is_button_pressed(menu_action)

	if is_pressed and not _menu_button_pressed:
		_menu_button_pressed = true
		_toggle_spawn_menu()
	elif not is_pressed:
		_menu_button_pressed = false


func _find_xr_nodes() -> void:
	# Find XR origin first
	var xr_origin := _find_node_by_class(get_tree().root, "XROrigin3D")
	if not xr_origin:
		# Try again on next frame
		await get_tree().process_frame
		xr_origin = _find_node_by_class(get_tree().root, "XROrigin3D")

	if not xr_origin:
		push_warning("PanelSpawner: Could not find XROrigin3D")
		return

	# Find camera
	for child in xr_origin.get_children():
		if child is XRCamera3D:
			_xr_camera = child
			break

	# Find the specified controller
	for child in xr_origin.get_children():
		if child is XRController3D:
			var is_left := "left" in child.name.to_lower()
			var is_right := "right" in child.name.to_lower()

			if trigger_controller == "left" and is_left:
				_controller = child
				break
			elif trigger_controller == "right" and is_right:
				_controller = child
				break


func _find_node_by_class(node: Node, target_class: String) -> Node:
	if node.get_class() == target_class:
		return node
	for child in node.get_children():
		var result := _find_node_by_class(child, target_class)
		if result:
			return result
	return null


func _toggle_spawn_menu() -> void:
	if _spawn_menu and is_instance_valid(_spawn_menu):
		_close_spawn_menu()
	else:
		_open_spawn_menu()


func _open_spawn_menu() -> void:
	if not _xr_camera:
		_find_xr_nodes()

	if not _xr_camera:
		push_error("PanelSpawner: Cannot open menu without XR camera")
		return

	# Close existing menu if any
	if _spawn_menu and is_instance_valid(_spawn_menu):
		_spawn_menu.queue_free()
		_spawn_menu = null

	# Create spawn menu based on type
	if menu_type == "project":
		_spawn_menu = ProjectSpawnMenuScript.new()
	else:
		_spawn_menu = SpawnMenuScript.new()

	_spawn_menu.set_xr_camera(_xr_camera)

	# Add to scene
	get_tree().current_scene.add_child(_spawn_menu)

	# Position menu in front of camera
	var camera_transform := _xr_camera.global_transform
	var forward := -camera_transform.basis.z.normalized()

	var spawn_pos := camera_transform.origin + forward * menu_spawn_distance
	spawn_pos.y += menu_height_offset

	# Create transform facing the camera
	var look_dir := camera_transform.origin - spawn_pos
	look_dir.y = 0
	if look_dir.length() > 0.01:
		_spawn_menu.global_position = spawn_pos
		_spawn_menu.look_at(spawn_pos + look_dir.normalized(), Vector3.UP)
	else:
		_spawn_menu.global_position = spawn_pos

	# Connect signals
	_spawn_menu.closed.connect(_on_spawn_menu_closed)

	if menu_type == "project":
		_spawn_menu.agent_spawned.connect(_on_agent_spawned)
		_spawn_menu.spawn_failed.connect(_on_spawn_failed)
	else:
		_spawn_menu.panel_spawned.connect(_on_panel_spawned)

	menu_opened.emit()


func _close_spawn_menu() -> void:
	if _spawn_menu and is_instance_valid(_spawn_menu):
		_spawn_menu.close()


func _on_spawn_menu_closed() -> void:
	_spawn_menu = null
	menu_closed.emit()


func _on_panel_spawned(panel: WorkspacePanel, type_key: String) -> void:
	panel_spawned.emit(panel, type_key)


func _on_agent_spawned(agent_id: String, terminal: TerminalPanel) -> void:
	agent_spawned.emit(agent_id, terminal)


func _on_spawn_failed(error_message: String) -> void:
	push_error("PanelSpawner: Spawn failed - %s" % error_message)


## Check if the spawn menu is currently open
func is_menu_open() -> bool:
	return _spawn_menu != null and is_instance_valid(_spawn_menu)


## Manually open the spawn menu
func open_menu() -> void:
	if not is_menu_open():
		_open_spawn_menu()


## Manually close the spawn menu
func close_menu() -> void:
	if is_menu_open():
		_close_spawn_menu()


## Set the XR camera reference manually
func set_xr_camera(camera: XRCamera3D) -> void:
	_xr_camera = camera


## Set the controller reference manually
func set_controller(controller: XRController3D) -> void:
	_controller = controller
