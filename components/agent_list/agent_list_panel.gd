class_name AgentListPanel
extends WorkspacePanel


## AgentListPanel - A floating panel for managing active agent sessions
##
## Displays all active agents, their status, and provides controls to
## kill individual agents or all agents at once.


# =============================================================================
# Signals
# =============================================================================

## Emitted when an agent is killed from this panel
signal agent_killed(agent_id: String)

## Emitted when all agents are killed
signal all_agents_killed(count: int)

## Emitted when an agent is restarted
signal agent_restarted(agent_id: String)

## Emitted when an agent's terminal is focused
signal agent_focused(agent_id: String)


# =============================================================================
# State
# =============================================================================

var _list_content: Control = null  # AgentListContent instance
var _agent_orchestrator: Node = null
var _panel_registry: Node = null


# =============================================================================
# Lifecycle
# =============================================================================

func _init() -> void:
	# Configure as a compact panel for agent management
	panel_size = Vector2(0.6, 0.7)  # Slightly larger for working directory display
	title = "Agent Overview"
	viewport_size = Vector2(480, 560)  # Increased for better readability
	resizable = false
	billboard_mode = true


func _ready() -> void:
	# Set content scene before parent _ready
	content_scene = load("res://components/agent_list/agent_list_content.tscn")

	super._ready()

	# Connect to content after setup
	_connect_list_content()
	_connect_agent_orchestrator()
	_connect_panel_registry()


func _connect_list_content() -> void:
	if not is_inside_tree():
		return

	await get_tree().process_frame

	var content_instance := get_content_scene_instance()
	if content_instance and content_instance.has_signal("kill_agent_requested"):
		_list_content = content_instance
		_list_content.kill_agent_requested.connect(_on_kill_agent_requested)
		_list_content.kill_all_requested.connect(_on_kill_all_requested)
		_list_content.close_requested.connect(_on_close_requested)
		_list_content.focus_agent_requested.connect(_on_focus_agent_requested)
		_list_content.restart_agent_requested.connect(_on_restart_agent_requested)


func _connect_agent_orchestrator() -> void:
	_agent_orchestrator = get_node_or_null("/root/AgentOrchestrator")
	if not _agent_orchestrator:
		push_warning("AgentListPanel: AgentOrchestrator autoload not found")
		return

	# Connect to spawn rejected signal
	_agent_orchestrator.spawn_rejected.connect(_on_spawn_rejected)


func _connect_panel_registry() -> void:
	_panel_registry = get_node_or_null("/root/PanelRegistry")
	if not _panel_registry:
		push_warning("AgentListPanel: PanelRegistry autoload not found")


# =============================================================================
# Event Handlers
# =============================================================================

func _on_kill_agent_requested(agent_id: String) -> void:
	if not _agent_orchestrator:
		return

	var err: Error = _agent_orchestrator.kill_agent(agent_id)
	if err == OK:
		print("AgentListPanel: Killed agent: %s" % agent_id)
		agent_killed.emit(agent_id)
	else:
		push_warning("AgentListPanel: Failed to kill agent: %s (error: %s)" % [agent_id, error_string(err)])


func _on_kill_all_requested() -> void:
	if not _agent_orchestrator:
		return

	var killed: int = _agent_orchestrator.kill_all_agents()
	if killed > 0:
		print("AgentListPanel: Killed %d agents" % killed)
		all_agents_killed.emit(killed)
	else:
		print("AgentListPanel: No agents to kill")


func _on_close_requested() -> void:
	close()


func _on_focus_agent_requested(agent_id: String) -> void:
	if not _panel_registry:
		return

	var success: bool = _panel_registry.focus_agent_panel(agent_id)
	if success:
		print("AgentListPanel: Focused terminal for agent: %s" % agent_id)
		agent_focused.emit(agent_id)
	else:
		push_warning("AgentListPanel: No terminal panel found for agent: %s" % agent_id)


func _on_restart_agent_requested(agent_id: String) -> void:
	if not _agent_orchestrator:
		return

	var err: Error = _agent_orchestrator.restart_agent(agent_id)
	if err == OK:
		print("AgentListPanel: Restarting agent: %s" % agent_id)
		agent_restarted.emit(agent_id)
	else:
		push_warning("AgentListPanel: Failed to restart agent: %s (error: %s)" % [agent_id, error_string(err)])


func _on_spawn_rejected(reason: String, _current: int, _max: int) -> void:
	# Show warning in the panel
	if _list_content and _list_content.has_method("show_warning"):
		_list_content.show_warning(reason)


# =============================================================================
# Public API
# =============================================================================

## Refresh the agent list
func refresh() -> void:
	if _list_content:
		_list_content.refresh()


## Get the number of active agents
func get_agent_count() -> int:
	if _agent_orchestrator:
		return _agent_orchestrator.get_agent_count()
	return 0


## Get the number of running agents
func get_running_count() -> int:
	if _agent_orchestrator:
		return _agent_orchestrator.get_running_count()
	return 0
