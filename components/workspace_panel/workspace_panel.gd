@tool
class_name WorkspacePanel
extends Node3D


## WorkspacePanel - A grabbable, resizable 2D panel in 3D VR space
##
## This component provides a VR workspace panel that can be grabbed and moved
## with controllers, resized by grabbing corners/edges, and features a title bar
## with close/minimize controls.


## Emitted when the panel is closed
signal closed

## Emitted when the panel is minimized
signal minimized

## Emitted when the panel is grabbed
signal grabbed(by: Node3D)

## Emitted when the panel is released
signal released

## Emitted when the panel is resized
signal resized(new_size: Vector2)


## Minimum panel size
const MIN_SIZE := Vector2(0.3, 0.2)

## Maximum panel size
const MAX_SIZE := Vector2(5.0, 5.0)

## Title bar height in meters
const TITLE_BAR_HEIGHT := 0.08

## Handle size for resize corners/edges
const HANDLE_SIZE := 0.05

## Default collision layer for grabbable panels (layer 4)
const GRAB_LAYER := 0b0000_0000_0000_0000_0000_0000_0000_1000


@export_group("Panel")

## The physical size of the panel in meters (width x height)
@export var panel_size := Vector2(1.0, 0.75): set = set_panel_size

## The title displayed in the title bar
@export var title := "Panel": set = set_title

## The 2D scene to render in the panel content area
@export var content_scene: PackedScene: set = set_content_scene

## Viewport resolution for the content
@export var viewport_size := Vector2(800, 600): set = set_viewport_size

@export_group("Behavior")

## If true, the panel can be grabbed and moved
@export var grabbable := true: set = set_grabbable

## If true, the panel can be resized by grabbing corners/edges
@export var resizable := true: set = set_resizable

## If true, the panel will always face the user (XR camera)
@export var billboard_mode := false: set = set_billboard_mode

## If true, the panel will snap to grid positions when released
@export var snap_to_grid := false

## Grid size for snapping (in meters)
@export var grid_size := 0.25

@export_group("Appearance")

## Show the title bar
@export var show_title_bar := true: set = set_show_title_bar

## Show close button
@export var show_close_button := true: set = set_show_close_button

## Show minimize button
@export var show_minimize_button := true: set = set_show_minimize_button

## Panel background color
@export var background_color := Color(0.15, 0.15, 0.18, 0.95)

## Title bar color
@export var title_bar_color := Color(0.2, 0.2, 0.25, 1.0)


# Internal state
var _is_grabbed := false
var _grab_offset := Transform3D.IDENTITY
var _grabber: Node3D = null
var _is_minimized := false
var _original_size := Vector2.ZERO

# Node references
var _viewport_container: XRToolsViewport2DIn3D
var _title_bar: Node3D
var _grab_body: RigidBody3D
var _resize_handles: Array[RigidBody3D] = []
var _active_resize_handle: RigidBody3D = null
var _resize_start_size := Vector2.ZERO
var _resize_start_pos := Vector3.ZERO
var _xr_camera: XRCamera3D


func _ready() -> void:
	_setup_panel()
	_find_xr_camera()


func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		return

	# Handle billboard mode
	if billboard_mode and is_instance_valid(_xr_camera):
		_apply_billboard()

	# Handle active grab
	if _is_grabbed and is_instance_valid(_grabber):
		_update_grabbed_position()

	# Handle active resize
	if _active_resize_handle and is_instance_valid(_active_resize_handle):
		_update_resize()


func _setup_panel() -> void:
	# Create the viewport container for content
	_create_viewport_container()

	# Create the title bar
	if show_title_bar:
		_create_title_bar()

	# Create the main grab body
	if grabbable:
		_create_grab_body()

	# Create resize handles
	if resizable:
		_create_resize_handles()

	_update_layout()


func _create_viewport_container() -> void:
	# Load and instantiate the viewport 2D in 3D scene
	var viewport_scene = load("res://addons/godot-xr-tools/objects/viewport_2d_in_3d.tscn")
	if not viewport_scene:
		push_error("WorkspacePanel: Failed to load viewport_2d_in_3d.tscn — is godot-xr-tools installed?")
		return
	_viewport_container = viewport_scene.instantiate()
	_viewport_container.name = "ViewportContainer"

	# Add child first so viewport is ready before configuration
	add_child(_viewport_container)

	# Configure the viewport after adding to tree
	_viewport_container.screen_size = _get_content_size()
	_viewport_container.viewport_size = viewport_size
	_viewport_container.transparent = XRToolsViewport2DIn3D.TransparancyMode.TRANSPARENT
	_viewport_container.unshaded = true

	if content_scene:
		_viewport_container.scene = content_scene


func _create_title_bar() -> void:
	_title_bar = Node3D.new()
	_title_bar.name = "TitleBar"
	add_child(_title_bar)

	# Create title bar mesh
	var mesh_instance = MeshInstance3D.new()
	mesh_instance.name = "TitleBarMesh"
	var quad_mesh = QuadMesh.new()
	quad_mesh.size = Vector2(panel_size.x, TITLE_BAR_HEIGHT)
	mesh_instance.mesh = quad_mesh

	# Create title bar material
	var mat = StandardMaterial3D.new()
	mat.albedo_color = title_bar_color
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh_instance.material_override = mat

	_title_bar.add_child(mesh_instance)

	# Create title bar viewport for text and buttons
	_create_title_bar_ui()


func _create_title_bar_ui() -> void:
	# Create a small viewport for title bar UI
	var title_viewport = SubViewport.new()
	title_viewport.name = "TitleViewport"
	title_viewport.size = Vector2i(int(panel_size.x * 400), int(TITLE_BAR_HEIGHT * 400))
	title_viewport.transparent_bg = true
	title_viewport.disable_3d = true
	title_viewport.gui_embed_subwindows = true
	_title_bar.add_child(title_viewport)

	# Create HBoxContainer for layout
	var hbox = HBoxContainer.new()
	hbox.name = "TitleBarContent"
	hbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	hbox.add_theme_constant_override("separation", 8)
	title_viewport.add_child(hbox)

	# Title label
	var label = Label.new()
	label.name = "TitleLabel"
	label.text = title
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 24)
	label.add_theme_color_override("font_color", Color.WHITE)
	hbox.add_child(label)

	# Spacer
	var spacer = Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(spacer)

	# Minimize button
	if show_minimize_button:
		var minimize_btn = Button.new()
		minimize_btn.name = "MinimizeButton"
		minimize_btn.text = "_"
		minimize_btn.custom_minimum_size = Vector2(32, 32)
		minimize_btn.pressed.connect(_on_minimize_pressed)
		hbox.add_child(minimize_btn)

	# Close button
	if show_close_button:
		var close_btn = Button.new()
		close_btn.name = "CloseButton"
		close_btn.text = "X"
		close_btn.custom_minimum_size = Vector2(32, 32)
		close_btn.pressed.connect(_on_close_pressed)
		hbox.add_child(close_btn)

	# Create mesh to display title viewport
	var title_screen = MeshInstance3D.new()
	title_screen.name = "TitleScreen"
	var title_quad = QuadMesh.new()
	title_quad.size = Vector2(panel_size.x, TITLE_BAR_HEIGHT)
	title_screen.mesh = title_quad
	title_screen.position.z = 0.001  # Slightly in front

	_title_bar.add_child(title_screen)

	# Set material after adding to tree so viewport texture is valid
	var title_mat = StandardMaterial3D.new()
	title_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	title_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	title_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	title_mat.albedo_texture = title_viewport.get_texture()
	title_screen.material_override = title_mat


func _create_grab_body() -> void:
	_grab_body = RigidBody3D.new()
	_grab_body.name = "GrabBody"
	_grab_body.freeze = true
	_grab_body.collision_layer = GRAB_LAYER
	_grab_body.collision_mask = 0

	# Add collision shape covering the title bar area for grabbing
	var collision = CollisionShape3D.new()
	collision.name = "GrabCollision"
	var box_shape = BoxShape3D.new()
	box_shape.size = Vector3(panel_size.x, TITLE_BAR_HEIGHT, 0.02)
	collision.shape = box_shape
	_grab_body.add_child(collision)

	# Add XRToolsPickable script for grab detection
	var pickable_script = load("res://addons/godot-xr-tools/objects/pickable.gd")
	_grab_body.set_script(pickable_script)
	_grab_body.enabled = true
	_grab_body.press_to_hold = true

	# Connect signals
	_grab_body.picked_up.connect(_on_grabbed)
	_grab_body.dropped.connect(_on_released)

	add_child(_grab_body)


func _create_resize_handles() -> void:
	# Create handles at corners and edges
	var handle_positions = [
		# Corners
		{"name": "TopLeft", "pos": Vector3(-panel_size.x/2, panel_size.y/2, 0), "resize_dir": Vector2(-1, 1)},
		{"name": "TopRight", "pos": Vector3(panel_size.x/2, panel_size.y/2, 0), "resize_dir": Vector2(1, 1)},
		{"name": "BottomLeft", "pos": Vector3(-panel_size.x/2, -panel_size.y/2, 0), "resize_dir": Vector2(-1, -1)},
		{"name": "BottomRight", "pos": Vector3(panel_size.x/2, -panel_size.y/2, 0), "resize_dir": Vector2(1, -1)},
		# Edges
		{"name": "Left", "pos": Vector3(-panel_size.x/2, 0, 0), "resize_dir": Vector2(-1, 0)},
		{"name": "Right", "pos": Vector3(panel_size.x/2, 0, 0), "resize_dir": Vector2(1, 0)},
		{"name": "Top", "pos": Vector3(0, panel_size.y/2, 0), "resize_dir": Vector2(0, 1)},
		{"name": "Bottom", "pos": Vector3(0, -panel_size.y/2, 0), "resize_dir": Vector2(0, -1)},
	]

	for handle_data in handle_positions:
		var handle = _create_single_resize_handle(handle_data)
		_resize_handles.append(handle)
		add_child(handle)


func _create_single_resize_handle(data: Dictionary) -> RigidBody3D:
	var handle = RigidBody3D.new()
	handle.name = "ResizeHandle_" + data["name"]
	handle.freeze = true
	handle.collision_layer = GRAB_LAYER
	handle.collision_mask = 0
	handle.position = data["pos"]
	handle.set_meta("resize_dir", data["resize_dir"])

	# Create collision shape
	var collision = CollisionShape3D.new()
	var sphere_shape = SphereShape3D.new()
	sphere_shape.radius = HANDLE_SIZE
	collision.shape = sphere_shape
	handle.add_child(collision)

	# Add pickable script
	var pickable_script = load("res://addons/godot-xr-tools/objects/pickable.gd")
	handle.set_script(pickable_script)
	handle.enabled = true
	handle.press_to_hold = true

	# Connect signals
	handle.picked_up.connect(_on_resize_handle_grabbed.bind(handle))
	handle.dropped.connect(_on_resize_handle_released.bind(handle))

	return handle


func _update_layout() -> void:
	var content_size = _get_content_size()
	var title_bar_offset = TITLE_BAR_HEIGHT / 2 if show_title_bar else 0.0

	# Position viewport container (centered on content area)
	if _viewport_container:
		_viewport_container.screen_size = content_size
		_viewport_container.position.y = -title_bar_offset

	# Position title bar
	if _title_bar and show_title_bar:
		_title_bar.position.y = (panel_size.y / 2)
		_update_title_bar_size()

	# Position grab body on title bar
	if _grab_body and show_title_bar:
		_grab_body.position.y = (panel_size.y / 2)
		var collision = _grab_body.get_node_or_null("GrabCollision")
		if collision and collision.shape:
			collision.shape.size = Vector3(panel_size.x, TITLE_BAR_HEIGHT, 0.02)

	# Update resize handle positions
	_update_resize_handle_positions()


func _update_title_bar_size() -> void:
	if not _title_bar:
		return

	var mesh = _title_bar.get_node_or_null("TitleBarMesh")
	if mesh and mesh.mesh:
		mesh.mesh.size = Vector2(panel_size.x, TITLE_BAR_HEIGHT)

	var title_screen = _title_bar.get_node_or_null("TitleScreen")
	if title_screen and title_screen.mesh:
		title_screen.mesh.size = Vector2(panel_size.x, TITLE_BAR_HEIGHT)

	var title_viewport = _title_bar.get_node_or_null("TitleViewport")
	if title_viewport:
		title_viewport.size = Vector2i(int(panel_size.x * 400), int(TITLE_BAR_HEIGHT * 400))


func _update_resize_handle_positions() -> void:
	var content_size = _get_content_size()
	var y_offset = -TITLE_BAR_HEIGHT / 2 if show_title_bar else 0.0

	var positions = {
		"TopLeft": Vector3(-panel_size.x/2, content_size.y/2 + y_offset, 0),
		"TopRight": Vector3(panel_size.x/2, content_size.y/2 + y_offset, 0),
		"BottomLeft": Vector3(-panel_size.x/2, -content_size.y/2 + y_offset, 0),
		"BottomRight": Vector3(panel_size.x/2, -content_size.y/2 + y_offset, 0),
		"Left": Vector3(-panel_size.x/2, y_offset, 0),
		"Right": Vector3(panel_size.x/2, y_offset, 0),
		"Top": Vector3(0, content_size.y/2 + y_offset, 0),
		"Bottom": Vector3(0, -content_size.y/2 + y_offset, 0),
	}

	for handle in _resize_handles:
		var handle_name = handle.name.replace("ResizeHandle_", "")
		if positions.has(handle_name):
			handle.position = positions[handle_name]


func _get_content_size() -> Vector2:
	var height = panel_size.y
	if show_title_bar:
		height -= TITLE_BAR_HEIGHT
	return Vector2(panel_size.x, height)


func _find_xr_camera() -> void:
	# Try to find the XR camera in the scene
	var viewport = get_viewport()
	if viewport:
		_xr_camera = Utils.find_node_by_class(viewport, "XRCamera3D")


func _apply_billboard() -> void:
	if not is_instance_valid(_xr_camera):
		return

	# Look at camera but only rotate on Y axis for a more comfortable viewing
	var camera_pos = _xr_camera.global_position
	var panel_pos = global_position

	# Calculate direction to camera (only horizontal)
	var direction = camera_pos - panel_pos
	direction.y = 0

	if direction.length() > 0.01:
		direction = direction.normalized()
		# Face the camera
		var target_pos = panel_pos + direction
		look_at(target_pos, Vector3.UP)
		# Flip to face camera (look_at points -Z at target)
		rotate_y(PI)


func _update_grabbed_position() -> void:
	# Update panel position based on grabber position
	global_transform = _grabber.global_transform * _grab_offset

	# Apply grid snapping on release (handled in _on_released)


func _update_resize() -> void:
	if not _active_resize_handle:
		return

	var resize_dir: Vector2 = _active_resize_handle.get_meta("resize_dir")
	var handle_world_pos = _active_resize_handle.global_position
	var local_pos = to_local(handle_world_pos)

	# Calculate new size based on handle position
	var delta = Vector2(local_pos.x, local_pos.y) - Vector2(_resize_start_pos.x, _resize_start_pos.y)

	var new_size = _resize_start_size
	if resize_dir.x != 0:
		new_size.x += delta.x * resize_dir.x * 2
	if resize_dir.y != 0:
		new_size.y += delta.y * resize_dir.y * 2

	# Clamp to min/max size
	new_size = new_size.clamp(MIN_SIZE, MAX_SIZE)

	# Apply new size
	set_panel_size(new_size)


# Signal handlers
func _on_grabbed(pickable: Node3D) -> void:
	_is_grabbed = true
	_grabber = pickable.get_picked_up_by()

	# Calculate offset between grabber and panel
	if _grabber:
		_grab_offset = _grabber.global_transform.affine_inverse() * global_transform

	grabbed.emit(_grabber)


func _on_released(pickable: Node3D) -> void:
	_is_grabbed = false

	# Apply grid snapping if enabled
	if snap_to_grid and grid_size > 0:
		var pos = global_position
		pos.x = round(pos.x / grid_size) * grid_size
		pos.y = round(pos.y / grid_size) * grid_size
		pos.z = round(pos.z / grid_size) * grid_size
		global_position = pos

	_grabber = null
	released.emit()


func _on_resize_handle_grabbed(pickable: Node3D, handle: RigidBody3D) -> void:
	_active_resize_handle = handle
	_resize_start_size = panel_size
	_resize_start_pos = to_local(handle.global_position)


func _on_resize_handle_released(pickable: Node3D, handle: RigidBody3D) -> void:
	if _active_resize_handle == handle:
		_active_resize_handle = null
		resized.emit(panel_size)


func _on_minimize_pressed() -> void:
	toggle_minimize()


func _on_close_pressed() -> void:
	close()


# Public API
func set_panel_size(new_size: Vector2) -> void:
	panel_size = new_size.clamp(MIN_SIZE, MAX_SIZE)
	if is_inside_tree():
		_update_layout()


func set_title(new_title: String) -> void:
	title = new_title
	if _title_bar:
		var title_viewport = _title_bar.get_node_or_null("TitleViewport")
		if title_viewport:
			var label = title_viewport.get_node_or_null("TitleBarContent/TitleLabel")
			if label:
				label.text = title


func set_content_scene(new_scene: PackedScene) -> void:
	content_scene = new_scene
	if _viewport_container:
		_viewport_container.scene = new_scene


func set_viewport_size(new_size: Vector2) -> void:
	viewport_size = new_size
	if _viewport_container:
		_viewport_container.viewport_size = new_size


func set_grabbable(value: bool) -> void:
	grabbable = value
	if _grab_body:
		_grab_body.enabled = value


func set_resizable(value: bool) -> void:
	resizable = value
	for handle in _resize_handles:
		handle.enabled = value


func set_billboard_mode(value: bool) -> void:
	billboard_mode = value


func set_show_title_bar(value: bool) -> void:
	show_title_bar = value
	if _title_bar:
		_title_bar.visible = value
	if is_inside_tree():
		_update_layout()


func set_show_close_button(value: bool) -> void:
	show_close_button = value


func set_show_minimize_button(value: bool) -> void:
	show_minimize_button = value


## Toggle the minimized state of the panel
func toggle_minimize() -> void:
	if _is_minimized:
		restore()
	else:
		minimize()


## Minimize the panel (collapse to title bar only)
func minimize() -> void:
	if _is_minimized:
		return

	_is_minimized = true
	_original_size = panel_size

	if _viewport_container:
		_viewport_container.visible = false

	for handle in _resize_handles:
		handle.visible = false

	minimized.emit()


## Restore the panel from minimized state
func restore() -> void:
	if not _is_minimized:
		return

	_is_minimized = false

	if _viewport_container:
		_viewport_container.visible = true

	for handle in _resize_handles:
		handle.visible = resizable

	if _original_size != Vector2.ZERO:
		set_panel_size(_original_size)


## Close the panel
func close() -> void:
	closed.emit()
	queue_free()


## Get the content viewport for direct access
func get_content_viewport() -> SubViewport:
	if _viewport_container:
		return _viewport_container.get_node_or_null("Viewport")
	return null


## Get the 2D scene instance
func get_content_scene_instance() -> Node:
	if _viewport_container:
		return _viewport_container.get_scene_instance()
	return null
