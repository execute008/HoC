class_name ProjectSwitcherContent
extends Control


## ProjectSwitcherContent - 2D UI content for switching between projects
##
## Displays recent projects with their settings and allows switching between them.
## Handles agent cleanup options and layout restoration when switching projects.


# =============================================================================
# Signals
# =============================================================================

## Emitted when user selects a project to switch to
signal project_selected(project_path: String)

## Emitted when user wants to add a new project
signal add_project_requested

## Emitted when user removes a project from the list
signal project_removed(project_path: String)

## Emitted when the panel should be closed
signal close_requested


# =============================================================================
# Constants
# =============================================================================

const THEME_BG_COLOR := Color(0.15, 0.15, 0.18, 0.95)
const THEME_ITEM_COLOR := Color(0.2, 0.2, 0.25, 0.9)
const THEME_ITEM_HOVER := Color(0.25, 0.25, 0.3, 0.95)
const THEME_ITEM_SELECTED := Color(0.25, 0.35, 0.5, 0.95)
const THEME_DANGER_COLOR := Color(0.8, 0.2, 0.2, 0.9)
const THEME_DANGER_HOVER := Color(0.9, 0.3, 0.3, 0.95)
const THEME_ACCENT_COLOR := Color(0.4, 0.6, 0.9)
const THEME_SUCCESS_COLOR := Color(0.2, 0.7, 0.3, 0.9)
const THEME_TEXT_PRIMARY := Color(0.95, 0.95, 0.98)
const THEME_TEXT_SECONDARY := Color(0.7, 0.7, 0.75)


# =============================================================================
# State
# =============================================================================

var _project_config: Node = null
var _agent_orchestrator: Node = null
var _layout_manager: Node = null

## Current active project path (if any)
var _current_project: String = ""

## Whether to kill agents when switching projects
var _kill_agents_on_switch: bool = true

# UI References
var _main_container: VBoxContainer
var _title_label: Label
var _project_list: VBoxContainer
var _empty_label: Label
var _kill_agents_checkbox: CheckBox
var _add_button: Button
var _status_label: Label


# =============================================================================
# Lifecycle
# =============================================================================

func _ready() -> void:
	_connect_autoloads()
	_setup_ui()
	_refresh_project_list()


func _connect_autoloads() -> void:
	_project_config = get_node_or_null("/root/ProjectConfig")
	if not _project_config:
		push_warning("ProjectSwitcherContent: ProjectConfig autoload not found")
	else:
		_project_config.recent_projects_changed.connect(_on_recent_projects_changed)

	_agent_orchestrator = get_node_or_null("/root/AgentOrchestrator")
	if not _agent_orchestrator:
		push_warning("ProjectSwitcherContent: AgentOrchestrator autoload not found")

	_layout_manager = get_node_or_null("/root/LayoutManager")
	if not _layout_manager:
		push_warning("ProjectSwitcherContent: LayoutManager autoload not found")


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
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_bottom", 12)
	_main_container.add_child(margin)

	var inner_container := VBoxContainer.new()
	inner_container.name = "InnerContainer"
	inner_container.add_theme_constant_override("separation", 10)
	margin.add_child(inner_container)

	# Header row
	var header_row := HBoxContainer.new()
	header_row.name = "HeaderRow"
	inner_container.add_child(header_row)

	# Title
	_title_label = Label.new()
	_title_label.name = "TitleLabel"
	_title_label.text = "Project Switcher"
	_title_label.add_theme_font_size_override("font_size", 20)
	_title_label.add_theme_color_override("font_color", THEME_TEXT_PRIMARY)
	_title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header_row.add_child(_title_label)

	# Status label (showing current project)
	_status_label = Label.new()
	_status_label.name = "StatusLabel"
	_status_label.text = ""
	_status_label.add_theme_font_size_override("font_size", 11)
	_status_label.add_theme_color_override("font_color", THEME_TEXT_SECONDARY)
	header_row.add_child(_status_label)

	# Separator
	var separator := HSeparator.new()
	separator.name = "TitleSeparator"
	inner_container.add_child(separator)

	# Options row
	var options_row := HBoxContainer.new()
	options_row.name = "OptionsRow"
	inner_container.add_child(options_row)

	_kill_agents_checkbox = CheckBox.new()
	_kill_agents_checkbox.name = "KillAgentsCheckbox"
	_kill_agents_checkbox.text = "Kill running agents when switching"
	_kill_agents_checkbox.button_pressed = _kill_agents_on_switch
	_kill_agents_checkbox.add_theme_font_size_override("font_size", 11)
	_kill_agents_checkbox.add_theme_color_override("font_color", THEME_TEXT_SECONDARY)
	_kill_agents_checkbox.toggled.connect(_on_kill_agents_toggled)
	options_row.add_child(_kill_agents_checkbox)

	# Scroll container for project list
	var scroll := ScrollContainer.new()
	scroll.name = "ScrollContainer"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	inner_container.add_child(scroll)

	_project_list = VBoxContainer.new()
	_project_list.name = "ProjectList"
	_project_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_project_list.add_theme_constant_override("separation", 6)
	scroll.add_child(_project_list)

	# Empty message
	_empty_label = Label.new()
	_empty_label.name = "EmptyLabel"
	_empty_label.text = "No recent projects\n\nUse the Agent Spawn panel to\nopen a project first."
	_empty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty_label.add_theme_font_size_override("font_size", 12)
	_empty_label.add_theme_color_override("font_color", THEME_TEXT_SECONDARY)
	_project_list.add_child(_empty_label)

	# Button row
	var button_row := HBoxContainer.new()
	button_row.name = "ButtonRow"
	button_row.add_theme_constant_override("separation", 8)
	inner_container.add_child(button_row)

	# Add project button
	_add_button = Button.new()
	_add_button.name = "AddButton"
	_add_button.text = "Browse..."
	_add_button.custom_minimum_size = Vector2(0, 40)
	_add_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_primary_button(_add_button)
	_add_button.pressed.connect(_on_add_button_pressed)
	button_row.add_child(_add_button)


func _create_project_item(project) -> Control:
	var is_current := project.path == _current_project

	var item := PanelContainer.new()
	item.name = "Project_" + project.path.get_file()
	item.custom_minimum_size = Vector2(0, 80)
	item.set_meta("project_path", project.path)

	# Item style
	var style := StyleBoxFlat.new()
	style.bg_color = THEME_ITEM_SELECTED if is_current else THEME_ITEM_COLOR
	style.border_color = THEME_ACCENT_COLOR if is_current else Color(0.3, 0.3, 0.35)
	style.set_border_width_all(1 if not is_current else 2)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(10)
	item.add_theme_stylebox_override("panel", style)

	# Main container
	var hbox := HBoxContainer.new()
	hbox.name = "Content"
	hbox.add_theme_constant_override("separation", 10)
	item.add_child(hbox)

	# Project icon/indicator
	var icon_label := Label.new()
	icon_label.name = "IconLabel"
	icon_label.text = "📁" if not is_current else "✓"
	icon_label.add_theme_font_size_override("font_size", 20)
	icon_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	hbox.add_child(icon_label)

	# Info container
	var info_container := VBoxContainer.new()
	info_container.name = "InfoContainer"
	info_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info_container.add_theme_constant_override("separation", 2)
	hbox.add_child(info_container)

	# Project name
	var name_label := Label.new()
	name_label.name = "NameLabel"
	name_label.text = project.name
	name_label.add_theme_font_size_override("font_size", 14)
	name_label.add_theme_color_override("font_color", THEME_TEXT_PRIMARY)
	info_container.add_child(name_label)

	# Project path
	var path_label := Label.new()
	path_label.name = "PathLabel"
	path_label.text = project.path
	path_label.add_theme_font_size_override("font_size", 9)
	path_label.add_theme_color_override("font_color", THEME_TEXT_SECONDARY)
	path_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	path_label.tooltip_text = project.path
	info_container.add_child(path_label)

	# Metadata row
	var meta_row := HBoxContainer.new()
	meta_row.name = "MetaRow"
	meta_row.add_theme_constant_override("separation", 8)
	info_container.add_child(meta_row)

	# Last used time
	var time_label := Label.new()
	time_label.name = "TimeLabel"
	time_label.text = _format_time_ago(project.last_opened)
	time_label.add_theme_font_size_override("font_size", 10)
	time_label.add_theme_color_override("font_color", THEME_TEXT_SECONDARY)
	meta_row.add_child(time_label)

	# Last preset
	if project.preset != "":
		var preset_label := Label.new()
		preset_label.name = "PresetLabel"
		preset_label.text = "[%s]" % project.preset
		preset_label.add_theme_font_size_override("font_size", 10)
		preset_label.add_theme_color_override("font_color", THEME_ACCENT_COLOR)
		meta_row.add_child(preset_label)

	# Current indicator
	if is_current:
		var current_label := Label.new()
		current_label.name = "CurrentLabel"
		current_label.text = "• Active"
		current_label.add_theme_font_size_override("font_size", 10)
		current_label.add_theme_color_override("font_color", THEME_SUCCESS_COLOR)
		meta_row.add_child(current_label)

	# Actions container
	var actions := VBoxContainer.new()
	actions.name = "ActionsContainer"
	actions.add_theme_constant_override("separation", 4)
	actions.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	hbox.add_child(actions)

	# Switch button (or "Active" if current)
	var switch_button := Button.new()
	switch_button.name = "SwitchButton"
	if is_current:
		switch_button.text = "Active"
		switch_button.disabled = true
		_style_success_button(switch_button)
	else:
		switch_button.text = "Switch"
		_style_primary_button(switch_button)
	switch_button.custom_minimum_size = Vector2(70, 28)
	switch_button.pressed.connect(_on_project_switch_pressed.bind(project.path))
	actions.add_child(switch_button)

	# Remove button
	var remove_button := Button.new()
	remove_button.name = "RemoveButton"
	remove_button.text = "Remove"
	remove_button.custom_minimum_size = Vector2(70, 24)
	_style_small_danger_button(remove_button)
	remove_button.pressed.connect(_on_project_remove_pressed.bind(project.path))
	actions.add_child(remove_button)

	return item


func _format_time_ago(timestamp: int) -> String:
	var now := int(Time.get_unix_time_from_system())
	var diff := now - timestamp

	if diff < 60:
		return "Just now"
	elif diff < 3600:
		var mins := diff / 60
		return "%d min%s ago" % [mins, "s" if mins > 1 else ""]
	elif diff < 86400:
		var hours := diff / 3600
		return "%d hour%s ago" % [hours, "s" if hours > 1 else ""]
	elif diff < 604800:
		var days := diff / 86400
		return "%d day%s ago" % [days, "s" if days > 1 else ""]
	else:
		var date := Time.get_datetime_dict_from_unix_time(timestamp)
		return "%04d-%02d-%02d" % [date.year, date.month, date.day]


# =============================================================================
# Styling
# =============================================================================

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
	pressed_style.border_color = Color(0.5, 0.7, 1.0)
	button.add_theme_stylebox_override("pressed", pressed_style)

	var disabled_style := style.duplicate()
	disabled_style.bg_color = Color(0.2, 0.2, 0.25, 0.5)
	disabled_style.border_color = Color(0.25, 0.25, 0.3)
	button.add_theme_stylebox_override("disabled", disabled_style)
	button.add_theme_color_override("font_disabled_color", THEME_TEXT_SECONDARY)


func _style_success_button(button: Button) -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = THEME_SUCCESS_COLOR
	style.border_color = Color(0.15, 0.5, 0.2)
	style.set_border_width_all(1)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(8)
	button.add_theme_stylebox_override("normal", style)
	button.add_theme_font_size_override("font_size", 11)
	button.add_theme_color_override("font_color", THEME_TEXT_PRIMARY)

	var disabled_style := style.duplicate()
	disabled_style.bg_color = Color(0.15, 0.4, 0.2, 0.7)
	disabled_style.border_color = Color(0.1, 0.3, 0.15)
	button.add_theme_stylebox_override("disabled", disabled_style)
	button.add_theme_color_override("font_disabled_color", THEME_TEXT_PRIMARY)


func _style_small_danger_button(button: Button) -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.4, 0.15, 0.15, 0.8)
	style.border_color = Color(0.5, 0.2, 0.2)
	style.set_border_width_all(1)
	style.set_corner_radius_all(4)
	style.set_content_margin_all(4)
	button.add_theme_stylebox_override("normal", style)
	button.add_theme_font_size_override("font_size", 10)
	button.add_theme_color_override("font_color", THEME_TEXT_SECONDARY)

	var hover_style := style.duplicate()
	hover_style.bg_color = THEME_DANGER_COLOR
	hover_style.border_color = Color(0.6, 0.2, 0.2)
	button.add_theme_stylebox_override("hover", hover_style)
	button.add_theme_color_override("font_hover_color", THEME_TEXT_PRIMARY)

	var pressed_style := style.duplicate()
	pressed_style.bg_color = THEME_DANGER_HOVER
	pressed_style.border_color = Color(0.7, 0.25, 0.25)
	button.add_theme_stylebox_override("pressed", pressed_style)


# =============================================================================
# Project List Management
# =============================================================================

func _refresh_project_list() -> void:
	# Clear existing items (except empty label)
	# Remove from tree immediately to avoid duplicates on rapid refresh
	for child in _project_list.get_children():
		if child != _empty_label:
			_project_list.remove_child(child)
			child.queue_free()

	if not _project_config:
		_empty_label.visible = true
		return

	# Get recent projects
	var projects = _project_config.get_recent_projects()

	# Show empty message if no projects
	_empty_label.visible = projects.is_empty()

	if projects.is_empty():
		return

	# Create items for each project
	for project in projects:
		var item := _create_project_item(project)
		_project_list.add_child(item)

	# Move empty label to end (hidden)
	_project_list.move_child(_empty_label, _project_list.get_child_count() - 1)

	# Update status
	_update_status()


func _update_status() -> void:
	if _current_project != "":
		_status_label.text = _current_project.get_file()
	else:
		_status_label.text = "No active project"


# =============================================================================
# Event Handlers
# =============================================================================

func _on_recent_projects_changed() -> void:
	_refresh_project_list()


func _on_kill_agents_toggled(pressed: bool) -> void:
	_kill_agents_on_switch = pressed


func _on_project_switch_pressed(project_path: String) -> void:
	project_selected.emit(project_path)


func _on_project_remove_pressed(project_path: String) -> void:
	project_removed.emit(project_path)


func _on_add_button_pressed() -> void:
	add_project_requested.emit()


# =============================================================================
# Public API
# =============================================================================

## Set the current active project (for highlighting)
func set_current_project(project_path: String) -> void:
	_current_project = project_path
	_refresh_project_list()


## Get whether agents should be killed on switch
func get_kill_agents_on_switch() -> bool:
	return _kill_agents_on_switch


## Set whether agents should be killed on switch
func set_kill_agents_on_switch(value: bool) -> void:
	_kill_agents_on_switch = value
	if _kill_agents_checkbox:
		_kill_agents_checkbox.button_pressed = value


## Force refresh the project list
func refresh() -> void:
	_refresh_project_list()


## Show a warning message
func show_warning(message: String) -> void:
	# Flash the status label with warning
	_status_label.text = message
	_status_label.add_theme_color_override("font_color", THEME_DANGER_COLOR)

	# Reset after delay
	var timer := get_tree().create_timer(3.0)
	await timer.timeout
	if not is_instance_valid(self) or not _status_label:
		return
	_status_label.add_theme_color_override("font_color", THEME_TEXT_SECONDARY)
	_update_status()
