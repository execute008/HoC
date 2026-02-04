class_name TerminalContent
extends Control


## Terminal content renderer with ANSI color support and scrollback buffer.
##
## This Control renders terminal output with monospace text, ANSI color codes,
## line wrapping, scrollback buffer, and a text cursor.
##
## Performance optimizations:
## - Dirty region tracking to minimize redraws
## - Frame-gated output processing
## - Update throttling for distant panels


## Emitted when the terminal requests scroll input (for VR controller integration)
signal scroll_requested(direction: int)

## Emitted when terminal content changes
signal content_changed

## Emitted when user clicks/taps on the terminal (for focus)
signal focus_requested


## Default terminal colors (matches standard ANSI 16-color palette)
const DEFAULT_FG_COLOR := Color(0.9, 0.9, 0.9)
const DEFAULT_BG_COLOR := Color(0.1, 0.1, 0.12, 1.0)

## Cursor blink rate in seconds
const CURSOR_BLINK_RATE := 0.5

## Maximum lines to render per frame for performance
const MAX_LINES_PER_FRAME := 50

## Output buffer size limit
const OUTPUT_BUFFER_LIMIT := 32768


## Scrollback buffer size (number of lines to keep)
@export var scrollback_size: int = 1000: set = set_scrollback_size

## Number of columns for line wrapping (0 = auto based on width)
@export var columns: int = 80: set = set_columns

## Font size in pixels
@export var font_size: int = 14: set = set_font_size

## Show the text cursor
@export var show_cursor: bool = true: set = set_show_cursor

## Cursor color
@export var cursor_color: Color = Color(0.8, 0.8, 0.8, 0.8)

## Background color
@export var background_color: Color = DEFAULT_BG_COLOR: set = set_background_color


# Internal state
var _lines: Array[TerminalLine] = []
var _scroll_offset: int = 0
var _cursor_row: int = 0
var _cursor_col: int = 0
var _cursor_visible: bool = true
var _cursor_blink_timer: float = 0.0
var _ansi_parser: AnsiParser
var _font: Font
var _char_size: Vector2 = Vector2.ZERO
var _visible_rows: int = 0
var _saved_cursor_row: int = 0
var _saved_cursor_col: int = 0
var _is_focused: bool = false

# Performance optimization state
var _dirty_lines: PackedInt32Array = PackedInt32Array()
var _full_redraw_needed: bool = true
var _output_buffer: String = ""
var _is_throttled: bool = false
var _last_content_hash: int = 0
var _frames_since_update: int = 0
var _update_throttle_frames: int = 0


## Represents a single line in the terminal with styled spans
class TerminalLine extends RefCounted:
	var spans: Array[AnsiParser.TextSpan] = []

	func get_plain_text() -> String:
		var result := ""
		for span in spans:
			result += span.text
		return result

	func get_length() -> int:
		var length := 0
		for span in spans:
			length += span.text.length()
		return length

	func clear() -> void:
		spans.clear()


func _ready() -> void:
	_ansi_parser = AnsiParser.new()
	_setup_font()
	_initialize_buffer()

	# Connect to resize
	resized.connect(_on_resized)

	# Initial calculation
	_calculate_dimensions()

	# Enable input handling for focus
	mouse_filter = Control.MOUSE_FILTER_STOP


func _gui_input(event: InputEvent) -> void:
	# Request focus when clicked
	if event is InputEventMouseButton:
		var mouse_event := event as InputEventMouseButton
		if mouse_event.pressed and mouse_event.button_index == MOUSE_BUTTON_LEFT:
			focus_requested.emit()
			accept_event()


func _process(delta: float) -> void:
	_frames_since_update += 1

	# Process buffered output if not throttled
	if not _is_throttled and not _output_buffer.is_empty():
		_process_buffered_output()

	# Handle cursor blinking (only if focused and not throttled)
	if show_cursor and _is_focused and not _is_throttled:
		_cursor_blink_timer += delta
		if _cursor_blink_timer >= CURSOR_BLINK_RATE:
			_cursor_blink_timer = 0.0
			_cursor_visible = not _cursor_visible
			_mark_cursor_dirty()


func _draw() -> void:
	# Draw background
	draw_rect(Rect2(Vector2.ZERO, size), background_color)

	if _char_size == Vector2.ZERO:
		return

	var y_offset := 0.0
	var start_line := _scroll_offset
	var end_line := mini(start_line + _visible_rows, _lines.size())

	# Limit lines per frame for performance if many lines need drawing
	var lines_to_draw := end_line - start_line
	if lines_to_draw > MAX_LINES_PER_FRAME and not _full_redraw_needed:
		# Only draw dirty lines
		for line_idx in _dirty_lines:
			if line_idx >= start_line and line_idx < end_line:
				var screen_row := line_idx - start_line
				var line_y := screen_row * _char_size.y
				_draw_line_at(_lines[line_idx], line_y)
	else:
		# Draw all visible lines (normal case)
		for line_idx in range(start_line, end_line):
			var line := _lines[line_idx]
			var x_offset := 0.0

			for span in line.spans:
				_draw_span(span, Vector2(x_offset, y_offset))
				x_offset += span.text.length() * _char_size.x

			y_offset += _char_size.y

	# Clear dirty state after draw
	_dirty_lines.clear()
	_full_redraw_needed = false

	# Draw cursor
	if show_cursor and _cursor_visible and _is_cursor_visible():
		_draw_cursor()


func _draw_line_at(line: TerminalLine, y_offset: float) -> void:
	var x_offset := 0.0
	for span in line.spans:
		_draw_span(span, Vector2(x_offset, y_offset))
		x_offset += span.text.length() * _char_size.x


func _draw_span(span: AnsiParser.TextSpan, position: Vector2) -> void:
	if span.text.is_empty():
		return

	var style := span.style
	var fg_color := style.foreground if style else DEFAULT_FG_COLOR
	var bg_color := style.background if style else Color.TRANSPARENT

	# Handle reverse video
	if style and style.has_attribute(AnsiParser.Attribute.REVERSE):
		var temp := fg_color
		fg_color = bg_color if bg_color.a > 0 else background_color
		bg_color = temp

	# Draw background if not transparent
	if bg_color.a > 0:
		var bg_rect := Rect2(
			position + Vector2(0, 2),  # Small offset for baseline
			Vector2(span.text.length() * _char_size.x, _char_size.y)
		)
		draw_rect(bg_rect, bg_color)

	# Handle hidden text
	if style and style.has_attribute(AnsiParser.Attribute.HIDDEN):
		return

	# Draw text
	var text_pos := position + Vector2(0, _char_size.y - 2)  # Baseline adjustment
	draw_string(_font, text_pos, span.text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, fg_color)

	# Draw underline
	if style and style.has_attribute(AnsiParser.Attribute.UNDERLINE):
		var underline_y := text_pos.y + 2
		draw_line(
			Vector2(position.x, underline_y),
			Vector2(position.x + span.text.length() * _char_size.x, underline_y),
			fg_color,
			1.0
		)

	# Draw strikethrough
	if style and style.has_attribute(AnsiParser.Attribute.STRIKETHROUGH):
		var strike_y := position.y + _char_size.y / 2
		draw_line(
			Vector2(position.x, strike_y),
			Vector2(position.x + span.text.length() * _char_size.x, strike_y),
			fg_color,
			1.0
		)


func _draw_cursor() -> void:
	var cursor_screen_row := _cursor_row - _scroll_offset
	if cursor_screen_row < 0 or cursor_screen_row >= _visible_rows:
		return

	var cursor_pos := Vector2(
		_cursor_col * _char_size.x,
		cursor_screen_row * _char_size.y + 2
	)

	# Draw block cursor
	var cursor_rect := Rect2(cursor_pos, Vector2(_char_size.x, _char_size.y))
	draw_rect(cursor_rect, cursor_color)


func _setup_font() -> void:
	# Use the default monospace font from Godot
	_font = ThemeDB.fallback_font
	_calculate_char_size()


func _calculate_char_size() -> void:
	if not _font:
		_char_size = Vector2(8, 16)
		return

	# Measure a monospace character
	var test_string := "M"
	_char_size.x = _font.get_string_size(test_string, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	_char_size.y = _font.get_height(font_size)


func _calculate_dimensions() -> void:
	_calculate_char_size()

	if _char_size.y > 0:
		_visible_rows = int(size.y / _char_size.y)
	else:
		_visible_rows = 24  # Default fallback

	# Auto-calculate columns if set to 0
	if columns == 0 and _char_size.x > 0:
		columns = int(size.x / _char_size.x)


func _initialize_buffer() -> void:
	_lines.clear()
	# Start with one empty line
	_lines.append(TerminalLine.new())
	_cursor_row = 0
	_cursor_col = 0
	_scroll_offset = 0


func _is_cursor_visible() -> bool:
	return _cursor_row >= _scroll_offset and _cursor_row < _scroll_offset + _visible_rows


func _ensure_line_exists(row: int) -> void:
	while _lines.size() <= row:
		_lines.append(TerminalLine.new())


func _trim_scrollback() -> void:
	while _lines.size() > scrollback_size:
		_lines.remove_at(0)
		_cursor_row = maxi(0, _cursor_row - 1)
		_scroll_offset = maxi(0, _scroll_offset - 1)


func _scroll_to_cursor() -> void:
	# Ensure cursor is visible
	if _cursor_row < _scroll_offset:
		_scroll_offset = _cursor_row
	elif _cursor_row >= _scroll_offset + _visible_rows:
		_scroll_offset = _cursor_row - _visible_rows + 1


func _on_resized() -> void:
	_calculate_dimensions()
	queue_redraw()


## Write text to the terminal (with ANSI parsing)
## Uses buffered output to prevent frame drops during bursts
func write(text: String) -> void:
	# Buffer the output for frame-gated processing
	_output_buffer += text

	# Limit buffer size to prevent memory issues
	if _output_buffer.length() > OUTPUT_BUFFER_LIMIT:
		# Force process excess data
		_process_buffered_output_immediate()
	elif not _is_throttled:
		# Process immediately if not throttled and buffer is small
		if _output_buffer.length() < 1024:
			_process_buffered_output_immediate()


## Process buffered output with frame budget limiting
func _process_buffered_output() -> void:
	if _output_buffer.is_empty():
		return

	# Limit bytes processed per frame
	var bytes_to_process := mini(_output_buffer.length(), 4096)
	var chunk := _output_buffer.substr(0, bytes_to_process)
	_output_buffer = _output_buffer.substr(bytes_to_process)

	_write_text_internal(chunk)


## Process all buffered output immediately (for flush/force scenarios)
func _process_buffered_output_immediate() -> void:
	if _output_buffer.is_empty():
		return

	_write_text_internal(_output_buffer)
	_output_buffer = ""


## Internal write implementation
func _write_text_internal(text: String) -> void:
	var start_row := _cursor_row

	var parse_result := _ansi_parser.parse(text)

	# Process clear commands first
	for clear_cmd in parse_result.clear_commands:
		_process_clear_command(clear_cmd)

	# Process cursor commands
	for cursor_cmd in parse_result.cursor_commands:
		_process_cursor_command(cursor_cmd)

	# Process text spans
	for span in parse_result.spans:
		_write_span(span)

	# Mark affected lines as dirty
	var end_row := _cursor_row
	for i in range(start_row, end_row + 1):
		_mark_line_dirty(i)

	_trim_scrollback()
	_scroll_to_cursor()
	queue_redraw()
	content_changed.emit()


## Mark a specific line as needing redraw
func _mark_line_dirty(line_idx: int) -> void:
	if line_idx not in _dirty_lines:
		_dirty_lines.append(line_idx)


## Mark cursor area as dirty
func _mark_cursor_dirty() -> void:
	_mark_line_dirty(_cursor_row)
	queue_redraw()


func _write_span(span: AnsiParser.TextSpan) -> void:
	var text := span.text
	var i := 0

	while i < text.length():
		var char := text[i]

		match char:
			"\n":
				_cursor_row += 1
				_cursor_col = 0
				_ensure_line_exists(_cursor_row)
			"\r":
				_cursor_col = 0
			"\t":
				# Tab to next 8-column boundary
				var tab_stop := ((_cursor_col / 8) + 1) * 8
				_cursor_col = mini(tab_stop, columns - 1) if columns > 0 else tab_stop
			"\b":
				# Backspace
				_cursor_col = maxi(0, _cursor_col - 1)
			_:
				_ensure_line_exists(_cursor_row)
				_write_char_at_cursor(char, span.style)
				_cursor_col += 1

				# Handle line wrapping
				if columns > 0 and _cursor_col >= columns:
					_cursor_row += 1
					_cursor_col = 0
					_ensure_line_exists(_cursor_row)

		i += 1


func _write_char_at_cursor(char: String, style: AnsiParser.TextStyle) -> void:
	var line := _lines[_cursor_row]

	# Find or create the span at the cursor position
	var current_col := 0
	var span_idx := 0
	var char_in_span := 0

	# Find which span contains the cursor position
	while span_idx < line.spans.size():
		var span := line.spans[span_idx]
		if current_col + span.text.length() > _cursor_col:
			char_in_span = _cursor_col - current_col
			break
		current_col += span.text.length()
		span_idx += 1

	# If cursor is past all existing spans, add new span
	if span_idx >= line.spans.size():
		# Pad with spaces if needed
		var padding := _cursor_col - current_col
		if padding > 0:
			var pad_span := AnsiParser.TextSpan.new(" ".repeat(padding), null)
			line.spans.append(pad_span)

		# Add the new character
		var new_span := AnsiParser.TextSpan.new(char, style)
		line.spans.append(new_span)
	else:
		# Insert/replace character in existing span
		var span := line.spans[span_idx]

		# Check if style matches
		if _styles_match(span.style, style):
			# Overwrite character in place
			var text := span.text
			if char_in_span < text.length():
				span.text = text.substr(0, char_in_span) + char + text.substr(char_in_span + 1)
			else:
				span.text += char
		else:
			# Need to split span and insert new styled span
			_split_and_insert(line, span_idx, char_in_span, char, style)


func _split_and_insert(line: TerminalLine, span_idx: int, char_pos: int, char: String, style: AnsiParser.TextStyle) -> void:
	var original_span := line.spans[span_idx]
	var original_text := original_span.text

	var new_spans: Array[AnsiParser.TextSpan] = []

	# Text before the insertion point
	if char_pos > 0:
		var before_span := AnsiParser.TextSpan.new(original_text.substr(0, char_pos), original_span.style)
		new_spans.append(before_span)

	# The new character with new style
	var new_span := AnsiParser.TextSpan.new(char, style)
	new_spans.append(new_span)

	# Text after the insertion point (skip one character for overwrite)
	if char_pos + 1 < original_text.length():
		var after_span := AnsiParser.TextSpan.new(original_text.substr(char_pos + 1), original_span.style)
		new_spans.append(after_span)

	# Replace the original span with new spans
	line.spans.remove_at(span_idx)
	for i in range(new_spans.size()):
		line.spans.insert(span_idx + i, new_spans[i])


func _styles_match(a: AnsiParser.TextStyle, b: AnsiParser.TextStyle) -> bool:
	if a == null and b == null:
		return true
	if a == null or b == null:
		return false
	return a.foreground == b.foreground and a.background == b.background and a.attributes == b.attributes


func _process_cursor_command(cmd: AnsiParser.CursorMovement) -> void:
	match cmd.command:
		AnsiParser.CursorCommand.UP:
			_cursor_row = maxi(0, _cursor_row - cmd.amount)
		AnsiParser.CursorCommand.DOWN:
			_cursor_row += cmd.amount
			_ensure_line_exists(_cursor_row)
		AnsiParser.CursorCommand.FORWARD:
			_cursor_col += cmd.amount
		AnsiParser.CursorCommand.BACK:
			_cursor_col = maxi(0, _cursor_col - cmd.amount)
		AnsiParser.CursorCommand.NEXT_LINE:
			_cursor_row += cmd.amount
			_cursor_col = 0
			_ensure_line_exists(_cursor_row)
		AnsiParser.CursorCommand.PREV_LINE:
			_cursor_row = maxi(0, _cursor_row - cmd.amount)
			_cursor_col = 0
		AnsiParser.CursorCommand.COLUMN:
			_cursor_col = maxi(0, cmd.column - 1)  # ANSI columns are 1-based
		AnsiParser.CursorCommand.POSITION:
			_cursor_row = maxi(0, cmd.row - 1)  # ANSI rows are 1-based
			_cursor_col = maxi(0, cmd.column - 1)
			_ensure_line_exists(_cursor_row)
		AnsiParser.CursorCommand.SAVE:
			_saved_cursor_row = _cursor_row
			_saved_cursor_col = _cursor_col
		AnsiParser.CursorCommand.RESTORE:
			_cursor_row = _saved_cursor_row
			_cursor_col = _saved_cursor_col


func _process_clear_command(cmd: AnsiParser.ClearOperation) -> void:
	match cmd.command:
		AnsiParser.ClearCommand.SCREEN_ALL, AnsiParser.ClearCommand.SCREEN_ALL_AND_SCROLLBACK:
			clear()
		AnsiParser.ClearCommand.SCREEN_TO_END:
			# Clear from cursor to end of screen
			_clear_line_from(_cursor_row, _cursor_col)
			for i in range(_cursor_row + 1, _lines.size()):
				_lines[i].clear()
		AnsiParser.ClearCommand.SCREEN_TO_START:
			# Clear from start of screen to cursor
			for i in range(_cursor_row):
				_lines[i].clear()
			_clear_line_to(_cursor_row, _cursor_col)
		AnsiParser.ClearCommand.LINE_ALL:
			if _cursor_row < _lines.size():
				_lines[_cursor_row].clear()
		AnsiParser.ClearCommand.LINE_TO_END:
			_clear_line_from(_cursor_row, _cursor_col)
		AnsiParser.ClearCommand.LINE_TO_START:
			_clear_line_to(_cursor_row, _cursor_col)


func _clear_line_from(row: int, col: int) -> void:
	if row >= _lines.size():
		return

	var line := _lines[row]
	var current_col := 0
	var spans_to_keep: Array[AnsiParser.TextSpan] = []

	for span in line.spans:
		var span_end := current_col + span.text.length()
		if span_end <= col:
			spans_to_keep.append(span)
		elif current_col < col:
			# Truncate this span
			var keep_length := col - current_col
			var truncated := AnsiParser.TextSpan.new(span.text.substr(0, keep_length), span.style)
			spans_to_keep.append(truncated)
			break
		else:
			break
		current_col = span_end

	line.spans = spans_to_keep


func _clear_line_to(row: int, col: int) -> void:
	if row >= _lines.size():
		return

	var line := _lines[row]
	var current_col := 0
	var new_spans: Array[AnsiParser.TextSpan] = []
	var found := false

	for span in line.spans:
		var span_end := current_col + span.text.length()
		if not found and span_end > col:
			# Start keeping from this span
			var skip_length := col - current_col + 1
			if skip_length < span.text.length():
				# Pad with spaces for the cleared portion
				var pad_span := AnsiParser.TextSpan.new(" ".repeat(col + 1), null)
				new_spans.append(pad_span)
				var kept := AnsiParser.TextSpan.new(span.text.substr(skip_length), span.style)
				new_spans.append(kept)
			found = true
		elif found:
			new_spans.append(span)
		current_col = span_end

	if not found:
		# Clear entire line up to col
		var pad_span := AnsiParser.TextSpan.new(" ".repeat(col + 1), null)
		new_spans.append(pad_span)

	line.spans = new_spans


## Write a line of text (automatically adds newline)
func writeln(text: String) -> void:
	write(text + "\n")


## Clear all terminal content
func clear() -> void:
	_initialize_buffer()
	_ansi_parser.reset()
	_output_buffer = ""
	_dirty_lines.clear()
	_full_redraw_needed = true
	queue_redraw()
	content_changed.emit()


## Scroll the terminal view by the specified number of lines
func scroll(lines: int) -> void:
	var max_scroll := maxi(0, _lines.size() - _visible_rows)
	_scroll_offset = clampi(_scroll_offset + lines, 0, max_scroll)
	queue_redraw()


## Scroll to the bottom (most recent output)
func scroll_to_bottom() -> void:
	_scroll_offset = maxi(0, _lines.size() - _visible_rows)
	queue_redraw()


## Scroll to the top (oldest output in scrollback)
func scroll_to_top() -> void:
	_scroll_offset = 0
	queue_redraw()


## Get the current scroll position (0 = top, max = bottom)
func get_scroll_position() -> int:
	return _scroll_offset


## Get the maximum scroll position
func get_max_scroll() -> int:
	return maxi(0, _lines.size() - _visible_rows)


## Check if scrolled to the bottom
func is_at_bottom() -> bool:
	return _scroll_offset >= get_max_scroll()


## Set focus state (affects cursor visibility)
func set_focused(focused: bool) -> void:
	_is_focused = focused
	if focused:
		_cursor_visible = true
		_cursor_blink_timer = 0.0
	queue_redraw()


## Get the total number of lines in the buffer
func get_line_count() -> int:
	return _lines.size()


## Get the number of visible rows
func get_visible_rows() -> int:
	return _visible_rows


## Get the cursor position
func get_cursor_position() -> Vector2i:
	return Vector2i(_cursor_col, _cursor_row)


## Set the cursor position
func set_cursor_position(col: int, row: int) -> void:
	_cursor_col = maxi(0, col)
	_cursor_row = maxi(0, row)
	_ensure_line_exists(_cursor_row)
	_scroll_to_cursor()
	queue_redraw()


# Property setters
func set_scrollback_size(value: int) -> void:
	scrollback_size = maxi(100, value)
	_trim_scrollback()


func set_columns(value: int) -> void:
	columns = maxi(0, value)
	_calculate_dimensions()
	queue_redraw()


func set_font_size(value: int) -> void:
	font_size = clampi(value, 8, 72)
	_calculate_char_size()
	_calculate_dimensions()
	queue_redraw()


func set_show_cursor(value: bool) -> void:
	show_cursor = value
	queue_redraw()


func set_background_color(value: Color) -> void:
	background_color = value
	_full_redraw_needed = true
	queue_redraw()


# =============================================================================
# Performance Optimization API
# =============================================================================

## Set update throttling state (called by PerformanceManager for distant panels)
func set_update_throttled(throttled: bool) -> void:
	_is_throttled = throttled
	if not throttled and not _output_buffer.is_empty():
		# Process any pending output when unthrottled
		queue_redraw()


## Check if terminal is currently throttled
func is_update_throttled() -> bool:
	return _is_throttled


## Get pending output buffer size
func get_pending_output_size() -> int:
	return _output_buffer.length()


## Force flush all pending output
func flush_output() -> void:
	_process_buffered_output_immediate()


## Request full redraw on next frame
func request_full_redraw() -> void:
	_full_redraw_needed = true
	queue_redraw()
