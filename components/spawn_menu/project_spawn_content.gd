class_name ProjectSpawnContent
extends Control


## ProjectSpawnContent - 2D UI content for spawning agent sessions
##
## Displays recent projects, directory picker, and preset selector
## for spawning new agent sessions with bound terminal panels.


# =============================================================================
# Signals
# =============================================================================

## Emitted when user requests to spawn a project
signal spawn_requested(project_path: String, preset_name: String)

## Emitted when the menu should be closed
signal close_requested

## Emitted when an error occurs
signal error_occurred(message: String)


# =============================================================================
# Constants
# =============================================================================

const THEME_BG_COLOR := Color(0.15, 0.15, 0.18, 0.95)
const THEME_BUTTON_COLOR := Color(0.2, 0.2, 0.25, 0.9)
const THEME_BUTTON_HOVER := Color(0.25, 0.25, 0.3, 0.95)
const THEME_BUTTON_PRESSED := Color(0.3, 0.4, 0.5, 0.95)
const THEME_ACCENT_COLOR := Color(0.4, 0.6, 0.9)
const THEME_TEXT_PRIMARY := Color(0.95, 0.95, 0.98)
const THEME_TEXT_SECONDARY := Color(0.7, 0.7, 0.75)
const THEME_ERROR_COLOR := Color(0.9, 0.3, 0.3)
const THEME_SUCCESS_COLOR := Color(0.3, 0.9, 0.4)


# =============================================================================
# State
# =============================================================================

var _project_config: Node = null
var _agent_orchestrator: Node = null
var _selected_path: String = ""
var _selected_preset: String = "default"

# UI References
var _main_container: VBoxContainer
var _title_label: Label
var _recent_section: VBoxContainer
var _recent_list: VBoxContainer
var _browse_section: VBoxContainer
var _path_input: LineEdit
var _browse_button: Button
var _preset_section: VBoxContainer
var _preset_container: HBoxContainer
var _spawn_button: Button
var _error_label: Label
var _file_dialog: FileDialog


# =============================================================================
# Lifecycle
# =============================================================================

func _ready() -> void:
	_connect_project_config()
	_connect_agent_orchestrator()
	_setup_ui()
	_populate_recent_projects()
	_populate_presets()
	_update_spawn_button_state()


func _connect_project_config() -> void:
	_project_config = get_node_or_null("/root/ProjectConfig")
	if not _project_config:
		push_warning("ProjectSpawnContent: ProjectConfig autoload not found")
		return

	_project_config.recent_projects_changed.connect(_on_recent_projects_changed)
	_project_config.presets_changed.connect(_on_presets_changed)


func _connect_agent_orchestrator() -> void:
	_agent_orchestrator = get_node_or_null("/root/AgentOrchestrator")
	if not _agent_orchestrator:
		push_warning("ProjectSpawnContent: AgentOrchestrator autoload not found")
		return

	_agent_orchestrator.agent_count_changed.connect(_on_agent_count_changed)
	_agent_orchestrator.spawn_rejected.connect(_on_spawn_rejected)


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

	# Main container
	_main_container = VBoxContainer.new()
	_main_container.name = "MainContainer"
	_main_container.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_main_container)

	# Add margin
	var margin := MarginContainer.new()
	margin.name = "Margin"
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	margin.add_theme_constant_override("margin_left", 20)
	margin.add_theme_constant_override("margin_right", 20)
	margin.add_theme_constant_override("margin_top", 15)
	margin.add_theme_constant_override("margin_bottom", 15)
	_main_container.add_child(margin)

	var inner_container := VBoxContainer.new()
	inner_container.name = "InnerContainer"
	inner_container.add_theme_constant_override("separation", 12)
	margin.add_child(inner_container)

	# Title
	_title_label = Label.new()
	_title_label.name = "TitleLabel"
	_title_label.text = "Spawn Agent"
	_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title_label.add_theme_font_size_override("font_size", 24)
	_title_label.add_theme_color_override("font_color", THEME_TEXT_PRIMARY)
	inner_container.add_child(_title_label)

	# Separator
	var separator := HSeparator.new()
	separator.name = "TitleSeparator"
	inner_container.add_child(separator)

	# Create scrollable content area
	var scroll := ScrollContainer.new()
	scroll.name = "ScrollContainer"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	inner_container.add_child(scroll)

	var scroll_content := VBoxContainer.new()
	scroll_content.name = "ScrollContent"
	scroll_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll_content.add_theme_constant_override("separation", 16)
	scroll.add_child(scroll_content)

	# Recent Projects Section
	_setup_recent_section(scroll_content)

	# Browse Section
	_setup_browse_section(scroll_content)

	# Preset Section
	_setup_preset_section(scroll_content)

	# Error Label
	_error_label = Label.new()
	_error_label.name = "ErrorLabel"
	_error_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_error_label.add_theme_font_size_override("font_size", 12)
	_error_label.add_theme_color_override("font_color", THEME_ERROR_COLOR)
	_error_label.visible = false
	inner_container.add_child(_error_label)

	# Spawn Button
	_spawn_button = Button.new()
	_spawn_button.name = "SpawnButton"
	_spawn_button.text = "Spawn Terminal"
	_spawn_button.custom_minimum_size = Vector2(0, 50)
	_spawn_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_spawn_button(_spawn_button)
	_spawn_button.pressed.connect(_on_spawn_button_pressed)
	_spawn_button.disabled = true
	inner_container.add_child(_spawn_button)


func _setup_recent_section(parent: Control) -> void:
	_recent_section = VBoxContainer.new()
	_recent_section.name = "RecentSection"
	_recent_section.add_theme_constant_override("separation", 8)
	parent.add_child(_recent_section)

	# Section header
	var header := _create_section_header("Recent Projects", "")
	_recent_section.add_child(header)

	# Recent projects list
	_recent_list = VBoxContainer.new()
	_recent_list.name = "RecentList"
	_recent_list.add_theme_constant_override("separation", 4)
	_recent_section.add_child(_recent_list)


func _setup_browse_section(parent: Control) -> void:
	_browse_section = VBoxContainer.new()
	_browse_section.name = "BrowseSection"
	_browse_section.add_theme_constant_override("separation", 8)
	parent.add_child(_browse_section)

	# Section header
	var header := _create_section_header("Project Path", "")
	_browse_section.add_child(header)

	# Path input row
	var path_row := HBoxContainer.new()
	path_row.name = "PathRow"
	path_row.add_theme_constant_override("separation", 8)
	_browse_section.add_child(path_row)

	# Path input
	_path_input = LineEdit.new()
	_path_input.name = "PathInput"
	_path_input.placeholder_text = "/path/to/project"
	_path_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_path_input.custom_minimum_size = Vector2(0, 36)
	_style_line_edit(_path_input)
	_path_input.text_changed.connect(_on_path_text_changed)
	_path_input.text_submitted.connect(_on_path_submitted)
	path_row.add_child(_path_input)

	# Browse button
	_browse_button = Button.new()
	_browse_button.name = "BrowseButton"
	_browse_button.text = "Browse"
	_browse_button.custom_minimum_size = Vector2(80, 36)
	_style_button(_browse_button)
	_browse_button.pressed.connect(_on_browse_button_pressed)
	path_row.add_child(_browse_button)

	# Create file dialog (added to tree later when needed)
	_file_dialog = FileDialog.new()
	_file_dialog.name = "FileDialog"
	_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_file_dialog.title = "Select Project Directory"
	_file_dialog.min_size = Vector2i(600, 400)
	_file_dialog.dir_selected.connect(_on_directory_selected)
	_file_dialog.canceled.connect(_on_file_dialog_canceled)


func _setup_preset_section(parent: Control) -> void:
	_preset_section = VBoxContainer.new()
	_preset_section.name = "PresetSection"
	_preset_section.add_theme_constant_override("separation", 8)
	parent.add_child(_preset_section)

	# Section header
	var header := _create_section_header("Preset", "")
	_preset_section.add_child(header)

	# Preset buttons container
	_preset_container = HBoxContainer.new()
	_preset_container.name = "PresetContainer"
	_preset_container.add_theme_constant_override("separation", 8)
	_preset_section.add_child(_preset_container)


func _create_section_header(title: String, subtitle: String) -> HBoxContainer:
	var header := HBoxContainer.new()
	header.name = "Header_" + title.replace(" ", "")

	var title_label := Label.new()
	title_label.text = title
	title_label.add_theme_font_size_override("font_size", 16)
	title_label.add_theme_color_override("font_color", THEME_TEXT_PRIMARY)
	header.add_child(title_label)

	if subtitle != "":
		var subtitle_label := Label.new()
		subtitle_label.text = " - " + subtitle
		subtitle_label.add_theme_font_size_override("font_size", 12)
		subtitle_label.add_theme_color_override("font_color", THEME_TEXT_SECONDARY)
		header.add_child(subtitle_label)

	return header


# =============================================================================
# Recent Projects
# =============================================================================

func _populate_recent_projects() -> void:
	# Clear existing
	for child in _recent_list.get_children():
		child.queue_free()

	if not _project_config:
		_add_empty_recent_message()
		return

	var recent_projects: Array = _project_config.get_recent_projects()

	if recent_projects.is_empty():
		_add_empty_recent_message()
		return

	for project in recent_projects:
		_create_recent_project_button(project)


func _add_empty_recent_message() -> void:
	var label := Label.new()
	label.name = "EmptyMessage"
	label.text = "No recent projects"
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 12)
	label.add_theme_color_override("font_color", THEME_TEXT_SECONDARY)
	_recent_list.add_child(label)


func _create_recent_project_button(project) -> void:
	var button := Button.new()
	button.name = "Recent_" + project.name
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.custom_minimum_size = Vector2(0, 50)

	# Create button content
	var hbox := HBoxContainer.new()
	hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hbox.add_theme_constant_override("separation", 10)
	button.add_child(hbox)

	# Project icon
	var icon_label := Label.new()
	icon_label.text = ""
	icon_label.add_theme_font_size_override("font_size", 20)
	icon_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hbox.add_child(icon_label)

	# Text container
	var text_container := VBoxContainer.new()
	text_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text_container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	text_container.add_theme_constant_override("separation", 2)
	hbox.add_child(text_container)

	# Project name
	var name_label := Label.new()
	name_label.text = project.name
	name_label.add_theme_font_size_override("font_size", 14)
	name_label.add_theme_color_override("font_color", THEME_TEXT_PRIMARY)
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	text_container.add_child(name_label)

	# Project path (truncated)
	var path_label := Label.new()
	var display_path: String = project.path
	if display_path.length() > 35:
		display_path = "..." + display_path.substr(-32)
	path_label.text = display_path
	path_label.add_theme_font_size_override("font_size", 10)
	path_label.add_theme_color_override("font_color", THEME_TEXT_SECONDARY)
	path_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	text_container.add_child(path_label)

	# Time ago label
	var time_label := Label.new()
	time_label.text = _format_time_ago(project.last_opened)
	time_label.add_theme_font_size_override("font_size", 10)
	time_label.add_theme_color_override("font_color", THEME_TEXT_SECONDARY)
	time_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hbox.add_child(time_label)

	_style_button(button)

	# Connect signal
	button.pressed.connect(_on_recent_project_selected.bind(project.path, project.preset))

	_recent_list.add_child(button)


func _format_time_ago(timestamp: int) -> String:
	var now := Time.get_unix_time_from_system()
	var diff: int = now - timestamp

	if diff < 60:
		return "just now"
	elif diff < 3600:
		var mins := diff / 60
		return "%d min ago" % mins
	elif diff < 86400:
		var hours := diff / 3600
		return "%d hr ago" % hours
	elif diff < 604800:
		var days := diff / 86400
		return "%d day%s ago" % [days, "s" if days > 1 else ""]
	else:
		var weeks := diff / 604800
		return "%d week%s ago" % [weeks, "s" if weeks > 1 else ""]


# =============================================================================
# Presets
# =============================================================================

func _populate_presets() -> void:
	_populate_presets_for_project(_selected_path)


func _populate_presets_for_project(project_path: String) -> void:
	# Clear existing
	for child in _preset_container.get_children():
		child.queue_free()

	if not _project_config:
		_create_preset_button("default", "Default", "", true)
		return

	# Get presets - use project-specific if path is selected, otherwise global
	var presets: Array
	var default_preset_name: String = "default"

	if project_path != "" and DirAccess.dir_exists_absolute(project_path):
		presets = _project_config.get_presets_for_project(project_path)
		default_preset_name = _project_config.get_default_preset_name(project_path)
	else:
		presets = _project_config.get_presets()

	# If no preset is selected yet, use the default
	if _selected_preset == "" or _selected_preset == "default":
		_selected_preset = default_preset_name

	for preset in presets:
		var is_selected := preset.name == _selected_preset
		_create_preset_button(preset.name, preset.name.capitalize(), preset.icon, is_selected)


func _create_preset_button(preset_name: String, display_name: String, icon: String, selected: bool) -> void:
	var button := Button.new()
	button.name = "Preset_" + preset_name
	button.toggle_mode = true
	button.button_pressed = selected
	button.custom_minimum_size = Vector2(80, 40)

	# Button content
	var hbox := HBoxContainer.new()
	hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	hbox.add_theme_constant_override("separation", 6)
	button.add_child(hbox)

	if icon != "":
		var icon_label := Label.new()
		icon_label.text = icon
		icon_label.add_theme_font_size_override("font_size", 16)
		icon_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		hbox.add_child(icon_label)

	var name_label := Label.new()
	name_label.text = display_name
	name_label.add_theme_font_size_override("font_size", 12)
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hbox.add_child(name_label)

	_style_toggle_button(button, selected)

	button.pressed.connect(_on_preset_selected.bind(preset_name))

	_preset_container.add_child(button)


func _update_preset_selection(preset_name: String) -> void:
	_selected_preset = preset_name

	for child in _preset_container.get_children():
		if child is Button:
			var is_selected := child.name == "Preset_" + preset_name
			child.button_pressed = is_selected
			_style_toggle_button(child, is_selected)


# =============================================================================
# Styling
# =============================================================================

func _style_button(button: Button) -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = THEME_BUTTON_COLOR
	style.border_color = Color(0.3, 0.3, 0.35)
	style.set_border_width_all(1)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(10)
	button.add_theme_stylebox_override("normal", style)

	var hover_style := style.duplicate()
	hover_style.bg_color = THEME_BUTTON_HOVER
	hover_style.border_color = THEME_ACCENT_COLOR
	button.add_theme_stylebox_override("hover", hover_style)

	var pressed_style := style.duplicate()
	pressed_style.bg_color = THEME_BUTTON_PRESSED
	pressed_style.border_color = Color(0.5, 0.7, 1.0)
	button.add_theme_stylebox_override("pressed", pressed_style)


func _style_toggle_button(button: Button, selected: bool) -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = THEME_BUTTON_PRESSED if selected else THEME_BUTTON_COLOR
	style.border_color = THEME_ACCENT_COLOR if selected else Color(0.3, 0.3, 0.35)
	style.set_border_width_all(2 if selected else 1)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(8)
	button.add_theme_stylebox_override("normal", style)
	button.add_theme_stylebox_override("pressed", style)

	var hover_style := style.duplicate()
	hover_style.bg_color = THEME_BUTTON_HOVER
	hover_style.border_color = THEME_ACCENT_COLOR
	button.add_theme_stylebox_override("hover", hover_style)


func _style_spawn_button(button: Button) -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.2, 0.5, 0.3, 0.9)
	style.border_color = Color(0.3, 0.6, 0.4)
	style.set_border_width_all(2)
	style.set_corner_radius_all(8)
	style.set_content_margin_all(12)
	button.add_theme_stylebox_override("normal", style)
	button.add_theme_font_size_override("font_size", 18)
	button.add_theme_color_override("font_color", THEME_TEXT_PRIMARY)

	var hover_style := style.duplicate()
	hover_style.bg_color = Color(0.25, 0.6, 0.35, 0.95)
	hover_style.border_color = Color(0.4, 0.8, 0.5)
	button.add_theme_stylebox_override("hover", hover_style)

	var pressed_style := style.duplicate()
	pressed_style.bg_color = Color(0.3, 0.7, 0.4, 0.95)
	pressed_style.border_color = Color(0.5, 0.9, 0.6)
	button.add_theme_stylebox_override("pressed", pressed_style)

	var disabled_style := style.duplicate()
	disabled_style.bg_color = Color(0.2, 0.2, 0.25, 0.5)
	disabled_style.border_color = Color(0.3, 0.3, 0.35)
	button.add_theme_stylebox_override("disabled", disabled_style)
	button.add_theme_color_override("font_disabled_color", THEME_TEXT_SECONDARY)


func _style_line_edit(line_edit: LineEdit) -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.12, 0.12, 0.15, 0.95)
	style.border_color = Color(0.3, 0.3, 0.35)
	style.set_border_width_all(1)
	style.set_corner_radius_all(4)
	style.set_content_margin_all(8)
	line_edit.add_theme_stylebox_override("normal", style)

	var focus_style := style.duplicate()
	focus_style.border_color = THEME_ACCENT_COLOR
	focus_style.set_border_width_all(2)
	line_edit.add_theme_stylebox_override("focus", focus_style)

	line_edit.add_theme_color_override("font_color", THEME_TEXT_PRIMARY)
	line_edit.add_theme_color_override("font_placeholder_color", THEME_TEXT_SECONDARY)


# =============================================================================
# Event Handlers
# =============================================================================

func _on_recent_projects_changed() -> void:
	_populate_recent_projects()


func _on_presets_changed() -> void:
	_populate_presets()


func _on_recent_project_selected(path: String, preset: String) -> void:
	_selected_path = path
	_path_input.text = path

	# Refresh presets for the new project
	_populate_presets_for_project(path)

	if preset != "":
		_update_preset_selection(preset)

	_update_spawn_button_state()
	_clear_error()


func _on_path_text_changed(new_text: String) -> void:
	var old_path := _selected_path
	_selected_path = new_text.strip_edges()

	# Refresh presets if path changed to a valid directory
	if _selected_path != old_path and DirAccess.dir_exists_absolute(_selected_path):
		_populate_presets_for_project(_selected_path)

	_update_spawn_button_state()
	_clear_error()


func _on_path_submitted(_new_text: String) -> void:
	if _spawn_button.disabled:
		return
	_on_spawn_button_pressed()


func _on_browse_button_pressed() -> void:
	# Add file dialog to scene if not already
	if not _file_dialog.is_inside_tree():
		add_child(_file_dialog)

	# Set initial directory
	if _selected_path != "" and DirAccess.dir_exists_absolute(_selected_path):
		_file_dialog.current_dir = _selected_path
	else:
		_file_dialog.current_dir = OS.get_environment("HOME")

	_file_dialog.popup_centered()


func _on_directory_selected(dir: String) -> void:
	_selected_path = dir
	_path_input.text = dir

	# Refresh presets for the new project
	_populate_presets_for_project(dir)

	_update_spawn_button_state()
	_clear_error()


func _on_file_dialog_canceled() -> void:
	pass  # Nothing to do


func _on_preset_selected(preset_name: String) -> void:
	_update_preset_selection(preset_name)


func _on_spawn_button_pressed() -> void:
	if _selected_path == "":
		_show_error("Please select a project path")
		return

	# Validate path exists
	if not DirAccess.dir_exists_absolute(_selected_path):
		_show_error("Directory does not exist: " + _selected_path)
		return

	spawn_requested.emit(_selected_path, _selected_preset)


# =============================================================================
# Helpers
# =============================================================================

func _update_spawn_button_state() -> void:
	var path_valid := _selected_path != ""
	var can_spawn := true

	if _agent_orchestrator:
		can_spawn = _agent_orchestrator.can_spawn_agent(_selected_path)

	_spawn_button.disabled = not path_valid or not can_spawn

	# Update button text to show limit status
	if not can_spawn and path_valid:
		var status := _agent_orchestrator.get_resource_status()
		_spawn_button.text = "Limit Reached (%d/%d)" % [status.active_agents, status.max_agents]
	else:
		_spawn_button.text = "Spawn Terminal"


func _on_agent_count_changed(_count: int) -> void:
	_update_spawn_button_state()


func _on_spawn_rejected(reason: String, _current: int, _max: int) -> void:
	_show_error(reason)


func _show_error(message: String) -> void:
	_error_label.text = message
	_error_label.visible = true
	error_occurred.emit(message)


func _clear_error() -> void:
	_error_label.text = ""
	_error_label.visible = false


## Set the path programmatically
func set_project_path(path: String) -> void:
	_selected_path = path
	if _path_input:
		_path_input.text = path
	_update_spawn_button_state()


## Set the preset programmatically
func set_preset(preset_name: String) -> void:
	_update_preset_selection(preset_name)


## Refresh the UI
func refresh() -> void:
	_populate_recent_projects()
	_populate_presets()
