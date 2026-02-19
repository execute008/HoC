class_name VRKeyboard
extends Node3D


## VRKeyboard - A 3D virtual QWERTY keyboard for VR text input
##
## Renders a keyboard as a 2D UI inside a SubViewport projected onto a
## 3D quad. Supports letters, numbers, symbols, backspace, enter, shift,
## and space. Sends keystrokes to the focused terminal panel via InputRouter.


## Emitted when a key is pressed (before routing)
signal key_pressed(text: String)

## Emitted when the keyboard is dismissed
signal dismissed


# =============================================================================
# Constants
# =============================================================================

## Physical size of the keyboard in meters
const KEYBOARD_SIZE := Vector2(0.8, 0.3)

## Viewport resolution
const VIEWPORT_RESOLUTION := Vector2i(800, 300)

## Key dimensions
const KEY_WIDTH := 64
const KEY_HEIGHT := 56
const KEY_SPACING := 4
const ROW_SPACING := 4
const MARGIN_LEFT := 12
const MARGIN_TOP := 8

## Colors
const BG_COLOR := Color(0.12, 0.12, 0.15, 0.95)
const KEY_COLOR := Color(0.22, 0.22, 0.28)
const KEY_HOVER := Color(0.32, 0.32, 0.4)
const KEY_PRESSED_COLOR := Color(0.4, 0.5, 0.8)
const KEY_SPECIAL_COLOR := Color(0.18, 0.18, 0.24)
const KEY_ACTIVE_COLOR := Color(0.3, 0.45, 0.7)
const TEXT_COLOR := Color(0.95, 0.95, 0.98)

## Keyboard rows (lowercase)
const ROWS_LOWER := [
	["1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "-", "="],
	["q", "w", "e", "r", "t", "y", "u", "i", "o", "p", "[", "]"],
	["a", "s", "d", "f", "g", "h", "j", "k", "l", ";", "'"],
	["z", "x", "c", "v", "b", "n", "m", ",", ".", "/"],
]

## Keyboard rows (uppercase / shifted)
const ROWS_UPPER := [
	["!", "@", "#", "$", "%", "^", "&", "*", "(", ")", "_", "+"],
	["Q", "W", "E", "R", "T", "Y", "U", "I", "O", "P", "{", "}"],
	["A", "S", "D", "F", "G", "H", "J", "K", "L", ":", "\""],
	["Z", "X", "C", "V", "B", "N", "M", "<", ">", "?"],
]


# =============================================================================
# State
# =============================================================================

var _viewport: SubViewport
var _screen_mesh: MeshInstance3D
var _collision_body: StaticBody3D
var _panel_container: PanelContainer
var _key_buttons: Array[Button] = []
var _shift_active: bool = false
var _shift_button: Button = null
var _input_router: Node = null

## The panel this keyboard is attached to
var _target_panel: Node3D = null


# =============================================================================
# Lifecycle
# =============================================================================

func _ready() -> void:
	_input_router = get_node_or_null("/root/InputRouter")
	_build_3d_surface()
	_build_keyboard_ui()


# =============================================================================
# 3D Surface
# =============================================================================

func _build_3d_surface() -> void:
	# SubViewport
	_viewport = SubViewport.new()
	_viewport.name = "KeyboardViewport"
	_viewport.size = VIEWPORT_RESOLUTION
	_viewport.transparent_bg = true
	_viewport.disable_3d = true
	_viewport.gui_embed_subwindows = true
	add_child(_viewport)

	# Screen quad
	_screen_mesh = MeshInstance3D.new()
	_screen_mesh.name = "Screen"
	var quad := QuadMesh.new()
	quad.size = KEYBOARD_SIZE
	_screen_mesh.mesh = quad
	add_child(_screen_mesh)

	# Material - will set texture after viewport is ready
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_texture = _viewport.get_texture()
	_screen_mesh.material_override = mat

	# Collision for pointer interaction
	_collision_body = StaticBody3D.new()
	_collision_body.name = "KeyboardBody"
	_collision_body.collision_layer = 0b0000_0000_0000_0000_0000_0100_0000_0000  # layer 11
	_collision_body.collision_mask = 0
	add_child(_collision_body)

	var collision_shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(KEYBOARD_SIZE.x, KEYBOARD_SIZE.y, 0.01)
	collision_shape.shape = box
	_collision_body.add_child(collision_shape)

	# Add viewport_2d_in_3d-style input forwarding via the body
	var screen_size_prop := KEYBOARD_SIZE
	var viewport_size_prop := Vector2(VIEWPORT_RESOLUTION)
	_collision_body.set_meta("screen_size", screen_size_prop)
	_collision_body.set_meta("viewport_size", viewport_size_prop)
	_collision_body.set_meta("viewport", _viewport)

	# Use XRToolsViewport2DIn3D if available, otherwise manual setup
	_setup_input_forwarding()


func _setup_input_forwarding() -> void:
	# Load the viewport_2d_in_3d scene for proper XR pointer interaction
	var vp_scene = load("res://addons/godot-xr-tools/objects/viewport_2d_in_3d.tscn")
	if not vp_scene:
		push_warning("VRKeyboard: XR viewport scene not found, using manual input")
		return

	# We already built our own viewport, so we add input handling to the body
	# The XR pointer function will detect collisions and route events
	# We just need the collision body set up (done above)

	# Make the StaticBody3D detectable by XR pointer
	# The function_pointer checks for viewport_2d_in_3d nodes
	# We replicate the needed interface on our collision body
	var pointer_script_text := """
extends StaticBody3D

var screen_size: Vector2 = Vector2(%f, %f)
var viewport_size: Vector2 = Vector2(%f, %f)

func get_viewport_for_point(p_at: Vector3) -> SubViewport:
	return get_meta("viewport") as SubViewport

func convert_point(p_at: Vector3) -> Vector2:
	var local := p_at
	var x_ratio := (local.x / screen_size.x) + 0.5
	var y_ratio := 0.5 - (local.y / screen_size.y)
	return Vector2(x_ratio * viewport_size.x, y_ratio * viewport_size.y)
""" % [KEYBOARD_SIZE.x, KEYBOARD_SIZE.y, VIEWPORT_RESOLUTION.x, VIEWPORT_RESOLUTION.y]

	# Instead of a dynamic script, configure the body metadata
	# XR pointer uses viewport_2d_in_3d which is on the parent.
	# We'll use the simpler approach: instantiate the XR viewport scene
	# and let it handle everything.

	# Remove our manual setup and use XRToolsViewport2DIn3D instead
	_screen_mesh.queue_free()
	_collision_body.queue_free()

	var xr_viewport: XRToolsViewport2DIn3D = vp_scene.instantiate()
	xr_viewport.name = "XRViewportContainer"
	xr_viewport.screen_size = KEYBOARD_SIZE
	xr_viewport.viewport_size = VIEWPORT_RESOLUTION
	xr_viewport.transparent = XRToolsViewport2DIn3D.TransparancyMode.TRANSPARENT
	xr_viewport.unshaded = true
	add_child(xr_viewport)

	# Re-parent our UI to the XRTools viewport
	if _viewport:
		_viewport.queue_free()

	# Wait a frame for the XR viewport to initialize, then add our UI
	await get_tree().process_frame
	var vp_node: SubViewport = xr_viewport.get_node_or_null("Viewport")
	if vp_node:
		_viewport = vp_node
		_build_keyboard_ui()


# =============================================================================
# Keyboard UI
# =============================================================================

func _build_keyboard_ui() -> void:
	if not _viewport:
		return

	# Clear any existing UI
	for child in _viewport.get_children():
		if child is Control:
			child.queue_free()

	_key_buttons.clear()

	# Background
	_panel_container = PanelContainer.new()
	_panel_container.name = "KeyboardBG"
	_panel_container.set_anchors_preset(Control.PRESET_FULL_RECT)
	var bg_style := StyleBoxFlat.new()
	bg_style.bg_color = BG_COLOR
	bg_style.set_corner_radius_all(8)
	_panel_container.add_theme_stylebox_override("panel", bg_style)
	_viewport.add_child(_panel_container)

	var main_vbox := VBoxContainer.new()
	main_vbox.name = "Rows"
	main_vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	main_vbox.add_theme_constant_override("separation", ROW_SPACING)
	_panel_container.add_child(main_vbox)

	# Add margin
	var margin := MarginContainer.new()
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	margin.add_theme_constant_override("margin_left", MARGIN_LEFT)
	margin.add_theme_constant_override("margin_right", MARGIN_LEFT)
	margin.add_theme_constant_override("margin_top", MARGIN_TOP)
	margin.add_theme_constant_override("margin_bottom", MARGIN_TOP)
	main_vbox.add_child(margin)

	var rows_container := VBoxContainer.new()
	rows_container.add_theme_constant_override("separation", ROW_SPACING)
	margin.add_child(rows_container)

	# Character rows
	var rows := ROWS_LOWER if not _shift_active else ROWS_UPPER
	for row_idx in range(rows.size()):
		var row_hbox := HBoxContainer.new()
		row_hbox.add_theme_constant_override("separation", KEY_SPACING)
		row_hbox.alignment = BoxContainer.ALIGNMENT_CENTER
		rows_container.add_child(row_hbox)

		# Shift key on row 3 (index 3)
		if row_idx == 3:
			_shift_button = _create_key_button("⇧", KEY_WIDTH * 1.5, true)
			_shift_button.pressed.connect(_on_shift_pressed)
			if _shift_active:
				_apply_active_style(_shift_button)
			row_hbox.add_child(_shift_button)

		for key_text in rows[row_idx]:
			var btn := _create_key_button(key_text, KEY_WIDTH, false)
			btn.pressed.connect(_on_char_key_pressed.bind(key_text))
			row_hbox.add_child(btn)
			_key_buttons.append(btn)

		# Backspace on row 0
		if row_idx == 0:
			var bksp := _create_key_button("⌫", KEY_WIDTH * 1.5, true)
			bksp.pressed.connect(_on_backspace_pressed)
			row_hbox.add_child(bksp)

		# Enter on row 2
		if row_idx == 2:
			var enter := _create_key_button("⏎", KEY_WIDTH * 1.5, true)
			enter.pressed.connect(_on_enter_pressed)
			row_hbox.add_child(enter)

	# Bottom row: Tab, Space, Esc, Dismiss
	var bottom_row := HBoxContainer.new()
	bottom_row.add_theme_constant_override("separation", KEY_SPACING)
	bottom_row.alignment = BoxContainer.ALIGNMENT_CENTER
	rows_container.add_child(bottom_row)

	var tab_btn := _create_key_button("Tab", KEY_WIDTH * 1.2, true)
	tab_btn.pressed.connect(_on_tab_pressed)
	bottom_row.add_child(tab_btn)

	var ctrl_c_btn := _create_key_button("Ctrl+C", KEY_WIDTH * 1.3, true)
	ctrl_c_btn.pressed.connect(_on_ctrl_c_pressed)
	bottom_row.add_child(ctrl_c_btn)

	var space_btn := _create_key_button("Space", KEY_WIDTH * 5.0, true)
	space_btn.pressed.connect(_on_space_pressed)
	bottom_row.add_child(space_btn)

	var esc_btn := _create_key_button("Esc", KEY_WIDTH * 1.2, true)
	esc_btn.pressed.connect(_on_esc_pressed)
	bottom_row.add_child(esc_btn)

	var dismiss_btn := _create_key_button("✕", KEY_WIDTH, true)
	dismiss_btn.pressed.connect(dismiss)
	bottom_row.add_child(dismiss_btn)


func _create_key_button(text: String, width: float, is_special: bool) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.custom_minimum_size = Vector2(width, KEY_HEIGHT)
	btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER

	var style := StyleBoxFlat.new()
	style.bg_color = KEY_SPECIAL_COLOR if is_special else KEY_COLOR
	style.set_corner_radius_all(6)
	style.set_content_margin_all(4)
	btn.add_theme_stylebox_override("normal", style)

	var hover := style.duplicate()
	hover.bg_color = KEY_HOVER
	btn.add_theme_stylebox_override("hover", hover)

	var pressed := style.duplicate()
	pressed.bg_color = KEY_PRESSED_COLOR
	btn.add_theme_stylebox_override("pressed", pressed)

	btn.add_theme_font_size_override("font_size", 18)
	btn.add_theme_color_override("font_color", TEXT_COLOR)

	return btn


func _apply_active_style(btn: Button) -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = KEY_ACTIVE_COLOR
	style.set_corner_radius_all(6)
	style.set_content_margin_all(4)
	btn.add_theme_stylebox_override("normal", style)


# =============================================================================
# Key Handlers
# =============================================================================

func _on_char_key_pressed(character: String) -> void:
	_send_text(character)
	if _shift_active:
		_shift_active = false
		_rebuild_keys()


func _on_shift_pressed() -> void:
	_shift_active = not _shift_active
	_rebuild_keys()


func _on_backspace_pressed() -> void:
	_send_text("\u007F")  # DEL character (terminal backspace)


func _on_enter_pressed() -> void:
	_send_text("\n")


func _on_space_pressed() -> void:
	_send_text(" ")


func _on_tab_pressed() -> void:
	_send_text("\t")


func _on_ctrl_c_pressed() -> void:
	_send_text("\u0003")  # ETX (Ctrl+C)


func _on_esc_pressed() -> void:
	_send_text("\u001B")  # ESC


func _rebuild_keys() -> void:
	_build_keyboard_ui()


func _send_text(text: String) -> void:
	key_pressed.emit(text)

	# Route through InputRouter if available
	if _input_router and _input_router.has_focused_panel():
		var panel = _input_router.get_focused_panel()
		if panel and panel.is_bound():
			panel.send_input(text)
	else:
		# Fallback: dispatch as input event for single characters
		if text.length() == 1 and text.unicode_at(0) >= 32:
			var event := InputEventKey.new()
			event.unicode = text.unicode_at(0)
			event.keycode = text.unicode_at(0)
			event.pressed = true
			Input.parse_input_event(event)


# =============================================================================
# Public API
# =============================================================================

## Show the keyboard near a target panel
func show_near_panel(panel: Node3D) -> void:
	_target_panel = panel
	visible = true

	if panel:
		# Position below the panel, facing the same direction
		global_transform = panel.global_transform
		# Offset downward
		var down := -panel.global_transform.basis.y.normalized()
		global_position += down * (KEYBOARD_SIZE.y * 0.5 + 0.05)
		# Also offset slightly forward to avoid z-fighting
		var forward := -panel.global_transform.basis.z.normalized()
		global_position += forward * 0.02


## Show the keyboard at a specific transform
func show_at(xform: Transform3D) -> void:
	global_transform = xform
	visible = true


## Dismiss/hide the keyboard
func dismiss() -> void:
	visible = false
	dismissed.emit()


## Check if the keyboard is currently visible
func is_keyboard_visible() -> bool:
	return visible
