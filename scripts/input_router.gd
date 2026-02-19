extends Node


## InputRouter - Manages keyboard input routing to focused panels
##
## This singleton handles keyboard input capture and routes it to the
## currently focused terminal panel. Only one panel can be focused at a time.


## Emitted when the focused panel changes
signal focus_changed(panel: TerminalPanel)

## Emitted when input is routed to a panel
signal input_routed(panel: TerminalPanel, input: String)


# =============================================================================
# State
# =============================================================================

## Currently focused terminal panel
var _focused_panel: TerminalPanel = null

## Whether input capture is enabled
var _capture_enabled: bool = true

## Virtual keyboard instance (optional)
var _virtual_keyboard: Control = null

## Track modifier key states
var _ctrl_pressed: bool = false
var _alt_pressed: bool = false
var _shift_pressed: bool = false


# =============================================================================
# Lifecycle
# =============================================================================

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func _input(event: InputEvent) -> void:
	if not _capture_enabled:
		return

	if not _focused_panel:
		return

	# Handle keyboard input
	if event is InputEventKey:
		_handle_key_event(event as InputEventKey)


func _handle_key_event(event: InputEventKey) -> void:
	# Track modifier states
	if event.keycode == KEY_CTRL:
		_ctrl_pressed = event.pressed
		return
	if event.keycode == KEY_ALT:
		_alt_pressed = event.pressed
		return
	if event.keycode == KEY_SHIFT:
		_shift_pressed = event.pressed
		return

	# Only process key presses, not releases
	if not event.pressed:
		return

	# Check for Ctrl+C (interrupt signal)
	if _ctrl_pressed and event.keycode == KEY_C:
		_send_interrupt()
		get_viewport().set_input_as_handled()
		return

	# Check for Ctrl+D (EOF)
	if _ctrl_pressed and event.keycode == KEY_D:
		_send_eof()
		get_viewport().set_input_as_handled()
		return

	# Check for Ctrl+Z (suspend - SIGTSTP)
	if _ctrl_pressed and event.keycode == KEY_Z:
		_send_suspend()
		get_viewport().set_input_as_handled()
		return

	# Check for Ctrl+L (clear screen)
	if _ctrl_pressed and event.keycode == KEY_L:
		_send_clear_screen()
		get_viewport().set_input_as_handled()
		return

	# Handle Enter key (newline)
	if event.keycode == KEY_ENTER or event.keycode == KEY_KP_ENTER:
		_send_input("\n")
		get_viewport().set_input_as_handled()
		return

	# Handle Tab key
	if event.keycode == KEY_TAB:
		_send_input("\t")
		get_viewport().set_input_as_handled()
		return

	# Handle Backspace
	if event.keycode == KEY_BACKSPACE:
		_send_input("\u007F")  # DEL character (terminal backspace)
		get_viewport().set_input_as_handled()
		return

	# Handle Delete
	if event.keycode == KEY_DELETE:
		_send_input("\u001B[3~")  # Escape sequence for delete
		get_viewport().set_input_as_handled()
		return

	# Handle arrow keys
	if _handle_arrow_keys(event):
		get_viewport().set_input_as_handled()
		return

	# Handle Home/End/PageUp/PageDown
	if _handle_navigation_keys(event):
		get_viewport().set_input_as_handled()
		return

	# Handle regular character input
	if event.unicode > 0:
		var char := String.chr(event.unicode)
		_send_input(char)
		get_viewport().set_input_as_handled()


func _handle_arrow_keys(event: InputEventKey) -> bool:
	var escape_seq := ""

	match event.keycode:
		KEY_UP:
			escape_seq = "\u001B[A"
		KEY_DOWN:
			escape_seq = "\u001B[B"
		KEY_RIGHT:
			escape_seq = "\u001B[C"
		KEY_LEFT:
			escape_seq = "\u001B[D"
		_:
			return false

	# Add modifiers for Ctrl/Shift arrow keys
	if _ctrl_pressed:
		match event.keycode:
			KEY_UP:
				escape_seq = "\u001B[1;5A"
			KEY_DOWN:
				escape_seq = "\u001B[1;5B"
			KEY_RIGHT:
				escape_seq = "\u001B[1;5C"
			KEY_LEFT:
				escape_seq = "\u001B[1;5D"

	_send_input(escape_seq)
	return true


func _handle_navigation_keys(event: InputEventKey) -> bool:
	var escape_seq := ""

	match event.keycode:
		KEY_HOME:
			escape_seq = "\u001B[H"
		KEY_END:
			escape_seq = "\u001B[F"
		KEY_PAGEUP:
			escape_seq = "\u001B[5~"
		KEY_PAGEDOWN:
			escape_seq = "\u001B[6~"
		KEY_INSERT:
			escape_seq = "\u001B[2~"
		_:
			return false

	_send_input(escape_seq)
	return true


# =============================================================================
# Input Sending
# =============================================================================

func _send_input(input: String) -> void:
	if not _focused_panel or not _focused_panel.is_bound():
		return

	var err := _focused_panel.send_input(input)
	if err == OK:
		input_routed.emit(_focused_panel, input)


func _send_interrupt() -> void:
	# Send Ctrl+C (ETX - End of Text, ASCII 0x03)
	_send_input("\u0003")
	print("InputRouter: Sent interrupt signal (Ctrl+C)")


func _send_eof() -> void:
	# Send Ctrl+D (EOT - End of Transmission, ASCII 0x04)
	_send_input("\u0004")
	print("InputRouter: Sent EOF (Ctrl+D)")


func _send_suspend() -> void:
	# Send Ctrl+Z (SUB - Substitute, ASCII 0x1A)
	_send_input("\u001A")
	print("InputRouter: Sent suspend signal (Ctrl+Z)")


func _send_clear_screen() -> void:
	# Send Ctrl+L (Form Feed, ASCII 0x0C)
	_send_input("\u000C")
	print("InputRouter: Sent clear screen (Ctrl+L)")


# =============================================================================
# Public API - Focus Management
# =============================================================================

## Set the focused terminal panel
## Pass null to unfocus all panels
func set_focused_panel(panel: TerminalPanel) -> void:
	if _focused_panel == panel:
		return

	# Unfocus previous panel
	if _focused_panel:
		_focused_panel.set_terminal_focused(false)
		_unfocus_visual(_focused_panel)

	_focused_panel = panel

	# Focus new panel
	if _focused_panel:
		_focused_panel.set_terminal_focused(true)
		_focus_visual(_focused_panel)
		print("InputRouter: Focused panel: %s" % _focused_panel.title)
	else:
		print("InputRouter: No panel focused")

	focus_changed.emit(_focused_panel)


## Get the currently focused panel
func get_focused_panel() -> TerminalPanel:
	return _focused_panel


## Check if a panel is focused
func is_panel_focused(panel: TerminalPanel) -> bool:
	return _focused_panel == panel


## Check if any panel is focused
func has_focused_panel() -> bool:
	return _focused_panel != null


## Unfocus all panels
func clear_focus() -> void:
	set_focused_panel(null)


## Enable or disable input capture
func set_capture_enabled(enabled: bool) -> void:
	_capture_enabled = enabled


## Check if input capture is enabled
func is_capture_enabled() -> bool:
	return _capture_enabled


# =============================================================================
# Visual Feedback
# =============================================================================

func _focus_visual(panel: TerminalPanel) -> void:
	# Add visual focus indicator to the panel
	# This creates a colored border around the focused panel
	if not panel:
		return

	# Check if focus indicator already exists
	var indicator := panel.get_node_or_null("FocusIndicator")
	if indicator:
		indicator.visible = true
		return

	# Create focus border mesh
	indicator = MeshInstance3D.new()
	indicator.name = "FocusIndicator"

	# Create a frame mesh around the panel
	var immediate_mesh := ImmediateMesh.new()
	indicator.mesh = immediate_mesh

	# Material for the focus border
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.2, 0.6, 1.0, 0.8)  # Blue highlight
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	indicator.material_override = mat

	panel.add_child(indicator)

	# Update the focus border
	_update_focus_border(panel, indicator)


func _unfocus_visual(panel: TerminalPanel) -> void:
	if not panel:
		return

	var indicator := panel.get_node_or_null("FocusIndicator")
	if indicator:
		indicator.visible = false


func _update_focus_border(panel: TerminalPanel, indicator: MeshInstance3D) -> void:
	if not indicator or not indicator.mesh:
		return

	var immediate_mesh: ImmediateMesh = indicator.mesh
	immediate_mesh.clear_surfaces()

	var size := panel.panel_size
	var border_width := 0.01  # 1cm border
	var half_w := size.x / 2.0
	var half_h := size.y / 2.0
	var z_offset := 0.002  # Slightly in front of panel

	# Draw border as line strips
	immediate_mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)

	# Outer rectangle
	immediate_mesh.surface_add_vertex(Vector3(-half_w - border_width, -half_h - border_width, z_offset))
	immediate_mesh.surface_add_vertex(Vector3(half_w + border_width, -half_h - border_width, z_offset))
	immediate_mesh.surface_add_vertex(Vector3(half_w + border_width, half_h + border_width, z_offset))
	immediate_mesh.surface_add_vertex(Vector3(-half_w - border_width, half_h + border_width, z_offset))
	immediate_mesh.surface_add_vertex(Vector3(-half_w - border_width, -half_h - border_width, z_offset))

	immediate_mesh.surface_end()


# =============================================================================
# Virtual Keyboard (Optional)
# =============================================================================

## Show virtual keyboard for the focused panel
func show_virtual_keyboard() -> void:
	if not _focused_panel:
		return

	_ensure_virtual_keyboard()

	if _virtual_keyboard and _virtual_keyboard.has_method("show_near_panel"):
		_virtual_keyboard.show_near_panel(_focused_panel)


## Hide virtual keyboard
func hide_virtual_keyboard() -> void:
	if _virtual_keyboard and _virtual_keyboard.has_method("dismiss"):
		_virtual_keyboard.dismiss()
	elif _virtual_keyboard:
		_virtual_keyboard.hide()


## Check if virtual keyboard is visible
func is_virtual_keyboard_visible() -> bool:
	return _virtual_keyboard != null and _virtual_keyboard.visible


## Toggle virtual keyboard visibility
func toggle_virtual_keyboard() -> void:
	if is_virtual_keyboard_visible():
		hide_virtual_keyboard()
	else:
		show_virtual_keyboard()


## Lazily create the VR keyboard instance
func _ensure_virtual_keyboard() -> void:
	if _virtual_keyboard and is_instance_valid(_virtual_keyboard):
		return

	_virtual_keyboard = VRKeyboard.new()
	_virtual_keyboard.name = "VRKeyboard"
	_virtual_keyboard.visible = false
	get_tree().current_scene.add_child(_virtual_keyboard)


# =============================================================================
# Cleanup
# =============================================================================

func _exit_tree() -> void:
	clear_focus()
