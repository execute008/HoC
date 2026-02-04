@tool
class_name TerminalPanel
extends WorkspacePanel


## Terminal panel for viewing agent output in VR.
##
## Extends WorkspacePanel to provide a terminal display with ANSI color support,
## scrollback buffer, and VR controller scrolling via thumbstick.


## Emitted when terminal content is updated
signal content_updated

## Emitted when scroll position changes
signal scroll_changed(position: int, max_position: int)


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


# Internal state
var _terminal_content: TerminalContent = null
var _is_terminal_focused: bool = false
var _scroll_accumulator: float = 0.0
var _left_controller: XRController3D = null
var _right_controller: XRController3D = null


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


func _process(delta: float) -> void:
	super._process(delta)

	if Engine.is_editor_hint():
		return

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


func _find_controllers() -> void:
	# Find XR controllers in the scene
	var xr_origin := _find_node_by_class(get_tree().root, "XROrigin3D")
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
	await get_tree().process_frame

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
	_is_terminal_focused = focused
	if _terminal_content:
		_terminal_content.set_focused(focused)


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
