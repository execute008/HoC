class_name RemoteConnectionContent
extends Control


## RemoteConnectionContent - 2D UI for configuring remote bridge connection
##
## Allows users to configure connection to a PC-hosted bridge for standalone
## Quest usage. Supports IP address entry, port configuration, and authentication.


# =============================================================================
# Signals
# =============================================================================

## Emitted when connection settings are saved
signal settings_saved

## Emitted when user requests to connect
signal connect_requested

## Emitted when user requests to disconnect
signal disconnect_requested

## Emitted when the panel should be closed
signal close_requested


# =============================================================================
# Constants
# =============================================================================

const THEME_BG_COLOR := Color(0.15, 0.15, 0.18, 0.95)
const THEME_SECTION_COLOR := Color(0.2, 0.2, 0.25, 0.9)
const THEME_INPUT_BG := Color(0.12, 0.12, 0.15, 0.95)
const THEME_INPUT_BORDER := Color(0.3, 0.3, 0.35)
const THEME_ACCENT_COLOR := Color(0.4, 0.6, 0.9)
const THEME_SUCCESS_COLOR := Color(0.2, 0.7, 0.3)
const THEME_WARNING_COLOR := Color(0.9, 0.7, 0.2)
const THEME_DANGER_COLOR := Color(0.8, 0.2, 0.2)
const THEME_TEXT_PRIMARY := Color(0.95, 0.95, 0.98)
const THEME_TEXT_SECONDARY := Color(0.7, 0.7, 0.75)


# =============================================================================
# State
# =============================================================================

var _project_config: Node = null
var _bridge_client: Node = null

# UI References
var _main_container: VBoxContainer
var _enabled_checkbox: CheckBox
var _host_input: LineEdit
var _port_input: SpinBox
var _token_input: LineEdit
var _auto_reconnect_checkbox: CheckBox
var _status_indicator: Control
var _status_label: Label
var _connect_button: Button
var _save_button: Button
var _message_label: Label


# =============================================================================
# Lifecycle
# =============================================================================

func _ready() -> void:
	_connect_autoloads()
	_setup_ui()
	_load_settings()
	_update_connection_status()


func _process(_delta: float) -> void:
	# Update connection status periodically
	_update_connection_status()


func _connect_autoloads() -> void:
	_project_config = get_node_or_null("/root/ProjectConfig")
	if not _project_config:
		push_warning("RemoteConnectionContent: ProjectConfig autoload not found")

	_bridge_client = get_node_or_null("/root/BridgeClient")
	if _bridge_client:
		_bridge_client.connected.connect(_on_bridge_connected)
		_bridge_client.disconnected.connect(_on_bridge_disconnected)
		_bridge_client.connection_error.connect(_on_bridge_connection_error)
		_bridge_client.reconnecting.connect(_on_bridge_reconnecting)
		_bridge_client.auth_success.connect(_on_bridge_auth_success)
		_bridge_client.auth_failed.connect(_on_bridge_auth_failed)
	else:
		push_warning("RemoteConnectionContent: BridgeClient autoload not found")


# =============================================================================
# UI Setup
# =============================================================================

func _setup_ui() -> void:
	# Main background
	var bg := ColorRect.new()
	bg.name = "Background"
	bg.color = THEME_BG_COLOR
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	# Main scroll container
	var scroll := ScrollContainer.new()
	scroll.name = "ScrollContainer"
	scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)

	# Main container
	_main_container = VBoxContainer.new()
	_main_container.name = "MainContainer"
	_main_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_main_container)

	# Add margin
	var margin := MarginContainer.new()
	margin.name = "Margin"
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_bottom", 12)
	_main_container.add_child(margin)

	var inner_container := VBoxContainer.new()
	inner_container.name = "InnerContainer"
	inner_container.add_theme_constant_override("separation", 12)
	margin.add_child(inner_container)

	# Title
	var title_label := Label.new()
	title_label.name = "TitleLabel"
	title_label.text = "Remote Bridge Connection"
	title_label.add_theme_font_size_override("font_size", 18)
	title_label.add_theme_color_override("font_color", THEME_TEXT_PRIMARY)
	inner_container.add_child(title_label)

	# Description
	var desc_label := Label.new()
	desc_label.name = "DescriptionLabel"
	desc_label.text = "Connect your Quest to a PC-hosted bridge over WiFi.\nRun hoc-bridge on your PC and enter the connection details below."
	desc_label.add_theme_font_size_override("font_size", 11)
	desc_label.add_theme_color_override("font_color", THEME_TEXT_SECONDARY)
	desc_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	inner_container.add_child(desc_label)

	# Connection status section
	_create_status_section(inner_container)

	# Separator
	var sep1 := HSeparator.new()
	inner_container.add_child(sep1)

	# Settings section
	_create_settings_section(inner_container)

	# Separator
	var sep2 := HSeparator.new()
	inner_container.add_child(sep2)

	# Action buttons
	_create_action_buttons(inner_container)

	# Message label for feedback
	_message_label = Label.new()
	_message_label.name = "MessageLabel"
	_message_label.text = ""
	_message_label.add_theme_font_size_override("font_size", 11)
	_message_label.add_theme_color_override("font_color", THEME_TEXT_SECONDARY)
	_message_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	inner_container.add_child(_message_label)


func _create_status_section(parent: Control) -> void:
	var section := _create_section_container("Connection Status")
	parent.add_child(section)

	var content := section.get_node("Content")

	# Status row
	var status_row := HBoxContainer.new()
	status_row.name = "StatusRow"
	status_row.add_theme_constant_override("separation", 10)
	content.add_child(status_row)

	# Status indicator (colored circle)
	_status_indicator = ColorRect.new()
	_status_indicator.name = "StatusIndicator"
	_status_indicator.custom_minimum_size = Vector2(16, 16)
	_status_indicator.color = THEME_TEXT_SECONDARY
	status_row.add_child(_status_indicator)

	# Status label
	_status_label = Label.new()
	_status_label.name = "StatusLabel"
	_status_label.text = "Disconnected"
	_status_label.add_theme_font_size_override("font_size", 13)
	_status_label.add_theme_color_override("font_color", THEME_TEXT_PRIMARY)
	_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status_row.add_child(_status_label)


func _create_settings_section(parent: Control) -> void:
	var section := _create_section_container("Connection Settings")
	parent.add_child(section)

	var content := section.get_node("Content")

	# Enable remote connection checkbox
	_enabled_checkbox = CheckBox.new()
	_enabled_checkbox.name = "EnabledCheckbox"
	_enabled_checkbox.text = "Enable remote connection"
	_enabled_checkbox.add_theme_font_size_override("font_size", 12)
	_enabled_checkbox.add_theme_color_override("font_color", THEME_TEXT_PRIMARY)
	_enabled_checkbox.toggled.connect(_on_enabled_toggled)
	content.add_child(_enabled_checkbox)

	# Host input
	var host_row := _create_input_row("PC IP Address:", "e.g., 192.168.1.100")
	content.add_child(host_row)
	_host_input = host_row.get_node("Input")
	_host_input.text_changed.connect(_on_host_changed)

	# Port input
	var port_row := HBoxContainer.new()
	port_row.name = "PortRow"
	port_row.add_theme_constant_override("separation", 10)
	content.add_child(port_row)

	var port_label := Label.new()
	port_label.name = "PortLabel"
	port_label.text = "Port:"
	port_label.add_theme_font_size_override("font_size", 12)
	port_label.add_theme_color_override("font_color", THEME_TEXT_PRIMARY)
	port_label.custom_minimum_size = Vector2(120, 0)
	port_row.add_child(port_label)

	_port_input = SpinBox.new()
	_port_input.name = "PortInput"
	_port_input.min_value = 1
	_port_input.max_value = 65535
	_port_input.value = 9000
	_port_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_port_input.value_changed.connect(_on_port_changed)
	port_row.add_child(_port_input)

	# Token input
	var token_row := _create_input_row("Auth Token:", "Leave empty if not required")
	content.add_child(token_row)
	_token_input = token_row.get_node("Input")
	_token_input.secret = true  # Hide token characters
	_token_input.text_changed.connect(_on_token_changed)

	# Show/hide token button
	var token_container := token_row.get_node("Input").get_parent()
	var show_token_btn := Button.new()
	show_token_btn.name = "ShowTokenButton"
	show_token_btn.text = "Show"
	show_token_btn.custom_minimum_size = Vector2(50, 0)
	show_token_btn.pressed.connect(_on_show_token_pressed.bind(show_token_btn))
	token_container.add_child(show_token_btn)

	# Auto-reconnect checkbox
	_auto_reconnect_checkbox = CheckBox.new()
	_auto_reconnect_checkbox.name = "AutoReconnectCheckbox"
	_auto_reconnect_checkbox.text = "Auto-reconnect on disconnect"
	_auto_reconnect_checkbox.button_pressed = true
	_auto_reconnect_checkbox.add_theme_font_size_override("font_size", 11)
	_auto_reconnect_checkbox.add_theme_color_override("font_color", THEME_TEXT_SECONDARY)
	_auto_reconnect_checkbox.toggled.connect(_on_auto_reconnect_toggled)
	content.add_child(_auto_reconnect_checkbox)


func _create_action_buttons(parent: Control) -> void:
	var button_row := HBoxContainer.new()
	button_row.name = "ButtonRow"
	button_row.add_theme_constant_override("separation", 10)
	parent.add_child(button_row)

	# Save button
	_save_button = Button.new()
	_save_button.name = "SaveButton"
	_save_button.text = "Save Settings"
	_save_button.custom_minimum_size = Vector2(0, 40)
	_save_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_primary_button(_save_button)
	_save_button.pressed.connect(_on_save_pressed)
	button_row.add_child(_save_button)

	# Connect/Disconnect button
	_connect_button = Button.new()
	_connect_button.name = "ConnectButton"
	_connect_button.text = "Connect"
	_connect_button.custom_minimum_size = Vector2(0, 40)
	_connect_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_success_button(_connect_button)
	_connect_button.pressed.connect(_on_connect_pressed)
	button_row.add_child(_connect_button)


func _create_section_container(title: String) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.name = title.replace(" ", "") + "Section"

	var style := StyleBoxFlat.new()
	style.bg_color = THEME_SECTION_COLOR
	style.set_corner_radius_all(6)
	style.set_content_margin_all(12)
	panel.add_theme_stylebox_override("panel", style)

	var vbox := VBoxContainer.new()
	vbox.name = "Content"
	vbox.add_theme_constant_override("separation", 8)
	panel.add_child(vbox)

	# Section title
	var label := Label.new()
	label.name = "SectionTitle"
	label.text = title
	label.add_theme_font_size_override("font_size", 13)
	label.add_theme_color_override("font_color", THEME_ACCENT_COLOR)
	vbox.add_child(label)

	return panel


func _create_input_row(label_text: String, placeholder: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.name = label_text.replace(":", "").replace(" ", "") + "Row"
	row.add_theme_constant_override("separation", 10)

	var label := Label.new()
	label.name = "Label"
	label.text = label_text
	label.add_theme_font_size_override("font_size", 12)
	label.add_theme_color_override("font_color", THEME_TEXT_PRIMARY)
	label.custom_minimum_size = Vector2(120, 0)
	row.add_child(label)

	var input := LineEdit.new()
	input.name = "Input"
	input.placeholder_text = placeholder
	input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	input.custom_minimum_size = Vector2(0, 32)
	_style_input(input)
	row.add_child(input)

	return row


# =============================================================================
# Styling
# =============================================================================

func _style_input(input: LineEdit) -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = THEME_INPUT_BG
	style.border_color = THEME_INPUT_BORDER
	style.set_border_width_all(1)
	style.set_corner_radius_all(4)
	style.set_content_margin_all(8)
	input.add_theme_stylebox_override("normal", style)
	input.add_theme_font_size_override("font_size", 12)
	input.add_theme_color_override("font_color", THEME_TEXT_PRIMARY)
	input.add_theme_color_override("font_placeholder_color", THEME_TEXT_SECONDARY)

	var focus_style := style.duplicate()
	focus_style.border_color = THEME_ACCENT_COLOR
	input.add_theme_stylebox_override("focus", focus_style)


func _style_primary_button(button: Button) -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.25, 0.35, 0.5, 0.9)
	style.border_color = Color(0.3, 0.4, 0.55)
	style.set_border_width_all(1)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(8)
	button.add_theme_stylebox_override("normal", style)
	button.add_theme_font_size_override("font_size", 12)
	button.add_theme_color_override("font_color", THEME_TEXT_PRIMARY)

	var hover_style := style.duplicate()
	hover_style.bg_color = Color(0.3, 0.45, 0.65, 0.95)
	hover_style.border_color = THEME_ACCENT_COLOR
	button.add_theme_stylebox_override("hover", hover_style)

	var pressed_style := style.duplicate()
	pressed_style.bg_color = Color(0.35, 0.5, 0.7)
	button.add_theme_stylebox_override("pressed", pressed_style)


func _style_success_button(button: Button) -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.15, 0.4, 0.2, 0.9)
	style.border_color = Color(0.2, 0.5, 0.25)
	style.set_border_width_all(1)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(8)
	button.add_theme_stylebox_override("normal", style)
	button.add_theme_font_size_override("font_size", 12)
	button.add_theme_color_override("font_color", THEME_TEXT_PRIMARY)

	var hover_style := style.duplicate()
	hover_style.bg_color = THEME_SUCCESS_COLOR
	hover_style.border_color = Color(0.25, 0.6, 0.3)
	button.add_theme_stylebox_override("hover", hover_style)


func _style_danger_button(button: Button) -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.4, 0.15, 0.15, 0.9)
	style.border_color = Color(0.5, 0.2, 0.2)
	style.set_border_width_all(1)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(8)
	button.add_theme_stylebox_override("normal", style)
	button.add_theme_font_size_override("font_size", 12)
	button.add_theme_color_override("font_color", THEME_TEXT_PRIMARY)

	var hover_style := style.duplicate()
	hover_style.bg_color = THEME_DANGER_COLOR
	hover_style.border_color = Color(0.6, 0.25, 0.25)
	button.add_theme_stylebox_override("hover", hover_style)


# =============================================================================
# Settings Management
# =============================================================================

func _load_settings() -> void:
	if not _project_config:
		return

	var remote: Dictionary = _project_config.get_remote_connection()
	_enabled_checkbox.button_pressed = remote.enabled
	_host_input.text = remote.host
	_port_input.value = remote.port
	_token_input.text = remote.token
	_auto_reconnect_checkbox.button_pressed = remote.auto_reconnect

	_update_ui_enabled_state()


func _save_settings() -> void:
	if not _project_config:
		_show_message("Error: Config not available", THEME_DANGER_COLOR)
		return

	var host := _host_input.text.strip_edges()
	var port := int(_port_input.value)
	var token := _token_input.text.strip_edges()
	var enabled := _enabled_checkbox.button_pressed
	var auto_reconnect := _auto_reconnect_checkbox.button_pressed

	# Validate
	if enabled and host == "":
		_show_message("Please enter a PC IP address", THEME_WARNING_COLOR)
		return

	# Save settings
	_project_config.configure_remote_connection(host, port, token, enabled)
	_project_config.set_remote_auto_reconnect(auto_reconnect)

	_show_message("Settings saved! Restart app to apply.", THEME_SUCCESS_COLOR)
	settings_saved.emit()


func _update_ui_enabled_state() -> void:
	var enabled := _enabled_checkbox.button_pressed
	_host_input.editable = enabled
	_port_input.editable = enabled
	_token_input.editable = enabled
	_auto_reconnect_checkbox.disabled = not enabled

	# Update visual opacity
	var alpha := 1.0 if enabled else 0.5
	_host_input.modulate.a = alpha
	_port_input.modulate.a = alpha
	_token_input.modulate.a = alpha


# =============================================================================
# Connection Status
# =============================================================================

func _update_connection_status() -> void:
	if not _bridge_client:
		_set_status("No bridge client", THEME_TEXT_SECONDARY)
		return

	var state = _bridge_client.get_state()
	var is_remote: bool = _bridge_client.is_remote_connection()

	match state:
		0:  # DISCONNECTED
			_set_status("Disconnected", THEME_TEXT_SECONDARY)
			_update_connect_button(false)
		1:  # CONNECTING
			_set_status("Connecting...", THEME_WARNING_COLOR)
			_update_connect_button(true)
		2:  # CONNECTED
			var url: String = _bridge_client.get_connection_url()
			var label := "Connected to %s" % url if is_remote else "Connected (local)"
			_set_status(label, THEME_SUCCESS_COLOR)
			_update_connect_button(true)
		3:  # RECONNECTING
			_set_status("Reconnecting...", THEME_WARNING_COLOR)
			_update_connect_button(true)


func _set_status(text: String, color: Color) -> void:
	if _status_label:
		_status_label.text = text
	if _status_indicator:
		_status_indicator.color = color


func _update_connect_button(is_connected: bool) -> void:
	if not _connect_button:
		return

	if is_connected:
		_connect_button.text = "Disconnect"
		_style_danger_button(_connect_button)
	else:
		_connect_button.text = "Connect"
		_style_success_button(_connect_button)


func _show_message(text: String, color: Color) -> void:
	if _message_label:
		_message_label.text = text
		_message_label.add_theme_color_override("font_color", color)

		# Clear message after delay
		var timer := get_tree().create_timer(5.0)
		await timer.timeout
		if _message_label:
			_message_label.text = ""


# =============================================================================
# Event Handlers
# =============================================================================

func _on_enabled_toggled(pressed: bool) -> void:
	_update_ui_enabled_state()


func _on_host_changed(_new_text: String) -> void:
	# Validation happens on save; real-time feedback not needed
	pass


func _on_port_changed(_new_value: float) -> void:
	# Validation happens on save
	pass


func _on_token_changed(_new_text: String) -> void:
	# Validation happens on save
	pass


func _on_auto_reconnect_toggled(pressed: bool) -> void:
	if _bridge_client:
		_bridge_client.set_auto_reconnect(pressed)


func _on_show_token_pressed(button: Button) -> void:
	_token_input.secret = not _token_input.secret
	button.text = "Hide" if not _token_input.secret else "Show"


func _on_save_pressed() -> void:
	_save_settings()


func _on_connect_pressed() -> void:
	if not _bridge_client:
		_show_message("Bridge client not available", THEME_DANGER_COLOR)
		return

	var state = _bridge_client.get_state()

	if state == 2:  # CONNECTED
		_bridge_client.disconnect_from_bridge()
		disconnect_requested.emit()
	else:
		# Try to connect with current UI values
		var host := _host_input.text.strip_edges()
		var port := int(_port_input.value)
		var token := _token_input.text.strip_edges()

		if host == "":
			_show_message("Please enter a PC IP address", THEME_WARNING_COLOR)
			return

		var err: int = _bridge_client.connect_to_remote(host, port, token)
		if err != OK:
			_show_message("Failed to connect: %s" % error_string(err), THEME_DANGER_COLOR)
		else:
			connect_requested.emit()


# Bridge client signal handlers
func _on_bridge_connected() -> void:
	_show_message("Connected successfully!", THEME_SUCCESS_COLOR)
	_update_connection_status()


func _on_bridge_disconnected() -> void:
	_show_message("Disconnected from bridge", THEME_WARNING_COLOR)
	_update_connection_status()


func _on_bridge_connection_error(error: String) -> void:
	_show_message("Connection error: %s" % error, THEME_DANGER_COLOR)
	_update_connection_status()


func _on_bridge_reconnecting(attempt: int) -> void:
	_show_message("Reconnecting (attempt %d)..." % attempt, THEME_WARNING_COLOR)
	_update_connection_status()


func _on_bridge_auth_success() -> void:
	_show_message("Authentication successful", THEME_SUCCESS_COLOR)


func _on_bridge_auth_failed(message: String) -> void:
	_show_message("Auth failed: %s" % message, THEME_DANGER_COLOR)


# =============================================================================
# Public API
# =============================================================================

## Force refresh the UI
func refresh() -> void:
	_load_settings()
	_update_connection_status()
