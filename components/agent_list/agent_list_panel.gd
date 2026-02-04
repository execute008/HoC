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


# =============================================================================
# State
# =============================================================================

var _list_content: Control = null  # AgentListContent instance
var _agent_orchestrator: Node = null


# =============================================================================
# Lifecycle
# =============================================================================

func _init() -> void:
	# Configure as a compact panel for agent management
	panel_size = Vector2(0.5, 0.6)
	title = "Agents"
	viewport_size = Vector2(400, 480)
	resizable = false
	billboard_mode = true


func _ready() -> void:
	# Set content scene before parent _ready
	content_scene = load("res://components/agent_list/agent_list_content.tscn")

	super._ready()

	# Connect to content after setup
	_connect_list_content()
	_connect_agent_orchestrator()


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


func _connect_agent_orchestrator() -> void:
	_agent_orchestrator = get_node_or_null("/root/AgentOrchestrator")
	if not _agent_orchestrator:
		push_warning("AgentListPanel: AgentOrchestrator autoload not found")
		return

	# Connect to spawn rejected signal
	_agent_orchestrator.spawn_rejected.connect(_on_spawn_rejected)


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
