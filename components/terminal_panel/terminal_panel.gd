@tool
class_name TerminalPanel
extends WorkspacePanel


## Terminal panel for viewing agent output in VR.
##
## Extends WorkspacePanel to provide a terminal display with ANSI color support,
## scrollback buffer, and VR controller scrolling via thumbstick.
## Supports binding to agent sessions for real-time output display.


const OutputBufferScript = preload("res://scripts/output_buffer.gd")


## Emitted when terminal content is updated
signal content_updated

## Emitted when scroll position changes
signal scroll_changed(position: int, max_position: int)

## Emitted when bound agent state changes
signal agent_state_changed(state: int)

## Emitted when bound agent exits
signal agent_exited(exit_code: int, reason: String)

## Emitted when terminal receives focus
signal terminal_focused

## Emitted when terminal loses focus
signal terminal_unfocused


@export_group("Terminal")

## Scrollback buffer size (number of lines)
@export var scrollback_size: int = 1000: set = set_scrollback_size

## Number of columns for line wrapping (0 = auto)
@export var terminal_columns: int = 80: set = set_terminal_columns

## Terminal font size in pixels
@export var terminal_font_size: int = 14: set = set_terminal_font_size

## Show the text cursor
@export var show_terminal_cursor: bool = true: set = set_show_terminal_cursor

## Terminal background color
@export var terminal_background: Color = Color(0.1, 0.1, 0.12, 1.0): set = set_terminal_background

## Cursor color
@export var terminal_cursor_color: Color = Color(0.8, 0.8, 0.8, 0.8): set = set_terminal_cursor_color

@export_group("Scrolling")

## Scroll speed (lines per second when thumbstick is held)
@export var scroll_speed: float = 10.0

## Thumbstick deadzone for scrolling
@export var scroll_deadzone: float = 0.3

@export_group("Agent Binding")

## Auto-scroll to bottom when new output arrives (if already at bottom)
@export var auto_scroll: bool = true

## Show status indicator for agent state
@export var show_status_indicator: bool = true

@export_group("Performance")

## Enable output buffering for smoother performance
@export var enable_output_buffering: bool = true

## Maximum bytes to process per frame
@export var max_output_per_frame: int = 4096


# Internal state
var _terminal_content: TerminalContent = null
var _is_terminal_focused: bool = false
var _scroll_accumulator: float = 0.0
var _left_controller: XRController3D = null
var _right_controller: XRController3D = null

# Agent binding state
var _bound_agent_id: String = ""
var _agent_orchestrator: Node = null
var _output_callback: Callable
var _agent_state: int = -1  # -1 = unbound, otherwise AgentOrchestrator.AgentState
var _status_indicator: Control = null
var _was_at_bottom: bool = true

# Input routing
var _input_router: Node = null

# Performance optimization state
var _output_buffer: RefCounted = null  # OutputBuffer instance
var _is_update_throttled: bool = false
var _performance_manager: Node = null


func _ready() -> void:
	# Set terminal-specific defaults before parent _ready
	if title == "Panel":
		title = "Terminal"

	# Override content scene to use terminal content
	content_scene = load("res://components/terminal_panel/terminal_content.tscn")

	# Set appropriate viewport size for terminal
	if viewport_size == Vector2(800, 600):
		viewport_size = Vector2(960, 600)

	super._ready()

	# Get reference to terminal content after setup
	_connect_terminal_content()

	if not Engine.is_editor_hint():
		_find_controllers()
		_connect_agent_orchestrator()
		_connect_input_router()
		_connect_performance_manager()

		# Create output callback
		_output_callback = _on_agent_output

		# Initialize output buffer with callback
		if enable_output_buffering:
			_output_buffer = OutputBufferScript.new(_flush_buffered_output)

		# Connect to panel interaction signals for focus handling
		grabbed.connect(_on_panel_grabbed)
		released.connect(_on_panel_released)


func _exit_tree() -> void:
	# Clean up agent binding to prevent dangling callbacks
	if _bound_agent_id != "":
		unbind_agent()


func _process(delta: float) -> void:
	super._process(delta)

	if Engine.is_editor_hint():
		return

	# Process buffered output (frame-gated)
	if _output_buffer and not _is_update_throttled:
		_output_buffer.process_frame()

	# Handle VR controller scrolling when focused
	if _is_terminal_focused:
		_process_controller_scroll(delta)


func _connect_terminal_content() -> void:
	# Wait a frame for viewport to be ready
	if not is_inside_tree():
		return

	await get_tree().process_frame

	var content_instance := get_content_scene_instance()
	if content_instance and content_instance is TerminalContent:
		_terminal_content = content_instance
		_terminal_content.scrollback_size = scrollback_size
		_terminal_content.columns = terminal_columns
		_terminal_content.font_size = terminal_font_size
		_terminal_content.show_cursor = show_terminal_cursor
		_terminal_content.background_color = terminal_background
		_terminal_content.cursor_color = terminal_cursor_color
		_terminal_content.content_changed.connect(_on_terminal_content_changed)
		_terminal_content.focus_requested.connect(_on_terminal_focus_requested)


func _find_controllers() -> void:
	# Find XR controllers in the scene
	var xr_origin := Utils.find_node_by_class(get_tree().root, "XROrigin3D")
	if xr_origin:
		for child in xr_origin.get_children():
			if child is XRController3D:
				if "left" in child.name.to_lower():
					_left_controller = child
				elif "right" in child.name.to_lower():
					_right_controller = child


func _process_controller_scroll(delta: float) -> void:
	if not _terminal_content:
		return

	var scroll_input := 0.0

	# Check right controller thumbstick Y axis (primary hand for most users)
	if _right_controller:
		var thumbstick_y := _right_controller.get_float("primary")
		if absf(thumbstick_y) > scroll_deadzone:
			scroll_input = -thumbstick_y  # Negative because up on stick = scroll up

	# Check left controller as fallback
	if scroll_input == 0.0 and _left_controller:
		var thumbstick_y := _left_controller.get_float("primary")
		if absf(thumbstick_y) > scroll_deadzone:
			scroll_input = -thumbstick_y

	if scroll_input != 0.0:
		_scroll_accumulator += scroll_input * scroll_speed * delta
		var lines_to_scroll := int(_scroll_accumulator)
		if lines_to_scroll != 0:
			_scroll_accumulator -= lines_to_scroll
			_terminal_content.scroll(lines_to_scroll)
			scroll_changed.emit(
				_terminal_content.get_scroll_position(),
				_terminal_content.get_max_scroll()
			)


func _on_terminal_content_changed() -> void:
	content_updated.emit()


func _connect_agent_orchestrator() -> void:
	_agent_orchestrator = get_node_or_null("/root/AgentOrchestrator")
	if not _agent_orchestrator:
		push_warning("TerminalPanel: AgentOrchestrator autoload not found")
		return

	# Connect to agent lifecycle signals
	_agent_orchestrator.agent_state_changed.connect(_on_orchestrator_agent_state_changed)
	_agent_orchestrator.agent_exit.connect(_on_orchestrator_agent_exit)
	_agent_orchestrator.agent_removed.connect(_on_orchestrator_agent_removed)


func _connect_input_router() -> void:
	_input_router = get_node_or_null("/root/InputRouter")
	if not _input_router:
		push_warning("TerminalPanel: InputRouter autoload not found")


func _connect_performance_manager() -> void:
	_performance_manager = get_node_or_null("/root/PerformanceManager")
	# Performance manager is optional - graceful fallback if not present


func _on_panel_grabbed(by: Node3D) -> void:
	# Request focus when panel is grabbed
	request_focus()


func _on_panel_released() -> void:
	# Keep focus after release - user explicitly grabbed this panel
	pass


func _on_terminal_focus_requested() -> void:
	# Request focus when terminal content is clicked/tapped
	request_focus()


func _on_orchestrator_agent_state_changed(agent_id: String, old_state: int, new_state: int) -> void:
	if agent_id != _bound_agent_id:
		return

	_agent_state = new_state
	_update_status_indicator()
	agent_state_changed.emit(new_state)


func _on_orchestrator_agent_exit(agent_id: String, exit_code: int, reason: String) -> void:
	if agent_id != _bound_agent_id:
		return

	agent_exited.emit(exit_code, reason)


func _on_orchestrator_agent_removed(agent_id: String) -> void:
	if agent_id != _bound_agent_id:
		return

	# Agent was removed from orchestrator, unbind
	unbind_agent()


func _on_agent_output(data: String) -> void:
	# Track if we're at the bottom before writing
	_was_at_bottom = is_at_bottom()

	if enable_output_buffering and _output_buffer:
		# Buffer the output for frame-gated processing
		_output_buffer.append(data)
	else:
		# Write immediately (legacy behavior)
		write(data)

		# Auto-scroll to bottom if we were already at the bottom
		if auto_scroll and _was_at_bottom:
			scroll_to_bottom()


## Callback for flushing buffered output
func _flush_buffered_output(data: String) -> void:
	# Write data to terminal with ANSI parsing
	write(data)

	# Auto-scroll to bottom if we were already at the bottom
	if auto_scroll and _was_at_bottom:
		scroll_to_bottom()


# =============================================================================
# Public API - Agent Binding
# =============================================================================

## Bind this terminal to an agent session by ID.
## Real-time output will be displayed and agent state will be tracked.
## Returns true if binding was successful.
func bind_agent(agent_id: String) -> bool:
	if not _agent_orchestrator:
		push_error("TerminalPanel: Cannot bind agent - AgentOrchestrator not available")
		return false

	if not _agent_orchestrator.has_agent(agent_id):
		push_error("TerminalPanel: Cannot bind agent - unknown agent ID: %s" % agent_id)
		return false

	# Unbind current agent if any
	if _bound_agent_id != "":
		unbind_agent()

	# Register output callback
	var success: bool = _agent_orchestrator.register_output_callback(agent_id, _output_callback)
	if not success:
		push_error("TerminalPanel: Failed to register output callback for agent: %s" % agent_id)
		return false

	_bound_agent_id = agent_id

	# Get current state
	var session = _agent_orchestrator.get_session(agent_id)
	if session:
		_agent_state = session.state

		# Update title to show agent binding
		if title == "Terminal":
			title = "Terminal [%s]" % agent_id.substr(0, 8)

	# Update status indicator
	_update_status_indicator()

	print("TerminalPanel: Bound to agent: %s" % agent_id)
	return true


## Unbind from current agent session.
## The terminal will stop receiving output from the agent.
func unbind_agent() -> void:
	if _bound_agent_id == "" or not _agent_orchestrator:
		return

	# Unregister callback
	_agent_orchestrator.unregister_output_callback(_bound_agent_id, _output_callback)

	var old_id := _bound_agent_id
	_bound_agent_id = ""
	_agent_state = -1

	# Reset title
	if title.begins_with("Terminal ["):
		title = "Terminal"

	# Update status indicator
	_update_status_indicator()

	print("TerminalPanel: Unbound from agent: %s" % old_id)


## Check if terminal is bound to an agent
func is_bound() -> bool:
	return _bound_agent_id != ""


## Get the bound agent ID (empty string if not bound)
func get_bound_agent_id() -> String:
	return _bound_agent_id


## Get the current agent state (-1 if not bound)
func get_agent_state() -> int:
	return _agent_state


## Get the agent state as a human-readable string
func get_agent_state_string() -> String:
	match _agent_state:
		-1:
			return "Unbound"
		0:  # SPAWNING
			return "Spawning"
		1:  # RUNNING
			return "Running"
		2:  # EXITING
			return "Exiting"
		3:  # EXITED
			return "Exited"
		_:
			return "Unknown"


## Send input to the bound agent (if running)
func send_input(input: String) -> Error:
	if _bound_agent_id == "" or not _agent_orchestrator:
		return ERR_UNCONFIGURED

	return _agent_orchestrator.send_input(_bound_agent_id, input)


## Kill the bound agent
func kill_agent(signal_num: int = 0) -> Error:
	if _bound_agent_id == "" or not _agent_orchestrator:
		return ERR_UNCONFIGURED

	return _agent_orchestrator.kill_agent(_bound_agent_id, signal_num)


# =============================================================================
# Status Indicator
# =============================================================================

func _update_status_indicator() -> void:
	if not show_status_indicator:
		if _status_indicator:
			_status_indicator.queue_free()
			_status_indicator = null
		return

	# Create status indicator if needed
	if not _status_indicator:
		_create_status_indicator()

	if not _status_indicator:
		return

	# Update indicator based on state
	var color: Color
	var tooltip: String

	match _agent_state:
		-1:  # Unbound
			color = Color(0.4, 0.4, 0.4, 0.8)  # Gray
			tooltip = "Not bound to agent"
		0:  # SPAWNING
			color = Color(1.0, 0.8, 0.0, 1.0)  # Yellow
			tooltip = "Agent spawning..."
		1:  # RUNNING
			color = Color(0.2, 0.9, 0.3, 1.0)  # Green
			tooltip = "Agent running"
		2:  # EXITING
			color = Color(1.0, 0.5, 0.0, 1.0)  # Orange
			tooltip = "Agent exiting..."
		3:  # EXITED
			color = Color(0.6, 0.6, 0.6, 1.0)  # Light gray
			tooltip = "Agent exited"
		_:
			color = Color(0.5, 0.5, 0.5, 0.8)
			tooltip = "Unknown state"

	# Update the indicator color
	var indicator_circle = _status_indicator.get_node_or_null("Circle")
	if indicator_circle:
		indicator_circle.color = color

	_status_indicator.tooltip_text = tooltip


func _create_status_indicator() -> void:
	if not _terminal_content:
		return

	# Create a container for the status indicator
	_status_indicator = Control.new()
	_status_indicator.name = "StatusIndicator"
	_status_indicator.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_status_indicator.position = Vector2(-24, 8)
	_status_indicator.size = Vector2(16, 16)
	_status_indicator.mouse_filter = Control.MOUSE_FILTER_IGNORE

	# Create the circle indicator
	var circle = ColorRect.new()
	circle.name = "Circle"
	circle.set_anchors_preset(Control.PRESET_FULL_RECT)
	circle.color = Color(0.4, 0.4, 0.4, 0.8)

	# Add corner radius via shader for circle appearance
	var shader_code = """
shader_type canvas_item;

void fragment() {
	vec2 center = vec2(0.5, 0.5);
	float dist = distance(UV, center);
	if (dist > 0.5) {
		discard;
	}
	COLOR = COLOR;
}
"""
	var shader = Shader.new()
	shader.code = shader_code
	var shader_mat = ShaderMaterial.new()
	shader_mat.shader = shader
	circle.material = shader_mat

	_status_indicator.add_child(circle)

	# Add to terminal content's parent (the viewport)
	var viewport = _terminal_content.get_parent()
	if viewport:
		viewport.add_child(_status_indicator)


# =============================================================================
# Terminal Output
# =============================================================================

## Write text to the terminal (with ANSI parsing)
func write(text: String) -> void:
	if _terminal_content:
		_terminal_content.write(text)
	else:
		# Queue write for when terminal is ready
		_queue_write(text)


func _queue_write(text: String) -> void:
	# Wait for terminal to be ready
	if not is_inside_tree():
		return

	await get_tree().process_frame
	if not is_instance_valid(self) or not is_inside_tree():
		return

	await get_tree().process_frame
	if not is_instance_valid(self) or not is_inside_tree():
		return

	if _terminal_content:
		_terminal_content.write(text)
	else:
		# Try to connect again
		_connect_terminal_content()
		if _terminal_content:
			_terminal_content.write(text)


## Write a line of text (automatically adds newline)
func writeln(text: String) -> void:
	write(text + "\n")


## Clear all terminal content
func clear_terminal() -> void:
	if _terminal_content:
		_terminal_content.clear()


## Scroll the terminal by the specified number of lines
func scroll_terminal(lines: int) -> void:
	if _terminal_content:
		_terminal_content.scroll(lines)
		scroll_changed.emit(
			_terminal_content.get_scroll_position(),
			_terminal_content.get_max_scroll()
		)


## Scroll to the bottom (most recent output)
func scroll_to_bottom() -> void:
	if _terminal_content:
		_terminal_content.scroll_to_bottom()
		scroll_changed.emit(
			_terminal_content.get_scroll_position(),
			_terminal_content.get_max_scroll()
		)


## Scroll to the top (oldest output)
func scroll_to_top() -> void:
	if _terminal_content:
		_terminal_content.scroll_to_top()
		scroll_changed.emit(
			_terminal_content.get_scroll_position(),
			_terminal_content.get_max_scroll()
		)


## Set terminal focus state (enables controller scrolling and cursor)
func set_terminal_focused(focused: bool) -> void:
	var was_focused := _is_terminal_focused
	_is_terminal_focused = focused
	if _terminal_content:
		_terminal_content.set_focused(focused)

	# Emit signals for focus state change
	if focused and not was_focused:
		terminal_focused.emit()
	elif not focused and was_focused:
		terminal_unfocused.emit()


## Check if terminal is focused
func is_terminal_focused() -> bool:
	return _is_terminal_focused


## Get the total number of lines in the buffer
func get_line_count() -> int:
	if _terminal_content:
		return _terminal_content.get_line_count()
	return 0


## Get the number of visible rows
func get_visible_rows() -> int:
	if _terminal_content:
		return _terminal_content.get_visible_rows()
	return 0


## Get the current scroll position
func get_scroll_position() -> int:
	if _terminal_content:
		return _terminal_content.get_scroll_position()
	return 0


## Get the maximum scroll position
func get_max_scroll() -> int:
	if _terminal_content:
		return _terminal_content.get_max_scroll()
	return 0


## Check if scrolled to the bottom
func is_at_bottom() -> bool:
	if _terminal_content:
		return _terminal_content.is_at_bottom()
	return true


## Get the cursor position
func get_cursor_position() -> Vector2i:
	if _terminal_content:
		return _terminal_content.get_cursor_position()
	return Vector2i.ZERO


## Set the cursor position
func set_cursor_position(col: int, row: int) -> void:
	if _terminal_content:
		_terminal_content.set_cursor_position(col, row)


## Get the terminal content node for direct access
func get_terminal_content() -> TerminalContent:
	return _terminal_content


# Property setters
func set_scrollback_size(value: int) -> void:
	scrollback_size = value
	if _terminal_content:
		_terminal_content.scrollback_size = value


func set_terminal_columns(value: int) -> void:
	terminal_columns = value
	if _terminal_content:
		_terminal_content.columns = value


func set_terminal_font_size(value: int) -> void:
	terminal_font_size = value
	if _terminal_content:
		_terminal_content.font_size = value


func set_show_terminal_cursor(value: bool) -> void:
	show_terminal_cursor = value
	if _terminal_content:
		_terminal_content.show_cursor = value


func set_terminal_background(value: Color) -> void:
	terminal_background = value
	if _terminal_content:
		_terminal_content.background_color = value


func set_terminal_cursor_color(value: Color) -> void:
	terminal_cursor_color = value
	if _terminal_content:
		_terminal_content.cursor_color = value


# =============================================================================
# Focus Management
# =============================================================================

## Request focus for this terminal panel.
## This will route keyboard input to this panel's bound agent.
func request_focus() -> void:
	if _input_router:
		_input_router.set_focused_panel(self)
		terminal_focused.emit()


## Release focus from this terminal panel.
func release_focus() -> void:
	if _input_router and _input_router.is_panel_focused(self):
		_input_router.clear_focus()
		terminal_unfocused.emit()


## Check if this terminal panel has input focus.
func has_input_focus() -> bool:
	if _input_router:
		return _input_router.is_panel_focused(self)
	return false


## Send keyboard interrupt (Ctrl+C) to bound agent.
func send_interrupt() -> Error:
	if _bound_agent_id == "" or not _agent_orchestrator:
		return ERR_UNCONFIGURED

	# Send ETX character (Ctrl+C)
	return _agent_orchestrator.send_input(_bound_agent_id, "\u0003")


# =============================================================================
# Performance Optimization API
# =============================================================================

## Set update throttling state (called by PerformanceManager for distant panels)
func set_update_throttled(throttled: bool) -> void:
	_is_update_throttled = throttled
	if _terminal_content:
		_terminal_content.set_update_throttled(throttled)


## Check if panel updates are throttled
func is_update_throttled() -> bool:
	return _is_update_throttled


## Get pending output buffer size
func get_pending_output_size() -> int:
	if _output_buffer:
		return _output_buffer.get_buffer_size()
	elif _terminal_content:
		return _terminal_content.get_pending_output_size()
	return 0


## Force flush all pending output
func flush_output() -> void:
	if _output_buffer:
		_output_buffer.flush_immediate()
	if _terminal_content:
		_terminal_content.flush_output()


## Get buffer statistics
func get_buffer_stats() -> Dictionary:
	var stats := {}
	if _output_buffer:
		stats["panel_buffer"] = _output_buffer.get_stats()
	if _terminal_content:
		stats["terminal_pending"] = _terminal_content.get_pending_output_size()
	stats["throttled"] = _is_update_throttled
	return stats
