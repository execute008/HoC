class_name AgentListContent
extends Control


## AgentListContent - 2D UI content for managing active agents
##
## Displays all active agent sessions with their status.
## Allows killing individual agents or all agents at once.


# =============================================================================
# Signals
# =============================================================================

## Emitted when user requests to kill an agent
signal kill_agent_requested(agent_id: String)

## Emitted when user requests to kill all agents
signal kill_all_requested

## Emitted when user clicks an agent to focus its terminal
signal focus_agent_requested(agent_id: String)

## Emitted when user requests to restart an agent
signal restart_agent_requested(agent_id: String)

## Emitted when the panel should be closed
signal close_requested


# =============================================================================
# Constants
# =============================================================================

const THEME_BG_COLOR := Color(0.15, 0.15, 0.18, 0.95)
const THEME_ITEM_COLOR := Color(0.2, 0.2, 0.25, 0.9)
const THEME_ITEM_HOVER := Color(0.25, 0.25, 0.3, 0.95)
const THEME_DANGER_COLOR := Color(0.8, 0.2, 0.2, 0.9)
const THEME_DANGER_HOVER := Color(0.9, 0.3, 0.3, 0.95)
const THEME_ACCENT_COLOR := Color(0.4, 0.6, 0.9)
const THEME_TEXT_PRIMARY := Color(0.95, 0.95, 0.98)
const THEME_TEXT_SECONDARY := Color(0.7, 0.7, 0.75)

# State colors - matches AgentOrchestrator.AgentState enum order
const STATE_COLORS := {
	0: Color(1.0, 0.8, 0.0),  # SPAWNING - Yellow
	1: Color(0.4, 0.7, 1.0),  # IDLE - Blue
	2: Color(0.2, 0.9, 0.3),  # RUNNING - Green
	3: Color(0.9, 0.2, 0.2),  # ERROR - Red
	4: Color(1.0, 0.5, 0.0),  # EXITING - Orange
	5: Color(0.6, 0.6, 0.6),  # EXITED - Gray
}

const STATE_NAMES := {
	0: "Spawning",
	1: "Idle",
	2: "Running",
	3: "Error",
	4: "Exiting",
	5: "Exited",
}

# State icons for visual distinction
const STATE_ICONS := {
	0: "⏳",  # SPAWNING
	1: "💤",  # IDLE
	2: "▶️",  # RUNNING
	3: "⚠️",  # ERROR
	4: "⏹️",  # EXITING
	5: "⬛",  # EXITED
}

## AgentState enum values (must match AgentOrchestrator.AgentState)
const AS_SPAWNING := 0
const AS_IDLE := 1
const AS_RUNNING := 2
const AS_ERROR := 3
const AS_EXITING := 4
const AS_EXITED := 5

## Refresh interval in seconds
const REFRESH_INTERVAL := 1.0


# =============================================================================
# State
# =============================================================================

var _agent_orchestrator: Node = null
var _refresh_timer: Timer = null

# UI References
var _main_container: VBoxContainer
var _title_label: Label
var _status_label: Label
var _agent_list: VBoxContainer
var _kill_all_button: Button
var _cleanup_button: Button
var _empty_label: Label


# =============================================================================
# Lifecycle
# =============================================================================

func _ready() -> void:
	_connect_agent_orchestrator()
	_setup_ui()
	_setup_refresh_timer()
	_refresh_agent_list()


func _connect_agent_orchestrator() -> void:
	_agent_orchestrator = get_node_or_null("/root/AgentOrchestrator")
	if not _agent_orchestrator:
		push_warning("AgentListContent: AgentOrchestrator autoload not found")
		return

	_agent_orchestrator.agent_created.connect(_on_agent_created)
	_agent_orchestrator.agent_state_changed.connect(_on_agent_state_changed)
	_agent_orchestrator.agent_exit.connect(_on_agent_exit)
	_agent_orchestrator.agent_removed.connect(_on_agent_removed)
	_agent_orchestrator.agent_count_changed.connect(_on_agent_count_changed)


func _setup_refresh_timer() -> void:
	_refresh_timer = Timer.new()
	_refresh_timer.name = "RefreshTimer"
	_refresh_timer.wait_time = REFRESH_INTERVAL
	_refresh_timer.one_shot = false
	_refresh_timer.timeout.connect(_on_refresh_timer)
	add_child(_refresh_timer)
	_refresh_timer.start()


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
	_title_label.text = "Agent Overview"
	_title_label.add_theme_font_size_override("font_size", 20)
	_title_label.add_theme_color_override("font_color", THEME_TEXT_PRIMARY)
	_title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header_row.add_child(_title_label)

	# Status label
	_status_label = Label.new()
	_status_label.name = "StatusLabel"
	_status_label.text = "0/10"
	_status_label.add_theme_font_size_override("font_size", 14)
	_status_label.add_theme_color_override("font_color", THEME_TEXT_SECONDARY)
	header_row.add_child(_status_label)

	# Separator
	var separator := HSeparator.new()
	separator.name = "TitleSeparator"
	inner_container.add_child(separator)

	# Scroll container for agent list
	var scroll := ScrollContainer.new()
	scroll.name = "ScrollContainer"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	inner_container.add_child(scroll)

	_agent_list = VBoxContainer.new()
	_agent_list.name = "AgentList"
	_agent_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_agent_list.add_theme_constant_override("separation", 6)
	scroll.add_child(_agent_list)

	# Empty message
	_empty_label = Label.new()
	_empty_label.name = "EmptyLabel"
	_empty_label.text = "No active agents"
	_empty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty_label.add_theme_font_size_override("font_size", 14)
	_empty_label.add_theme_color_override("font_color", THEME_TEXT_SECONDARY)
	_agent_list.add_child(_empty_label)

	# Button row
	var button_row := HBoxContainer.new()
	button_row.name = "ButtonRow"
	button_row.add_theme_constant_override("separation", 8)
	inner_container.add_child(button_row)

	# Cleanup button
	_cleanup_button = Button.new()
	_cleanup_button.name = "CleanupButton"
	_cleanup_button.text = "Cleanup Exited"
	_cleanup_button.custom_minimum_size = Vector2(0, 40)
	_cleanup_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_secondary_button(_cleanup_button)
	_cleanup_button.pressed.connect(_on_cleanup_button_pressed)
	button_row.add_child(_cleanup_button)

	# Kill all button
	_kill_all_button = Button.new()
	_kill_all_button.name = "KillAllButton"
	_kill_all_button.text = "Kill All"
	_kill_all_button.custom_minimum_size = Vector2(0, 40)
	_kill_all_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_danger_button(_kill_all_button)
	_kill_all_button.pressed.connect(_on_kill_all_button_pressed)
	button_row.add_child(_kill_all_button)


func _create_agent_item(session) -> Control:
	var item := PanelContainer.new()
	item.name = "Agent_" + session.agent_id
	item.custom_minimum_size = Vector2(0, 90)  # Increased height for working directory
	item.set_meta("agent_id", session.agent_id)

	# Item style
	var style := StyleBoxFlat.new()
	style.bg_color = THEME_ITEM_COLOR
	style.border_color = Color(0.3, 0.3, 0.35)
	style.set_border_width_all(1)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(10)
	item.add_theme_stylebox_override("panel", style)

	# Main container
	var hbox := HBoxContainer.new()
	hbox.name = "Content"
	hbox.add_theme_constant_override("separation", 10)
	item.add_child(hbox)

	# Status indicator
	var status_indicator := ColorRect.new()
	status_indicator.name = "StatusIndicator"
	status_indicator.custom_minimum_size = Vector2(12, 12)
	status_indicator.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	status_indicator.color = STATE_COLORS.get(session.state, Color.GRAY)
	# Make it circular with shader
	var shader_code = """
shader_type canvas_item;
void fragment() {
	vec2 center = vec2(0.5, 0.5);
	float dist = distance(UV, center);
	if (dist > 0.5) discard;
	COLOR = COLOR;
}
"""
	var shader = Shader.new()
	shader.code = shader_code
	var shader_mat = ShaderMaterial.new()
	shader_mat.shader = shader
	status_indicator.material = shader_mat
	hbox.add_child(status_indicator)

	# Info container
	var info_container := VBoxContainer.new()
	info_container.name = "InfoContainer"
	info_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info_container.add_theme_constant_override("separation", 2)
	hbox.add_child(info_container)

	# Project name row
	var project_name := session.project_path.get_file()
	if project_name == "":
		project_name = session.project_path
	var name_label := Label.new()
	name_label.name = "NameLabel"
	name_label.text = project_name
	name_label.add_theme_font_size_override("font_size", 14)
	name_label.add_theme_color_override("font_color", THEME_TEXT_PRIMARY)
	info_container.add_child(name_label)

	# Working directory row (full path)
	var path_label := Label.new()
	path_label.name = "PathLabel"
	path_label.text = session.project_path
	path_label.add_theme_font_size_override("font_size", 9)
	path_label.add_theme_color_override("font_color", THEME_TEXT_SECONDARY)
	path_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	path_label.tooltip_text = session.project_path
	info_container.add_child(path_label)

	# Status and ID row
	var status_row := HBoxContainer.new()
	status_row.name = "StatusRow"
	status_row.add_theme_constant_override("separation", 8)
	info_container.add_child(status_row)

	var state_label := Label.new()
	state_label.name = "StateLabel"
	var state_icon: String = STATE_ICONS.get(session.state, "❓")
	state_label.text = "%s %s" % [state_icon, STATE_NAMES.get(session.state, "Unknown")]
	state_label.add_theme_font_size_override("font_size", 11)
	state_label.add_theme_color_override("font_color", STATE_COLORS.get(session.state, Color.GRAY))
	status_row.add_child(state_label)

	var id_label := Label.new()
	id_label.name = "IdLabel"
	id_label.text = "[%s]" % session.agent_id.substr(0, 8)
	id_label.add_theme_font_size_override("font_size", 10)
	id_label.add_theme_color_override("font_color", THEME_TEXT_SECONDARY)
	status_row.add_child(id_label)

	# Action buttons container
	var actions_container := VBoxContainer.new()
	actions_container.name = "ActionsContainer"
	actions_container.add_theme_constant_override("separation", 4)
	actions_container.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	hbox.add_child(actions_container)

	# Focus button (eye icon / "Focus")
	var focus_button := Button.new()
	focus_button.name = "FocusButton"
	focus_button.text = "Focus"
	focus_button.custom_minimum_size = Vector2(70, 36)
	_style_small_action_button(focus_button)
	focus_button.pressed.connect(_on_agent_focus_pressed.bind(session.agent_id))
	# Disable focus if agent is exited or no terminal panel exists
	focus_button.disabled = session.state == AS_EXITED
	actions_container.add_child(focus_button)

	# Restart/Stop row
	var action_row := HBoxContainer.new()
	action_row.add_theme_constant_override("separation", 4)
	actions_container.add_child(action_row)

	# Restart button
	var restart_button := Button.new()
	restart_button.name = "RestartButton"
	restart_button.text = "↻"  # Restart symbol
	restart_button.tooltip_text = "Restart agent"
	restart_button.custom_minimum_size = Vector2(36, 36)
	_style_small_action_button(restart_button)
	restart_button.pressed.connect(_on_agent_restart_pressed.bind(session.agent_id))
	action_row.add_child(restart_button)

	# Kill button
	var kill_button := Button.new()
	kill_button.name = "KillButton"
	kill_button.text = "Stop"
	kill_button.custom_minimum_size = Vector2(48, 36)
	_style_small_danger_button(kill_button)
	kill_button.pressed.connect(_on_agent_kill_pressed.bind(session.agent_id))
	kill_button.disabled = session.state == AS_EXITED
	action_row.add_child(kill_button)

	return item


# =============================================================================
# Styling
# =============================================================================

func _style_secondary_button(button: Button) -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = THEME_ITEM_COLOR
	style.border_color = Color(0.3, 0.3, 0.35)
	style.set_border_width_all(1)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(8)
	button.add_theme_stylebox_override("normal", style)
	button.add_theme_font_size_override("font_size", 12)
	button.add_theme_color_override("font_color", THEME_TEXT_PRIMARY)

	var hover_style := style.duplicate()
	hover_style.bg_color = THEME_ITEM_HOVER
	hover_style.border_color = THEME_ACCENT_COLOR
	button.add_theme_stylebox_override("hover", hover_style)

	var pressed_style := style.duplicate()
	pressed_style.bg_color = THEME_ITEM_HOVER
	pressed_style.border_color = Color(0.5, 0.7, 1.0)
	button.add_theme_stylebox_override("pressed", pressed_style)


func _style_danger_button(button: Button) -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = THEME_DANGER_COLOR
	style.border_color = Color(0.6, 0.15, 0.15)
	style.set_border_width_all(1)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(8)
	button.add_theme_stylebox_override("normal", style)
	button.add_theme_font_size_override("font_size", 12)
	button.add_theme_color_override("font_color", THEME_TEXT_PRIMARY)

	var hover_style := style.duplicate()
	hover_style.bg_color = THEME_DANGER_HOVER
	hover_style.border_color = Color(0.8, 0.2, 0.2)
	button.add_theme_stylebox_override("hover", hover_style)

	var pressed_style := style.duplicate()
	pressed_style.bg_color = Color(0.95, 0.35, 0.35)
	pressed_style.border_color = Color(0.9, 0.3, 0.3)
	button.add_theme_stylebox_override("pressed", pressed_style)

	var disabled_style := style.duplicate()
	disabled_style.bg_color = Color(0.4, 0.2, 0.2, 0.5)
	disabled_style.border_color = Color(0.3, 0.2, 0.2)
	button.add_theme_stylebox_override("disabled", disabled_style)
	button.add_theme_color_override("font_disabled_color", THEME_TEXT_SECONDARY)


func _style_small_danger_button(button: Button) -> void:
	_style_danger_button(button)
	button.add_theme_font_size_override("font_size", 10)


func _style_small_action_button(button: Button) -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.25, 0.35, 0.5, 0.9)
	style.border_color = Color(0.3, 0.4, 0.55)
	style.set_border_width_all(1)
	style.set_corner_radius_all(4)
	style.set_content_margin_all(4)
	button.add_theme_stylebox_override("normal", style)
	button.add_theme_font_size_override("font_size", 10)
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


# =============================================================================
# Agent List Management
# =============================================================================

func _refresh_agent_list() -> void:
	if not _agent_orchestrator:
		return

	# Clear existing items (except empty label)
	# Use reverse iteration since queue_free doesn't remove immediately
	for child in _agent_list.get_children():
		if child != _empty_label:
			_agent_list.remove_child(child)
			child.queue_free()

	# Get all sessions
	var sessions = _agent_orchestrator.get_all_sessions()

	# Update status
	var status := _agent_orchestrator.get_resource_status()
	_status_label.text = "%d/%d" % [status.active_agents, status.max_agents]

	# Show empty message if no agents
	_empty_label.visible = sessions.is_empty()

	if sessions.is_empty():
		_kill_all_button.disabled = true
		_cleanup_button.disabled = true
		return

	# Sort sessions: running first, then by creation time
	sessions.sort_custom(_sort_sessions)

	# Create items for each session
	for session in sessions:
		var item := _create_agent_item(session)
		_agent_list.add_child(item)

	# Move empty label to end (hidden)
	_agent_list.move_child(_empty_label, _agent_list.get_child_count() - 1)

	# Update button states
	var has_running := _agent_orchestrator.get_running_count() > 0
	var has_exited := _agent_orchestrator.get_sessions_by_state(AS_EXITED).size() > 0  # EXITED = 3
	_kill_all_button.disabled = not has_running
	_cleanup_button.disabled = not has_exited


func _sort_sessions(a, b) -> bool:
	# Running agents first
	if a.state == AS_RUNNING and b.state != AS_RUNNING:  # RUNNING = 1
		return true
	if b.state == AS_RUNNING and a.state != AS_RUNNING:
		return false
	# Then by creation time (newest first)
	return a.created_at > b.created_at


func _update_agent_item(agent_id: String) -> void:
	if not _agent_orchestrator:
		return

	var session = _agent_orchestrator.get_session(agent_id)
	if not session:
		return

	# Find the item
	for child in _agent_list.get_children():
		if child.has_meta("agent_id") and child.get_meta("agent_id") == agent_id:
			# Update status indicator
			var status_indicator := child.get_node_or_null("Content/StatusIndicator")
			if status_indicator:
				status_indicator.color = STATE_COLORS.get(session.state, Color.GRAY)

			# Update state label
			var state_label := child.get_node_or_null("Content/InfoContainer/StatusRow/StateLabel")
			if state_label:
				var icon: String = STATE_ICONS.get(session.state, "❓")
				state_label.text = "%s %s" % [icon, STATE_NAMES.get(session.state, "Unknown")]
				state_label.add_theme_color_override("font_color", STATE_COLORS.get(session.state, Color.GRAY))

			# Update focus button
			var focus_button := child.get_node_or_null("Content/ActionsContainer/FocusButton")
			if focus_button:
				focus_button.disabled = session.state == AS_EXITED

			# Update kill button
			var kill_button := child.get_node_or_null("Content/ActionsContainer/HBoxContainer/KillButton")
			if kill_button:
				kill_button.disabled = session.state == AS_EXITED

			break


# =============================================================================
# Event Handlers
# =============================================================================

func _on_agent_created(_agent_id: String, _session) -> void:
	_refresh_agent_list()


func _on_agent_state_changed(agent_id: String, _old_state: int, _new_state: int) -> void:
	_update_agent_item(agent_id)
	# Also update button states
	var has_running := _agent_orchestrator.get_running_count() > 0
	var has_exited := _agent_orchestrator.get_sessions_by_state(AS_EXITED).size() > 0
	_kill_all_button.disabled = not has_running
	_cleanup_button.disabled = not has_exited


func _on_agent_exit(agent_id: String, _exit_code: int, _reason: String) -> void:
	_update_agent_item(agent_id)
	_cleanup_button.disabled = false


func _on_agent_removed(_agent_id: String) -> void:
	_refresh_agent_list()


func _on_agent_count_changed(_count: int) -> void:
	if _agent_orchestrator:
		var status := _agent_orchestrator.get_resource_status()
		_status_label.text = "%d/%d" % [status.active_agents, status.max_agents]


func _on_refresh_timer() -> void:
	# Just update the status label periodically
	if _agent_orchestrator:
		var status := _agent_orchestrator.get_resource_status()
		_status_label.text = "%d/%d" % [status.active_agents, status.max_agents]


func _on_agent_kill_pressed(agent_id: String) -> void:
	kill_agent_requested.emit(agent_id)


func _on_agent_focus_pressed(agent_id: String) -> void:
	focus_agent_requested.emit(agent_id)


func _on_agent_restart_pressed(agent_id: String) -> void:
	restart_agent_requested.emit(agent_id)


func _on_kill_all_button_pressed() -> void:
	kill_all_requested.emit()


func _on_cleanup_button_pressed() -> void:
	if _agent_orchestrator:
		var removed := _agent_orchestrator.cleanup_exited()
		if removed > 0:
			print("AgentListContent: Cleaned up %d exited agents" % removed)
		_refresh_agent_list()


# =============================================================================
# Public API
# =============================================================================

## Force refresh the agent list
func refresh() -> void:
	_refresh_agent_list()
