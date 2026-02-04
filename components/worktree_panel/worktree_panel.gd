class_name WorktreePanel
extends WorkspacePanel


## WorktreePanel - A floating panel for managing git worktrees
##
## Displays all worktrees for the current repository and provides controls to
## create new worktrees and select them as agent working directories.


# =============================================================================
# Signals
# =============================================================================

## Emitted when a worktree is selected for use
signal worktree_selected(path: String, branch: String)

## Emitted when a worktree is created
signal worktree_created(path: String, branch: String)

## Emitted when an error occurs
signal error_occurred(message: String)


# =============================================================================
# State
# =============================================================================

var _worktree_content: Control = null
var _project_config: Node = null


# =============================================================================
# Lifecycle
# =============================================================================

func _init() -> void:
	panel_size = Vector2(0.7, 0.8)
	title = "Git Worktrees"
	viewport_size = Vector2(560, 640)
	resizable = false
	billboard_mode = true


func _ready() -> void:
	content_scene = load("res://components/worktree_panel/worktree_content.tscn")

	super._ready()

	_connect_worktree_content()
	_connect_project_config()


func _connect_worktree_content() -> void:
	if not is_inside_tree():
		return

	await get_tree().process_frame

	var content_instance := get_content_scene_instance()
	if content_instance and content_instance.has_signal("worktree_selected"):
		_worktree_content = content_instance
		_worktree_content.worktree_selected.connect(_on_worktree_selected)
		_worktree_content.create_worktree_requested.connect(_on_create_worktree_requested)
		_worktree_content.close_requested.connect(_on_close_requested)
		_worktree_content.error_occurred.connect(_on_error_occurred)

		# Set initial repository path from most recent project if available
		if _project_config:
			var recent_projects = _project_config.get_recent_projects()
			if recent_projects.size() > 0:
				_worktree_content.set_repository_path(recent_projects[0].path)


func _connect_project_config() -> void:
	_project_config = get_node_or_null("/root/ProjectConfig")
	if not _project_config:
		push_warning("WorktreePanel: ProjectConfig autoload not found")


# =============================================================================
# Event Handlers
# =============================================================================

func _on_worktree_selected(path: String, branch: String) -> void:
	print("WorktreePanel: Selected worktree: %s (%s)" % [path, branch])
	worktree_selected.emit(path, branch)


func _on_create_worktree_requested(branch_name: String, base_path: String) -> void:
	if _worktree_content:
		var result: Dictionary = _worktree_content.create_worktree(branch_name, base_path)
		if result.get("success", false):
			print("WorktreePanel: Created worktree: %s" % result.get("path", ""))
			worktree_created.emit(result.get("path", ""), branch_name)


func _on_close_requested() -> void:
	close()


func _on_error_occurred(message: String) -> void:
	push_warning("WorktreePanel: %s" % message)
	error_occurred.emit(message)


# =============================================================================
# Public API
# =============================================================================

## Set the repository path to manage worktrees for
func set_repository_path(path: String) -> void:
	if _worktree_content:
		_worktree_content.set_repository_path(path)


## Refresh the worktree list
func refresh() -> void:
	if _worktree_content:
		_worktree_content.refresh()


## Get the currently selected worktree path
func get_selected_worktree() -> String:
	if _worktree_content:
		return _worktree_content.get_selected_worktree()
	return ""
