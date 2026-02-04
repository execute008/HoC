class_name WorktreeContent
extends Control


## WorktreeContent - 2D UI content for managing git worktrees
##
## Displays a visual tree of worktrees and provides controls to create
## new worktrees and select them for agent working directories.


# =============================================================================
# Signals
# =============================================================================

## Emitted when a worktree is selected
signal worktree_selected(path: String, branch: String)

## Emitted when user requests to create a worktree
signal create_worktree_requested(branch_name: String, base_path: String)

## Emitted when the panel should be closed
signal close_requested

## Emitted when an error occurs
signal error_occurred(message: String)


# =============================================================================
# Constants
# =============================================================================

const THEME_BG_COLOR := Color(0.12, 0.12, 0.15, 0.95)
const THEME_ITEM_COLOR := Color(0.18, 0.18, 0.22, 0.9)
const THEME_ITEM_HOVER := Color(0.22, 0.22, 0.28, 0.95)
const THEME_ITEM_SELECTED := Color(0.25, 0.35, 0.5, 0.95)
const THEME_ACCENT_COLOR := Color(0.4, 0.6, 0.9)
const THEME_SUCCESS_COLOR := Color(0.3, 0.8, 0.4)
const THEME_WARNING_COLOR := Color(0.9, 0.7, 0.2)
const THEME_DANGER_COLOR := Color(0.8, 0.3, 0.3)
const THEME_TEXT_PRIMARY := Color(0.95, 0.95, 0.98)
const THEME_TEXT_SECONDARY := Color(0.65, 0.65, 0.7)
const THEME_TREE_LINE := Color(0.35, 0.35, 0.4)

const MAIN_BRANCH_COLOR := Color(0.4, 0.8, 0.5)
const LINKED_BRANCH_COLOR := Color(0.5, 0.7, 0.95)


# =============================================================================
# Data Types
# =============================================================================

class WorktreeInfo:
	var path: String
	var branch: String
	var is_main: bool
	var is_bare: bool
	var is_locked: bool
	var commit_hash: String

	func _init(p_path: String = "", p_branch: String = "", p_is_main: bool = false) -> void:
		path = p_path
		branch = p_branch
		is_main = p_is_main
		is_bare = false
		is_locked = false
		commit_hash = ""


# =============================================================================
# State
# =============================================================================

var _repository_path: String = ""
var _worktrees: Array[WorktreeInfo] = []
var _selected_worktree: WorktreeInfo = null
var _is_git_repo: bool = false

# UI References
var _main_container: VBoxContainer
var _repo_label: Label
var _status_label: Label
var _tree_container: VBoxContainer
var _scroll_container: ScrollContainer
var _branch_input: LineEdit
var _create_button: Button
var _use_button: Button
var _error_label: Label
var _empty_label: Label


# =============================================================================
# Lifecycle
# =============================================================================

func _ready() -> void:
	_setup_ui()


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
	inner_container.add_theme_constant_override("separation", 12)
	margin.add_child(inner_container)

	# Header section
	_create_header_section(inner_container)

	# Tree visualization section
	_create_tree_section(inner_container)

	# Create worktree section
	_create_create_section(inner_container)

	# Action buttons section
	_create_action_section(inner_container)


func _create_header_section(parent: Control) -> void:
	var header := VBoxContainer.new()
	header.name = "HeaderSection"
	header.add_theme_constant_override("separation", 6)
	parent.add_child(header)

	# Title row
	var title_row := HBoxContainer.new()
	title_row.name = "TitleRow"
	header.add_child(title_row)

	var title_label := Label.new()
	title_label.name = "TitleLabel"
	title_label.text = "Worktree Manager"
	title_label.add_theme_font_size_override("font_size", 18)
	title_label.add_theme_color_override("font_color", THEME_TEXT_PRIMARY)
	title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(title_label)

	_status_label = Label.new()
	_status_label.name = "StatusLabel"
	_status_label.text = "0 worktrees"
	_status_label.add_theme_font_size_override("font_size", 12)
	_status_label.add_theme_color_override("font_color", THEME_TEXT_SECONDARY)
	title_row.add_child(_status_label)

	# Repository path
	_repo_label = Label.new()
	_repo_label.name = "RepoLabel"
	_repo_label.text = "No repository selected"
	_repo_label.add_theme_font_size_override("font_size", 11)
	_repo_label.add_theme_color_override("font_color", THEME_TEXT_SECONDARY)
	_repo_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	header.add_child(_repo_label)

	# Separator
	var separator := HSeparator.new()
	separator.name = "HeaderSeparator"
	header.add_child(separator)


func _create_tree_section(parent: Control) -> void:
	var tree_section := VBoxContainer.new()
	tree_section.name = "TreeSection"
	tree_section.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tree_section.add_theme_constant_override("separation", 6)
	parent.add_child(tree_section)

	# Section label
	var section_label := Label.new()
	section_label.name = "TreeSectionLabel"
	section_label.text = "Worktree Tree"
	section_label.add_theme_font_size_override("font_size", 13)
	section_label.add_theme_color_override("font_color", THEME_TEXT_SECONDARY)
	tree_section.add_child(section_label)

	# Scroll container for tree
	_scroll_container = ScrollContainer.new()
	_scroll_container.name = "TreeScrollContainer"
	_scroll_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll_container.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	tree_section.add_child(_scroll_container)

	_tree_container = VBoxContainer.new()
	_tree_container.name = "TreeContainer"
	_tree_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tree_container.add_theme_constant_override("separation", 2)
	_scroll_container.add_child(_tree_container)

	# Empty message
	_empty_label = Label.new()
	_empty_label.name = "EmptyLabel"
	_empty_label.text = "No worktrees found"
	_empty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty_label.add_theme_font_size_override("font_size", 13)
	_empty_label.add_theme_color_override("font_color", THEME_TEXT_SECONDARY)
	_tree_container.add_child(_empty_label)


func _create_create_section(parent: Control) -> void:
	var create_section := VBoxContainer.new()
	create_section.name = "CreateSection"
	create_section.add_theme_constant_override("separation", 8)
	parent.add_child(create_section)

	# Separator
	var separator := HSeparator.new()
	separator.name = "CreateSeparator"
	create_section.add_child(separator)

	# Section label
	var section_label := Label.new()
	section_label.name = "CreateSectionLabel"
	section_label.text = "Create New Worktree"
	section_label.add_theme_font_size_override("font_size", 13)
	section_label.add_theme_color_override("font_color", THEME_TEXT_SECONDARY)
	create_section.add_child(section_label)

	# Input row
	var input_row := HBoxContainer.new()
	input_row.name = "InputRow"
	input_row.add_theme_constant_override("separation", 8)
	create_section.add_child(input_row)

	# Branch name input
	_branch_input = LineEdit.new()
	_branch_input.name = "BranchInput"
	_branch_input.placeholder_text = "Branch name (e.g., feature/my-feature)"
	_branch_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_branch_input.custom_minimum_size = Vector2(0, 36)
	_style_text_input(_branch_input)
	_branch_input.text_submitted.connect(_on_branch_input_submitted)
	input_row.add_child(_branch_input)

	# Create button
	_create_button = Button.new()
	_create_button.name = "CreateButton"
	_create_button.text = "Create"
	_create_button.custom_minimum_size = Vector2(80, 36)
	_style_primary_button(_create_button)
	_create_button.pressed.connect(_on_create_button_pressed)
	input_row.add_child(_create_button)

	# Error label
	_error_label = Label.new()
	_error_label.name = "ErrorLabel"
	_error_label.text = ""
	_error_label.add_theme_font_size_override("font_size", 11)
	_error_label.add_theme_color_override("font_color", THEME_DANGER_COLOR)
	_error_label.visible = false
	create_section.add_child(_error_label)


func _create_action_section(parent: Control) -> void:
	var action_section := HBoxContainer.new()
	action_section.name = "ActionSection"
	action_section.add_theme_constant_override("separation", 8)
	parent.add_child(action_section)

	# Refresh button
	var refresh_button := Button.new()
	refresh_button.name = "RefreshButton"
	refresh_button.text = "Refresh"
	refresh_button.custom_minimum_size = Vector2(0, 40)
	refresh_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_secondary_button(refresh_button)
	refresh_button.pressed.connect(_on_refresh_button_pressed)
	action_section.add_child(refresh_button)

	# Use selected button
	_use_button = Button.new()
	_use_button.name = "UseButton"
	_use_button.text = "Use Selected"
	_use_button.custom_minimum_size = Vector2(0, 40)
	_use_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_primary_button(_use_button)
	_use_button.disabled = true
	_use_button.pressed.connect(_on_use_button_pressed)
	action_section.add_child(_use_button)


# =============================================================================
# Tree Visualization
# =============================================================================

func _rebuild_tree_view() -> void:
	# Clear existing items
	for child in _tree_container.get_children():
		if child != _empty_label:
			child.queue_free()

	_empty_label.visible = _worktrees.is_empty()

	if _worktrees.is_empty():
		return

	# Find main worktree
	var main_worktree: WorktreeInfo = null
	var linked_worktrees: Array[WorktreeInfo] = []

	for wt in _worktrees:
		if wt.is_main:
			main_worktree = wt
		else:
			linked_worktrees.append(wt)

	# Create main worktree node (root of tree)
	if main_worktree:
		var main_item := _create_tree_item(main_worktree, true, false)
		_tree_container.add_child(main_item)

	# Create linked worktrees with visual tree lines
	for i in range(linked_worktrees.size()):
		var wt := linked_worktrees[i]
		var is_last := (i == linked_worktrees.size() - 1)
		var linked_item := _create_tree_item(wt, false, is_last)
		_tree_container.add_child(linked_item)

	# Move empty label to end
	_tree_container.move_child(_empty_label, _tree_container.get_child_count() - 1)


func _create_tree_item(worktree: WorktreeInfo, is_root: bool, is_last_child: bool) -> Control:
	var item := PanelContainer.new()
	item.name = "Worktree_" + worktree.branch.replace("/", "_")
	item.custom_minimum_size = Vector2(0, 70)
	item.set_meta("worktree", worktree)

	# Item style
	var style := StyleBoxFlat.new()
	var is_selected := _selected_worktree and _selected_worktree.path == worktree.path
	style.bg_color = THEME_ITEM_SELECTED if is_selected else THEME_ITEM_COLOR
	style.border_color = THEME_ACCENT_COLOR if is_selected else Color(0.28, 0.28, 0.32)
	style.set_border_width_all(1 if not is_selected else 2)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(10)
	item.add_theme_stylebox_override("panel", style)

	# Make clickable
	item.gui_input.connect(_on_tree_item_input.bind(item, worktree))
	item.mouse_entered.connect(_on_tree_item_hover.bind(item, true))
	item.mouse_exited.connect(_on_tree_item_hover.bind(item, false))

	# Main horizontal layout
	var hbox := HBoxContainer.new()
	hbox.name = "Content"
	hbox.add_theme_constant_override("separation", 10)
	item.add_child(hbox)

	# Tree structure indicator
	var tree_indicator := VBoxContainer.new()
	tree_indicator.name = "TreeIndicator"
	tree_indicator.custom_minimum_size = Vector2(24, 0)
	hbox.add_child(tree_indicator)

	if is_root:
		# Root node - show tree icon
		var root_icon := Label.new()
		root_icon.text = ""
		root_icon.add_theme_font_size_override("font_size", 18)
		root_icon.add_theme_color_override("font_color", MAIN_BRANCH_COLOR)
		root_icon.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		root_icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		tree_indicator.add_child(root_icon)
	else:
		# Child node - show branch line
		var line_container := Control.new()
		line_container.name = "LineContainer"
		line_container.custom_minimum_size = Vector2(24, 50)
		tree_indicator.add_child(line_container)

		# Draw tree lines using custom draw
		line_container.draw.connect(_draw_tree_lines.bind(line_container, is_last_child))
		line_container.queue_redraw()

	# Info container
	var info_container := VBoxContainer.new()
	info_container.name = "InfoContainer"
	info_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info_container.add_theme_constant_override("separation", 4)
	hbox.add_child(info_container)

	# Branch name row
	var branch_row := HBoxContainer.new()
	branch_row.name = "BranchRow"
	branch_row.add_theme_constant_override("separation", 8)
	info_container.add_child(branch_row)

	# Branch indicator
	var branch_dot := ColorRect.new()
	branch_dot.name = "BranchDot"
	branch_dot.custom_minimum_size = Vector2(10, 10)
	branch_dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	branch_dot.color = MAIN_BRANCH_COLOR if worktree.is_main else LINKED_BRANCH_COLOR
	_make_circular(branch_dot)
	branch_row.add_child(branch_dot)

	# Branch name
	var branch_label := Label.new()
	branch_label.name = "BranchLabel"
	branch_label.text = worktree.branch if worktree.branch else "(detached)"
	branch_label.add_theme_font_size_override("font_size", 14)
	branch_label.add_theme_color_override("font_color", THEME_TEXT_PRIMARY)
	branch_row.add_child(branch_label)

	# Main badge
	if worktree.is_main:
		var main_badge := Label.new()
		main_badge.name = "MainBadge"
		main_badge.text = "main"
		main_badge.add_theme_font_size_override("font_size", 10)
		main_badge.add_theme_color_override("font_color", MAIN_BRANCH_COLOR)
		branch_row.add_child(main_badge)

	# Path
	var path_label := Label.new()
	path_label.name = "PathLabel"
	path_label.text = worktree.path
	path_label.add_theme_font_size_override("font_size", 10)
	path_label.add_theme_color_override("font_color", THEME_TEXT_SECONDARY)
	path_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	path_label.tooltip_text = worktree.path
	info_container.add_child(path_label)

	return item


func _draw_tree_lines(container: Control, is_last: bool) -> void:
	var width := container.size.x
	var height := container.size.y
	var mid_x := width / 2
	var mid_y := height / 2

	# Draw vertical line (from top to middle, or full height if not last)
	container.draw_line(
		Vector2(mid_x, 0),
		Vector2(mid_x, mid_y if is_last else height),
		THEME_TREE_LINE,
		2.0
	)

	# Draw horizontal line (from middle to right)
	container.draw_line(
		Vector2(mid_x, mid_y),
		Vector2(width, mid_y),
		THEME_TREE_LINE,
		2.0
	)


func _make_circular(rect: ColorRect) -> void:
	var shader_code := """
shader_type canvas_item;
void fragment() {
	vec2 center = vec2(0.5, 0.5);
	float dist = distance(UV, center);
	if (dist > 0.5) discard;
	COLOR = COLOR;
}
"""
	var shader := Shader.new()
	shader.code = shader_code
	var shader_mat := ShaderMaterial.new()
	shader_mat.shader = shader
	rect.material = shader_mat


# =============================================================================
# Git Operations
# =============================================================================

func _check_git_repository() -> bool:
	if _repository_path == "":
		_is_git_repo = false
		return false

	var output: Array = []
	var exit_code := OS.execute("git", ["-C", _repository_path, "rev-parse", "--git-dir"], output, true)
	_is_git_repo = (exit_code == 0)
	return _is_git_repo


func _load_worktrees() -> void:
	_worktrees.clear()

	if not _is_git_repo:
		_rebuild_tree_view()
		_update_status()
		return

	var output: Array = []
	var exit_code := OS.execute("git", ["-C", _repository_path, "worktree", "list", "--porcelain"], output, true)

	if exit_code != 0:
		_show_error("Failed to list worktrees")
		_rebuild_tree_view()
		_update_status()
		return

	# Parse porcelain output
	var output_text: String = output[0] if output.size() > 0 else ""
	var lines := output_text.split("\n")

	var current_worktree: WorktreeInfo = null
	var is_first := true

	for line in lines:
		line = line.strip_edges()
		if line == "":
			if current_worktree:
				_worktrees.append(current_worktree)
				current_worktree = null
			continue

		if line.begins_with("worktree "):
			if current_worktree:
				_worktrees.append(current_worktree)
			current_worktree = WorktreeInfo.new()
			current_worktree.path = line.substr(9)
			current_worktree.is_main = is_first
			is_first = false
		elif line.begins_with("HEAD ") and current_worktree:
			current_worktree.commit_hash = line.substr(5)
		elif line.begins_with("branch ") and current_worktree:
			var branch_ref := line.substr(7)
			# Extract branch name from refs/heads/
			if branch_ref.begins_with("refs/heads/"):
				current_worktree.branch = branch_ref.substr(11)
			else:
				current_worktree.branch = branch_ref
		elif line == "bare" and current_worktree:
			current_worktree.is_bare = true
		elif line == "locked" and current_worktree:
			current_worktree.is_locked = true
		elif line == "detached" and current_worktree:
			current_worktree.branch = "(detached HEAD)"

	# Don't forget the last worktree
	if current_worktree:
		_worktrees.append(current_worktree)

	_rebuild_tree_view()
	_update_status()


func create_worktree(branch_name: String, base_path: String = "") -> Dictionary:
	var result := {"success": false, "path": "", "error": ""}

	if not _is_git_repo:
		result.error = "Not a git repository"
		_show_error(result.error)
		return result

	if branch_name.strip_edges() == "":
		result.error = "Branch name cannot be empty"
		_show_error(result.error)
		return result

	# Sanitize branch name
	var safe_branch := branch_name.strip_edges().replace(" ", "-")

	# Determine worktree path
	var repo_parent := _repository_path.get_base_dir()
	var repo_name := _repository_path.get_file()
	var worktree_dir := safe_branch.replace("/", "-")
	var worktree_path := ""

	if base_path != "":
		worktree_path = base_path.path_join(worktree_dir)
	else:
		# Create worktrees directory next to the main repo
		var worktrees_base := repo_parent.path_join(repo_name + "-worktrees")
		worktree_path = worktrees_base.path_join(worktree_dir)

	# Check if branch exists locally
	var branch_exists := _branch_exists(safe_branch)

	var output: Array = []
	var exit_code: int

	if branch_exists:
		# Use existing branch
		exit_code = OS.execute("git", [
			"-C", _repository_path,
			"worktree", "add",
			worktree_path,
			safe_branch
		], output, true)
	else:
		# Create new branch from HEAD
		exit_code = OS.execute("git", [
			"-C", _repository_path,
			"worktree", "add",
			"-b", safe_branch,
			worktree_path
		], output, true)

	if exit_code != 0:
		var error_msg: String = output[0] if output.size() > 0 else "Unknown error"
		result.error = "Failed to create worktree: %s" % error_msg.strip_edges()
		_show_error(result.error)
		return result

	result.success = true
	result.path = worktree_path
	_hide_error()

	# Refresh the list
	_load_worktrees()

	return result


func _branch_exists(branch_name: String) -> bool:
	var output: Array = []
	var exit_code := OS.execute("git", [
		"-C", _repository_path,
		"show-ref", "--verify", "--quiet",
		"refs/heads/" + branch_name
	], output, true)
	return exit_code == 0


# =============================================================================
# Styling
# =============================================================================

func _style_text_input(input: LineEdit) -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.1, 0.1, 0.12)
	style.border_color = Color(0.3, 0.3, 0.35)
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
	style.bg_color = THEME_ACCENT_COLOR
	style.border_color = Color(0.5, 0.7, 1.0)
	style.set_border_width_all(1)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(8)
	button.add_theme_stylebox_override("normal", style)
	button.add_theme_font_size_override("font_size", 12)
	button.add_theme_color_override("font_color", THEME_TEXT_PRIMARY)

	var hover_style := style.duplicate()
	hover_style.bg_color = Color(0.5, 0.7, 1.0)
	button.add_theme_stylebox_override("hover", hover_style)

	var pressed_style := style.duplicate()
	pressed_style.bg_color = Color(0.6, 0.8, 1.0)
	button.add_theme_stylebox_override("pressed", pressed_style)

	var disabled_style := style.duplicate()
	disabled_style.bg_color = Color(0.25, 0.3, 0.4, 0.5)
	disabled_style.border_color = Color(0.3, 0.35, 0.4)
	button.add_theme_stylebox_override("disabled", disabled_style)
	button.add_theme_color_override("font_disabled_color", THEME_TEXT_SECONDARY)


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


# =============================================================================
# UI Helpers
# =============================================================================

func _update_status() -> void:
	var count := _worktrees.size()
	_status_label.text = "%d worktree%s" % [count, "" if count == 1 else "s"]

	if not _is_git_repo:
		_repo_label.text = "Not a git repository"
		_repo_label.add_theme_color_override("font_color", THEME_WARNING_COLOR)
	else:
		_repo_label.text = _repository_path
		_repo_label.add_theme_color_override("font_color", THEME_TEXT_SECONDARY)


func _show_error(message: String) -> void:
	_error_label.text = message
	_error_label.visible = true
	error_occurred.emit(message)


func _hide_error() -> void:
	_error_label.text = ""
	_error_label.visible = false


func _update_selection_button() -> void:
	_use_button.disabled = (_selected_worktree == null)


# =============================================================================
# Event Handlers
# =============================================================================

func _on_tree_item_input(event: InputEvent, item: Control, worktree: WorktreeInfo) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_select_worktree(worktree)
		# Double-click to use immediately
		if event.double_click:
			_on_use_button_pressed()


func _on_tree_item_hover(item: Control, is_hovered: bool) -> void:
	var worktree: WorktreeInfo = item.get_meta("worktree")
	var is_selected := _selected_worktree and _selected_worktree.path == worktree.path

	var style: StyleBoxFlat = item.get_theme_stylebox("panel").duplicate()
	if is_selected:
		style.bg_color = THEME_ITEM_SELECTED
		style.border_color = THEME_ACCENT_COLOR
		style.set_border_width_all(2)
	elif is_hovered:
		style.bg_color = THEME_ITEM_HOVER
		style.border_color = Color(0.35, 0.35, 0.4)
		style.set_border_width_all(1)
	else:
		style.bg_color = THEME_ITEM_COLOR
		style.border_color = Color(0.28, 0.28, 0.32)
		style.set_border_width_all(1)

	item.add_theme_stylebox_override("panel", style)


func _select_worktree(worktree: WorktreeInfo) -> void:
	_selected_worktree = worktree
	_rebuild_tree_view()
	_update_selection_button()


func _on_branch_input_submitted(text: String) -> void:
	_on_create_button_pressed()


func _on_create_button_pressed() -> void:
	var branch_name := _branch_input.text.strip_edges()
	if branch_name == "":
		_show_error("Please enter a branch name")
		return

	var result := create_worktree(branch_name)
	if result.success:
		_branch_input.text = ""
		create_worktree_requested.emit(branch_name, result.path)


func _on_refresh_button_pressed() -> void:
	refresh()


func _on_use_button_pressed() -> void:
	if _selected_worktree:
		worktree_selected.emit(_selected_worktree.path, _selected_worktree.branch)


# =============================================================================
# Public API
# =============================================================================

## Set the repository path to manage
func set_repository_path(path: String) -> void:
	_repository_path = path
	_check_git_repository()
	_load_worktrees()


## Refresh the worktree list
func refresh() -> void:
	_check_git_repository()
	_load_worktrees()
	_hide_error()


## Get the selected worktree path
func get_selected_worktree() -> String:
	if _selected_worktree:
		return _selected_worktree.path
	return ""


## Get all worktrees
func get_worktrees() -> Array[WorktreeInfo]:
	return _worktrees.duplicate()
