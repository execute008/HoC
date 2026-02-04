class_name ProjectSpawnMenu
extends WorkspacePanel


## ProjectSpawnMenu - A floating menu panel for spawning new agent sessions
##
## Displays recent projects, directory picker, and preset selector.
## Spawns a terminal panel and binds it to the newly created agent.


# =============================================================================
# Signals
# =============================================================================

## Emitted when an agent is spawned from this menu
signal agent_spawned(agent_id: String, terminal: TerminalPanel)

## Emitted when spawn fails
signal spawn_failed(error_message: String)


# =============================================================================
# Configuration
# =============================================================================

## Whether to close the menu after spawning an agent
@export var close_after_spawn: bool = false


# =============================================================================
# State
# =============================================================================

var _spawn_content: Control = null  # ProjectSpawnContent instance
var _agent_orchestrator: Node = null
var _project_config: Node = null

# Pending spawn tracking
var _pending_spawn_path: String = ""
var _pending_spawn_preset: String = ""
var _pending_terminal: TerminalPanel = null


# =============================================================================
# Lifecycle
# =============================================================================

func _init() -> void:
	# Configure as a larger menu panel for project selection
	panel_size = Vector2(0.6, 0.7)
	title = "Spawn Agent"
	viewport_size = Vector2(480, 560)
	resizable = false
	billboard_mode = true


func _ready() -> void:
	# Set content scene before parent _ready
	content_scene = load("res://components/spawn_menu/project_spawn_content.tscn")

	super._ready()

	# Connect to spawn content after setup
	_connect_spawn_content()
	_connect_agent_orchestrator()
	_connect_project_config()


func _connect_spawn_content() -> void:
	if not is_inside_tree():
		return

	await get_tree().process_frame

	var content_instance := get_content_scene_instance()
	if content_instance and content_instance.has_signal("spawn_requested"):
		_spawn_content = content_instance
		_spawn_content.spawn_requested.connect(_on_spawn_requested)
		_spawn_content.close_requested.connect(_on_close_requested)
		_spawn_content.error_occurred.connect(_on_content_error)


func _connect_agent_orchestrator() -> void:
	_agent_orchestrator = get_node_or_null("/root/AgentOrchestrator")
	if not _agent_orchestrator:
		push_warning("ProjectSpawnMenu: AgentOrchestrator autoload not found")
		return

	_agent_orchestrator.agent_created.connect(_on_agent_created)
	_agent_orchestrator.agent_exit.connect(_on_agent_exit)


func _connect_project_config() -> void:
	_project_config = get_node_or_null("/root/ProjectConfig")
	if not _project_config:
		push_warning("ProjectSpawnMenu: ProjectConfig autoload not found")


# =============================================================================
# Spawn Flow
# =============================================================================

func _on_spawn_requested(project_path: String, preset_name: String) -> void:
	if not _agent_orchestrator:
		_show_error("Agent orchestrator not available")
		return

	# Get preset configuration
	var cols := 80
	var rows := 24

	if _project_config and _project_config.has_preset(preset_name):
		var preset = _project_config.get_preset(preset_name)
		cols = preset.cols
		rows = preset.rows

	# Store pending spawn info
	_pending_spawn_path = project_path
	_pending_spawn_preset = preset_name

	# Create terminal panel first (will be positioned near spawn menu)
	_pending_terminal = _create_terminal_panel()
	if not _pending_terminal:
		_show_error("Failed to create terminal panel")
		return

	# Show spawning message in terminal
	_pending_terminal.writeln("\u001b[33mSpawning agent for: %s\u001b[0m" % project_path)
	_pending_terminal.writeln("\u001b[90mPreset: %s (%dx%d)\u001b[0m\n" % [preset_name, cols, rows])

	# Request agent spawn
	var error: Error = _agent_orchestrator.spawn_agent(project_path, preset_name, cols, rows)
	if error != OK:
		_show_error("Failed to spawn agent: " + error_string(error))
		_pending_terminal.writeln("\u001b[31mError: Failed to spawn agent\u001b[0m")
		_cleanup_pending_spawn()
		return

	# Add to recent projects
	if _project_config:
		_project_config.add_recent_project(project_path, preset_name)


func _create_terminal_panel() -> TerminalPanel:
	if not _xr_camera:
		_find_xr_camera()

	if not _xr_camera:
		push_error("ProjectSpawnMenu: Cannot create terminal without XR camera")
		return null

	# Calculate spawn position offset from this menu
	var spawn_transform := PanelRegistry.calculate_spawn_position(_xr_camera)

	# Offset slightly to the right of spawn menu
	spawn_transform.origin += global_transform.basis.x * 0.3

	# Get the main scene as parent
	var parent := get_tree().current_scene

	# Spawn terminal panel
	var terminal: TerminalPanel = PanelRegistry.spawn_panel("terminal", spawn_transform, parent)
	if terminal:
		terminal.title = "Terminal (spawning...)"

	return terminal


func _on_agent_created(agent_id: String, session) -> void:
	# Check if this is our pending spawn
	if _pending_spawn_path == "" or not _pending_terminal:
		return

	if session.project_path != _pending_spawn_path:
		return

	# Bind terminal to agent
	var success := _pending_terminal.bind_agent(agent_id)
	if not success:
		push_error("ProjectSpawnMenu: Failed to bind terminal to agent: %s" % agent_id)
		_pending_terminal.writeln("\u001b[31mError: Failed to bind to agent\u001b[0m")
	else:
		# Update terminal title
		var project_name := _pending_spawn_path.get_file()
		_pending_terminal.title = "Terminal [%s]" % project_name

	# Emit success signal
	agent_spawned.emit(agent_id, _pending_terminal)

	# Clear pending state
	_cleanup_pending_spawn()

	# Optionally close the spawn menu
	if close_after_spawn:
		close()


func _on_agent_exit(agent_id: String, exit_code: int, _reason: String) -> void:
	# If agent exits during spawn, show error
	if _pending_terminal and _pending_terminal.get_bound_agent_id() == agent_id:
		_pending_terminal.writeln("\n\u001b[31mAgent exited with code: %d\u001b[0m" % exit_code)


func _cleanup_pending_spawn() -> void:
	_pending_spawn_path = ""
	_pending_spawn_preset = ""
	_pending_terminal = null


# =============================================================================
# Error Handling
# =============================================================================

func _show_error(message: String) -> void:
	push_error("ProjectSpawnMenu: %s" % message)
	spawn_failed.emit(message)

	# Show error in spawn content if available
	if _spawn_content and _spawn_content.has_method("_show_error"):
		_spawn_content._show_error(message)


func _on_content_error(message: String) -> void:
	spawn_failed.emit(message)


func _on_close_requested() -> void:
	close()


# =============================================================================
# Public API
# =============================================================================

## Set the XR camera reference
func set_xr_camera(camera: XRCamera3D) -> void:
	_xr_camera = camera


## Refresh the menu content
func refresh() -> void:
	if _spawn_content and _spawn_content.has_method("refresh"):
		_spawn_content.refresh()


## Set the project path programmatically
func set_project_path(path: String) -> void:
	if _spawn_content and _spawn_content.has_method("set_project_path"):
		_spawn_content.set_project_path(path)


## Set the preset programmatically
func set_preset(preset_name: String) -> void:
	if _spawn_content and _spawn_content.has_method("set_preset"):
		_spawn_content.set_preset(preset_name)
