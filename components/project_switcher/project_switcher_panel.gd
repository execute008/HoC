class_name ProjectSwitcherPanel
extends WorkspacePanel


## ProjectSwitcherPanel - A floating panel for switching between projects
##
## Displays recent projects and allows switching between them with options
## to kill running agents and load project-specific layouts.


# =============================================================================
# Signals
# =============================================================================

## Emitted when project is successfully switched
signal project_switched(project_path: String)

## Emitted when switching begins (before cleanup)
signal project_switching(project_path: String)

## Emitted when a project is added to the list
signal project_added(project_path: String)

## Emitted when a project is removed from the list
signal project_removed(project_path: String)


# =============================================================================
# State
# =============================================================================

var _switcher_content: Control = null  # ProjectSwitcherContent instance
var _project_config: Node = null
var _agent_orchestrator: Node = null
var _layout_manager: Node = null
var _panel_registry: Node = null

## Currently active project path
var _current_project: String = ""

## File dialog for adding projects
var _file_dialog: FileDialog = null


# =============================================================================
# Lifecycle
# =============================================================================

func _init() -> void:
	# Configure as a panel for project management
	panel_size = Vector2(0.65, 0.75)
	title = "Project Switcher"
	viewport_size = Vector2(520, 600)
	resizable = false
	billboard_mode = true


func _ready() -> void:
	# Set content scene before parent _ready
	content_scene = load("res://components/project_switcher/project_switcher_content.tscn")

	super._ready()

	# Connect to content after setup
	_connect_content()
	_connect_autoloads()


func _connect_content() -> void:
	if not is_inside_tree():
		return

	await get_tree().process_frame

	var content_instance := get_content_scene_instance()
	if content_instance and content_instance.has_signal("project_selected"):
		_switcher_content = content_instance
		_switcher_content.project_selected.connect(_on_project_selected)
		_switcher_content.add_project_requested.connect(_on_add_project_requested)
		_switcher_content.project_removed.connect(_on_project_removed)
		_switcher_content.close_requested.connect(_on_close_requested)

		# Set initial current project
		if _current_project != "":
			_switcher_content.set_current_project(_current_project)


func _connect_autoloads() -> void:
	_project_config = get_node_or_null("/root/ProjectConfig")
	if not _project_config:
		push_warning("ProjectSwitcherPanel: ProjectConfig autoload not found")

	_agent_orchestrator = get_node_or_null("/root/AgentOrchestrator")
	if not _agent_orchestrator:
		push_warning("ProjectSwitcherPanel: AgentOrchestrator autoload not found")

	_layout_manager = get_node_or_null("/root/LayoutManager")
	if not _layout_manager:
		push_warning("ProjectSwitcherPanel: LayoutManager autoload not found")

	_panel_registry = get_node_or_null("/root/PanelRegistry")
	if not _panel_registry:
		push_warning("ProjectSwitcherPanel: PanelRegistry autoload not found")


# =============================================================================
# Event Handlers
# =============================================================================

func _on_project_selected(project_path: String) -> void:
	await switch_to_project(project_path)


func _on_add_project_requested() -> void:
	_open_file_dialog()


func _on_project_removed(project_path: String) -> void:
	if _project_config:
		_project_config.remove_recent_project(project_path)
		print("ProjectSwitcherPanel: Removed project from list: %s" % project_path)
		project_removed.emit(project_path)


func _on_close_requested() -> void:
	close()


func _on_file_dialog_dir_selected(dir_path: String) -> void:
	if _project_config:
		_project_config.add_recent_project(dir_path)
		print("ProjectSwitcherPanel: Added project: %s" % dir_path)
		project_added.emit(dir_path)

		if _switcher_content:
			_switcher_content.refresh()


func _on_file_dialog_canceled() -> void:
	# Clean up the dialog
	if _file_dialog:
		_file_dialog.queue_free()
		_file_dialog = null


# =============================================================================
# Public API
# =============================================================================

## Switch to a different project
## This will optionally kill running agents, save current layout,
## and load the project-specific layout
func switch_to_project(project_path: String) -> Error:
	if project_path == _current_project:
		print("ProjectSwitcherPanel: Already on project: %s" % project_path)
		return OK

	print("ProjectSwitcherPanel: Switching to project: %s" % project_path)
	project_switching.emit(project_path)

	# Get kill agents preference - first from UI, then from project settings
	var kill_agents := true
	if _switcher_content:
		kill_agents = _switcher_content.get_kill_agents_on_switch()
	elif _project_config and _current_project != "":
		kill_agents = _project_config.get_project_kill_agents(_current_project)

	# Kill running agents if requested
	if kill_agents and _agent_orchestrator:
		var killed: int = _agent_orchestrator.kill_all_agents()
		if killed > 0:
			print("ProjectSwitcherPanel: Killed %d agents" % killed)
			# Wait a moment for agents to exit
			await get_tree().create_timer(0.5).timeout
			# Clean up exited agents
			_agent_orchestrator.cleanup_exited()

	# Save current layout as project-specific layout before switching
	if _layout_manager and _current_project != "":
		var old_project_name := _current_project.get_file()
		var old_layout_name := "project_" + old_project_name
		_layout_manager.save_layout(old_layout_name)
		print("ProjectSwitcherPanel: Saved layout for previous project: %s" % old_layout_name)

		# Update project settings with the layout
		if _project_config:
			_project_config.set_project_layout(_current_project, old_layout_name)

	# Update current project
	var old_project := _current_project
	_current_project = project_path

	# Update the project in recent list (bumps to top)
	if _project_config:
		_project_config.add_recent_project(project_path)

	# Load project-specific layout if it exists
	await _load_project_layout(project_path)

	# Update UI
	if _switcher_content:
		_switcher_content.set_current_project(project_path)

	print("ProjectSwitcherPanel: Switched from '%s' to '%s'" % [old_project, project_path])
	project_switched.emit(project_path)

	return OK


## Load the layout associated with a project
func _load_project_layout(project_path: String) -> void:
	if not _layout_manager:
		return

	# First check if project has a preferred layout stored in settings
	var preferred_layout := ""
	if _project_config:
		preferred_layout = _project_config.get_project_layout(project_path)

	# If a preferred layout is set and exists, use it
	if preferred_layout != "" and _layout_manager.has_layout(preferred_layout):
		print("ProjectSwitcherPanel: Loading preferred layout: %s" % preferred_layout)
		await _layout_manager.load_layout(preferred_layout, true)
		return

	# Try to load a project-specific layout by convention
	# Layout name is derived from project folder name
	var project_name := project_path.get_file()
	var layout_name := "project_" + project_name

	if _layout_manager.has_layout(layout_name):
		print("ProjectSwitcherPanel: Loading project layout: %s" % layout_name)
		await _layout_manager.load_layout(layout_name, true)
	else:
		# No project-specific layout, load default
		print("ProjectSwitcherPanel: No project layout found, loading default")
		if _layout_manager.has_layout("default"):
			await _layout_manager.load_layout("default", true)


## Save current layout as project-specific layout
func save_project_layout() -> Error:
	if not _layout_manager or _current_project == "":
		return ERR_UNAVAILABLE

	var project_name := _current_project.get_file()
	var layout_name := "project_" + project_name

	return _layout_manager.save_layout(layout_name)


## Get the current active project path
func get_current_project() -> String:
	return _current_project


## Set the current project (without triggering a switch)
func set_current_project(project_path: String) -> void:
	_current_project = project_path
	if _switcher_content:
		_switcher_content.set_current_project(project_path)


## Force refresh the project list
func refresh() -> void:
	if _switcher_content:
		_switcher_content.refresh()


# =============================================================================
# File Dialog
# =============================================================================

func _open_file_dialog() -> void:
	# Create file dialog for selecting a directory
	_file_dialog = FileDialog.new()
	_file_dialog.name = "ProjectFileDialog"
	_file_dialog.title = "Select Project Directory"
	_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_file_dialog.use_native_dialog = true

	# Set initial directory to home
	var home_dir := OS.get_environment("HOME")
	if home_dir != "":
		_file_dialog.current_dir = home_dir

	_file_dialog.dir_selected.connect(_on_file_dialog_dir_selected)
	_file_dialog.canceled.connect(_on_file_dialog_canceled)

	# Add to scene and show
	add_child(_file_dialog)
	_file_dialog.popup_centered(Vector2i(800, 600))
