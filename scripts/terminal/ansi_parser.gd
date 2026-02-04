class_name AnsiParser
extends RefCounted


## ANSI escape code parser for terminal output rendering.
##
## Parses ANSI escape sequences and returns structured data that can be
## consumed by a terminal renderer. Supports SGR codes for colors and
## text attributes, basic cursor movement, and screen clear commands.


# ANSI escape sequence patterns
const ESC := "\u001b"
const CSI := ESC + "["


## Text attribute flags
enum Attribute {
	NONE = 0,
	BOLD = 1,
	ITALIC = 2,
	UNDERLINE = 4,
	BLINK = 8,
	REVERSE = 16,
	HIDDEN = 32,
	STRIKETHROUGH = 64,
}


## Cursor movement command types
enum CursorCommand {
	NONE,
	UP,
	DOWN,
	FORWARD,
	BACK,
	NEXT_LINE,
	PREV_LINE,
	COLUMN,
	POSITION,
	SAVE,
	RESTORE,
}


## Screen clear command types
enum ClearCommand {
	NONE,
	SCREEN_TO_END,
	SCREEN_TO_START,
	SCREEN_ALL,
	SCREEN_ALL_AND_SCROLLBACK,
	LINE_TO_END,
	LINE_TO_START,
	LINE_ALL,
}


## Standard ANSI colors (indices 0-7)
const STANDARD_COLORS: Array[Color] = [
	Color(0.0, 0.0, 0.0),       # 0: Black
	Color(0.8, 0.0, 0.0),       # 1: Red
	Color(0.0, 0.8, 0.0),       # 2: Green
	Color(0.8, 0.8, 0.0),       # 3: Yellow
	Color(0.0, 0.0, 0.8),       # 4: Blue
	Color(0.8, 0.0, 0.8),       # 5: Magenta
	Color(0.0, 0.8, 0.8),       # 6: Cyan
	Color(0.8, 0.8, 0.8),       # 7: White
]


## Bright ANSI colors (indices 8-15)
const BRIGHT_COLORS: Array[Color] = [
	Color(0.3, 0.3, 0.3),       # 8: Bright Black (Gray)
	Color(1.0, 0.0, 0.0),       # 9: Bright Red
	Color(0.0, 1.0, 0.0),       # 10: Bright Green
	Color(1.0, 1.0, 0.0),       # 11: Bright Yellow
	Color(0.0, 0.0, 1.0),       # 12: Bright Blue
	Color(1.0, 0.0, 1.0),       # 13: Bright Magenta
	Color(0.0, 1.0, 1.0),       # 14: Bright Cyan
	Color(1.0, 1.0, 1.0),       # 15: Bright White
]


## Default foreground and background colors
const DEFAULT_FG := Color(0.9, 0.9, 0.9)
const DEFAULT_BG := Color(0.0, 0.0, 0.0, 0.0)


## Represents the current text style state
class TextStyle extends RefCounted:
	var foreground: Color = DEFAULT_FG
	var background: Color = DEFAULT_BG
	var attributes: int = Attribute.NONE

	func duplicate() -> TextStyle:
		var copy := TextStyle.new()
		copy.foreground = foreground
		copy.background = background
		copy.attributes = attributes
		return copy

	func reset() -> void:
		foreground = DEFAULT_FG
		background = DEFAULT_BG
		attributes = Attribute.NONE

	func has_attribute(attr: Attribute) -> bool:
		return (attributes & attr) != 0

	func set_attribute(attr: Attribute, enabled: bool) -> void:
		if enabled:
			attributes |= attr
		else:
			attributes &= ~attr


## Represents a parsed text span with associated style
class TextSpan extends RefCounted:
	var text: String = ""
	var style: TextStyle = null

	func _init(p_text: String = "", p_style: TextStyle = null) -> void:
		text = p_text
		if p_style:
			style = p_style.duplicate()
		else:
			style = TextStyle.new()


## Represents a cursor movement command
class CursorMovement extends RefCounted:
	var command: CursorCommand = CursorCommand.NONE
	var amount: int = 1
	var row: int = 1
	var column: int = 1

	func _init(p_command: CursorCommand = CursorCommand.NONE, p_amount: int = 1) -> void:
		command = p_command
		amount = p_amount


## Represents a screen/line clear command
class ClearOperation extends RefCounted:
	var command: ClearCommand = ClearCommand.NONE

	func _init(p_command: ClearCommand = ClearCommand.NONE) -> void:
		command = p_command


## Result of parsing a line or buffer of text
class ParseResult extends RefCounted:
	var spans: Array[TextSpan] = []
	var cursor_commands: Array[CursorMovement] = []
	var clear_commands: Array[ClearOperation] = []

	func get_plain_text() -> String:
		var result := ""
		for span in spans:
			result += span.text
		return result


# Parser state
var _current_style: TextStyle
var _regex_csi: RegEx
var _regex_sgr: RegEx


func _init() -> void:
	_current_style = TextStyle.new()
	_compile_patterns()


func _compile_patterns() -> void:
	# CSI sequence pattern: ESC [ <params> <command>
	# Matches: ESC [ followed by optional numbers/semicolons, then a letter
	_regex_csi = RegEx.new()
	_regex_csi.compile("\\x1b\\[([0-9;]*)([A-Za-z])")

	# SGR parameter pattern for splitting
	_regex_sgr = RegEx.new()
	_regex_sgr.compile("[0-9]+")


## Parse a string containing ANSI escape codes
## Returns a ParseResult with styled text spans and commands
func parse(text: String) -> ParseResult:
	var result := ParseResult.new()
	var pos := 0
	var text_length := text.length()

	while pos < text_length:
		# Look for ESC character
		var esc_pos := text.find(ESC, pos)

		if esc_pos == -1:
			# No more escape sequences, add remaining text
			if pos < text_length:
				_add_text_span(result, text.substr(pos))
			break

		# Add any text before the escape sequence
		if esc_pos > pos:
			_add_text_span(result, text.substr(pos, esc_pos - pos))

		# Check if this is a CSI sequence
		if esc_pos + 1 < text_length and text[esc_pos + 1] == "[":
			var match_result := _regex_csi.search(text, esc_pos)
			if match_result and match_result.get_start() == esc_pos:
				var params := match_result.get_string(1)
				var command := match_result.get_string(2)
				_process_csi_sequence(result, params, command)
				pos = match_result.get_end()
				continue

		# Unknown escape sequence, skip ESC and continue
		pos = esc_pos + 1

	return result


## Reset the parser state (style) to defaults
func reset() -> void:
	_current_style.reset()


## Get a color by index (0-15 for standard/bright colors)
func get_color(index: int) -> Color:
	if index < 0:
		return DEFAULT_FG
	elif index < 8:
		return STANDARD_COLORS[index]
	elif index < 16:
		return BRIGHT_COLORS[index - 8]
	else:
		return DEFAULT_FG


func _add_text_span(result: ParseResult, text: String) -> void:
	if text.is_empty():
		return
	var span := TextSpan.new(text, _current_style)
	result.spans.append(span)


func _process_csi_sequence(result: ParseResult, params: String, command: String) -> void:
	match command:
		"m":
			_process_sgr(params)
		"A":
			_add_cursor_command(result, CursorCommand.UP, _parse_int(params, 1))
		"B":
			_add_cursor_command(result, CursorCommand.DOWN, _parse_int(params, 1))
		"C":
			_add_cursor_command(result, CursorCommand.FORWARD, _parse_int(params, 1))
		"D":
			_add_cursor_command(result, CursorCommand.BACK, _parse_int(params, 1))
		"E":
			_add_cursor_command(result, CursorCommand.NEXT_LINE, _parse_int(params, 1))
		"F":
			_add_cursor_command(result, CursorCommand.PREV_LINE, _parse_int(params, 1))
		"G":
			_add_cursor_column(result, _parse_int(params, 1))
		"H", "f":
			_add_cursor_position(result, params)
		"J":
			_process_clear_screen(result, _parse_int(params, 0))
		"K":
			_process_clear_line(result, _parse_int(params, 0))
		"s":
			_add_cursor_command(result, CursorCommand.SAVE, 0)
		"u":
			_add_cursor_command(result, CursorCommand.RESTORE, 0)


func _process_sgr(params: String) -> void:
	# Handle empty params as reset
	if params.is_empty():
		_current_style.reset()
		return

	var codes := _split_params(params)
	var i := 0

	while i < codes.size():
		var code := codes[i]

		match code:
			0:
				_current_style.reset()
			1:
				_current_style.set_attribute(Attribute.BOLD, true)
			2:
				# Dim/faint - not commonly used, treat as removing bold
				_current_style.set_attribute(Attribute.BOLD, false)
			3:
				_current_style.set_attribute(Attribute.ITALIC, true)
			4:
				_current_style.set_attribute(Attribute.UNDERLINE, true)
			5, 6:
				_current_style.set_attribute(Attribute.BLINK, true)
			7:
				_current_style.set_attribute(Attribute.REVERSE, true)
			8:
				_current_style.set_attribute(Attribute.HIDDEN, true)
			9:
				_current_style.set_attribute(Attribute.STRIKETHROUGH, true)
			21:
				# Double underline or bold off (varies by terminal)
				_current_style.set_attribute(Attribute.BOLD, false)
			22:
				_current_style.set_attribute(Attribute.BOLD, false)
			23:
				_current_style.set_attribute(Attribute.ITALIC, false)
			24:
				_current_style.set_attribute(Attribute.UNDERLINE, false)
			25:
				_current_style.set_attribute(Attribute.BLINK, false)
			27:
				_current_style.set_attribute(Attribute.REVERSE, false)
			28:
				_current_style.set_attribute(Attribute.HIDDEN, false)
			29:
				_current_style.set_attribute(Attribute.STRIKETHROUGH, false)
			30, 31, 32, 33, 34, 35, 36, 37:
				# Standard foreground colors (30-37)
				_current_style.foreground = STANDARD_COLORS[code - 30]
			38:
				# Extended foreground color
				i = _process_extended_color(codes, i, true)
			39:
				# Default foreground
				_current_style.foreground = DEFAULT_FG
			40, 41, 42, 43, 44, 45, 46, 47:
				# Standard background colors (40-47)
				_current_style.background = STANDARD_COLORS[code - 40]
			48:
				# Extended background color
				i = _process_extended_color(codes, i, false)
			49:
				# Default background
				_current_style.background = DEFAULT_BG
			90, 91, 92, 93, 94, 95, 96, 97:
				# Bright foreground colors (90-97)
				_current_style.foreground = BRIGHT_COLORS[code - 90]
			100, 101, 102, 103, 104, 105, 106, 107:
				# Bright background colors (100-107)
				_current_style.background = BRIGHT_COLORS[code - 100]

		i += 1


func _process_extended_color(codes: Array[int], index: int, is_foreground: bool) -> int:
	# Extended color format: 38;5;n (256 color) or 38;2;r;g;b (true color)
	if index + 1 >= codes.size():
		return index

	var mode := codes[index + 1]

	if mode == 5:
		# 256 color mode: 38;5;n
		if index + 2 < codes.size():
			var color_index := codes[index + 2]
			var color := _get_256_color(color_index)
			if is_foreground:
				_current_style.foreground = color
			else:
				_current_style.background = color
			return index + 2
	elif mode == 2:
		# True color mode: 38;2;r;g;b
		if index + 4 < codes.size():
			var r := clampf(codes[index + 2] / 255.0, 0.0, 1.0)
			var g := clampf(codes[index + 3] / 255.0, 0.0, 1.0)
			var b := clampf(codes[index + 4] / 255.0, 0.0, 1.0)
			var color := Color(r, g, b)
			if is_foreground:
				_current_style.foreground = color
			else:
				_current_style.background = color
			return index + 4

	return index


func _get_256_color(index: int) -> Color:
	if index < 0 or index > 255:
		return DEFAULT_FG

	# Standard colors (0-7)
	if index < 8:
		return STANDARD_COLORS[index]

	# Bright colors (8-15)
	if index < 16:
		return BRIGHT_COLORS[index - 8]

	# 216 color cube (16-231): 6x6x6 cube
	if index < 232:
		var cube_index := index - 16
		var r := (cube_index / 36) % 6
		var g := (cube_index / 6) % 6
		var b := cube_index % 6
		return Color(
			r * 0.2 if r > 0 else 0.0,
			g * 0.2 if g > 0 else 0.0,
			b * 0.2 if b > 0 else 0.0
		)

	# Grayscale (232-255): 24 shades
	var gray := (index - 232) / 23.0
	return Color(gray, gray, gray)


func _add_cursor_command(result: ParseResult, command: CursorCommand, amount: int) -> void:
	var movement := CursorMovement.new(command, amount)
	result.cursor_commands.append(movement)


func _add_cursor_column(result: ParseResult, column: int) -> void:
	var movement := CursorMovement.new(CursorCommand.COLUMN)
	movement.column = column
	result.cursor_commands.append(movement)


func _add_cursor_position(result: ParseResult, params: String) -> void:
	var parts := params.split(";")
	var row := 1
	var column := 1

	if parts.size() >= 1 and not parts[0].is_empty():
		row = parts[0].to_int()
	if parts.size() >= 2 and not parts[1].is_empty():
		column = parts[1].to_int()

	var movement := CursorMovement.new(CursorCommand.POSITION)
	movement.row = max(1, row)
	movement.column = max(1, column)
	result.cursor_commands.append(movement)


func _process_clear_screen(result: ParseResult, mode: int) -> void:
	var command: ClearCommand
	match mode:
		0:
			command = ClearCommand.SCREEN_TO_END
		1:
			command = ClearCommand.SCREEN_TO_START
		2:
			command = ClearCommand.SCREEN_ALL
		3:
			command = ClearCommand.SCREEN_ALL_AND_SCROLLBACK
		_:
			command = ClearCommand.SCREEN_TO_END

	result.clear_commands.append(ClearOperation.new(command))


func _process_clear_line(result: ParseResult, mode: int) -> void:
	var command: ClearCommand
	match mode:
		0:
			command = ClearCommand.LINE_TO_END
		1:
			command = ClearCommand.LINE_TO_START
		2:
			command = ClearCommand.LINE_ALL
		_:
			command = ClearCommand.LINE_TO_END

	result.clear_commands.append(ClearOperation.new(command))


func _split_params(params: String) -> Array[int]:
	var result: Array[int] = []
	var parts := params.split(";")
	for part in parts:
		if part.is_empty():
			result.append(0)
		else:
			result.append(part.to_int())
	return result


func _parse_int(value: String, default: int) -> int:
	if value.is_empty():
		return default
	return value.to_int()
