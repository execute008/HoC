extends Node


## AgentOrchestrator - Central agent state management
##
## Manages agent sessions by ID, routes output to registered callbacks,
## and emits signals for agent lifecycle events. Acts as the single source
## of truth for agent state in the Godot application.


# =============================================================================
# Signals - Agent Lifecycle
# =============================================================================

## Emitted when a new agent session is created
signal agent_created(agent_id: String, session: AgentSession)

## Emitted when an agent session is removed
signal agent_removed(agent_id: String)

## Emitted when an agent's state changes
signal agent_state_changed(agent_id: String, old_state: AgentState, new_state: AgentState)

## Emitted when agent output is received
signal agent_output_received(agent_id: String, data: String)

## Emitted when an agent exits
signal agent_exit(agent_id: String, exit_code: int, reason: String)

## Emitted when agent count changes
signal agent_count_changed(count: int)


# =============================================================================
# Types
# =============================================================================

## Agent states
enum AgentState {
	SPAWNING,    ## Spawn request sent, waiting for confirmation
	RUNNING,     ## Agent is running
	EXITING,     ## Exit requested, waiting for confirmation
	EXITED       ## Agent has exited
}


## Agent session data class
class AgentSession:
	var agent_id: String
	var project_path: String
	var preset: String
	var cols: int
	var rows: int
	var state: AgentState
	var exit_code: int
	var exit_reason: String
	var created_at: int  # Unix timestamp
	var callbacks: Array[Callable]  # Output callbacks

	func _init(id: String, path: String, p_preset: String = "") -> void:
		agent_id = id
		project_path = path
		preset = p_preset
		cols = 80
		rows = 24
		state = AgentState.SPAWNING
		exit_code = -1
		exit_reason = ""
		created_at = Time.get_unix_time_from_system()
		callbacks = []

	func add_callback(callback: Callable) -> void:
		if callback.is_valid() and callback not in callbacks:
			callbacks.append(callback)

	func remove_callback(callback: Callable) -> void:
		var idx := callbacks.find(callback)
		if idx >= 0:
			callbacks.remove_at(idx)

	func invoke_callbacks(data: String) -> void:
		for callback in callbacks:
			if callback.is_valid():
				callback.call(data)


# =============================================================================
# Constants
# =============================================================================

## Maximum number of concurrent agents allowed
const MAX_CONCURRENT_AGENTS := 10

## Default maximum agents per project
const DEFAULT_MAX_PER_PROJECT := 3


# =============================================================================
# Signals - Resource Limits
# =============================================================================

## Emitted when spawn is rejected due to resource limits
signal spawn_rejected(reason: String, current_count: int, max_count: int)


# =============================================================================
# State
# =============================================================================

## Active agent sessions by ID
var _sessions: Dictionary = {}  # Dictionary[String, AgentSession]

## Pending spawn requests (project_path -> temp session data)
## Used to match spawn responses to requests
var _pending_spawns: Array[Dictionary] = []

## Reference to BridgeClient autoload
var _bridge_client: Node = null

## Resource limits configuration
var _max_concurrent_agents: int = MAX_CONCURRENT_AGENTS
var _max_agents_per_project: int = DEFAULT_MAX_PER_PROJECT


# =============================================================================
# Lifecycle
# =============================================================================

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS

	# Connect to BridgeClient signals
	_connect_bridge_signals()


func _connect_bridge_signals() -> void:
	# BridgeClient is an autoload, get reference at runtime
	_bridge_client = get_node_or_null("/root/BridgeClient")
	if not _bridge_client:
		push_error("AgentOrchestrator: BridgeClient autoload not found")
		return

	_bridge_client.agent_spawned.connect(_on_agent_spawned)
	_bridge_client.agent_output.connect(_on_agent_output)
	_bridge_client.agent_exited.connect(_on_agent_exited)
	_bridge_client.agent_resized.connect(_on_agent_resized)
	_bridge_client.agent_list_received.connect(_on_agent_list_received)
	_bridge_client.agent_status_received.connect(_on_agent_status_received)


# =============================================================================
# Public API - Agent Management
# =============================================================================

## Spawn a new agent
## Returns OK if spawn request was sent, or an error code
func spawn_agent(project_path: String, preset: String = "", cols: int = 0, rows: int = 0) -> Error:
	if not _bridge_client.is_connected_to_bridge():
		push_error("AgentOrchestrator: Cannot spawn agent - not connected to bridge")
		return ERR_CONNECTION_ERROR

	# Check resource limits
	var limit_error := _check_spawn_limits(project_path)
	if limit_error != OK:
		return limit_error

	# Store pending spawn info to match with response
	_pending_spawns.append({
		"project_path": project_path,
		"preset": preset,
		"cols": cols if cols > 0 else 80,
		"rows": rows if rows > 0 else 24
	})

	return _bridge_client.spawn_agent(project_path, preset, cols, rows)


## Check if spawning a new agent would exceed resource limits
func _check_spawn_limits(project_path: String) -> Error:
	# Check total agent limit
	var active_count := get_active_count()
	if active_count >= _max_concurrent_agents:
		var msg := "Maximum concurrent agents reached (%d/%d)" % [active_count, _max_concurrent_agents]
		push_warning("AgentOrchestrator: %s" % msg)
		spawn_rejected.emit(msg, active_count, _max_concurrent_agents)
		return ERR_CANT_CREATE

	# Check per-project limit
	var project_count := get_project_agent_count(project_path)
	if project_count >= _max_agents_per_project:
		var msg := "Maximum agents for project reached (%d/%d): %s" % [project_count, _max_agents_per_project, project_path]
		push_warning("AgentOrchestrator: %s" % msg)
		spawn_rejected.emit(msg, project_count, _max_agents_per_project)
		return ERR_CANT_CREATE

	return OK


## Get count of active (non-exited) agents
func get_active_count() -> int:
	var count := 0
	for session: AgentSession in _sessions.values():
		if session.state != AgentState.EXITED:
			count += 1
	return count


## Get count of agents for a specific project path
func get_project_agent_count(project_path: String) -> int:
	var count := 0
	for session: AgentSession in _sessions.values():
		if session.project_path == project_path and session.state != AgentState.EXITED:
			count += 1
	return count


## Get all sessions for a specific project
func get_project_sessions(project_path: String) -> Array[AgentSession]:
	var result: Array[AgentSession] = []
	for session: AgentSession in _sessions.values():
		if session.project_path == project_path:
			result.append(session)
	return result


## Kill an agent by ID
## signal_num: Unix signal to send (0 = default SIGTERM)
func kill_agent(agent_id: String, signal_num: int = 0) -> Error:
	if not has_agent(agent_id):
		push_error("AgentOrchestrator: Unknown agent ID: %s" % agent_id)
		return ERR_DOES_NOT_EXIST

	var session := get_session(agent_id)
	if session.state == AgentState.EXITED:
		push_warning("AgentOrchestrator: Agent already exited: %s" % agent_id)
		return ERR_ALREADY_EXISTS

	# Update state
	var old_state := session.state
	session.state = AgentState.EXITING
	agent_state_changed.emit(agent_id, old_state, session.state)

	return _bridge_client.kill_agent(agent_id, signal_num)


## Send input to an agent
func send_input(agent_id: String, input: String) -> Error:
	if not has_agent(agent_id):
		push_error("AgentOrchestrator: Unknown agent ID: %s" % agent_id)
		return ERR_DOES_NOT_EXIST

	var session := get_session(agent_id)
	if session.state != AgentState.RUNNING:
		push_warning("AgentOrchestrator: Agent not running: %s (state: %d)" % [agent_id, session.state])
		return ERR_UNAVAILABLE

	return _bridge_client.send_agent_input(agent_id, input)


## Resize an agent's terminal
func resize_agent(agent_id: String, cols: int, rows: int) -> Error:
	if not has_agent(agent_id):
		push_error("AgentOrchestrator: Unknown agent ID: %s" % agent_id)
		return ERR_DOES_NOT_EXIST

	return _bridge_client.resize_terminal(agent_id, cols, rows)


## Request refresh of all agents from bridge
func refresh_agents() -> Error:
	return _bridge_client.list_agents()


## Request status of a specific agent
func refresh_agent_status(agent_id: String) -> Error:
	return _bridge_client.get_agent_status(agent_id)


# =============================================================================
# Public API - Session Queries
# =============================================================================

## Check if an agent exists
func has_agent(agent_id: String) -> bool:
	return agent_id in _sessions


## Get a session by ID
func get_session(agent_id: String) -> AgentSession:
	return _sessions.get(agent_id)


## Get all active sessions
func get_all_sessions() -> Array[AgentSession]:
	var result: Array[AgentSession] = []
	for session in _sessions.values():
		result.append(session)
	return result


## Get sessions by state
func get_sessions_by_state(state: AgentState) -> Array[AgentSession]:
	var result: Array[AgentSession] = []
	for session: AgentSession in _sessions.values():
		if session.state == state:
			result.append(session)
	return result


## Get count of active agents
func get_agent_count() -> int:
	return _sessions.size()


## Get count of running agents
func get_running_count() -> int:
	var count := 0
	for session: AgentSession in _sessions.values():
		if session.state == AgentState.RUNNING:
			count += 1
	return count


# =============================================================================
# Public API - Callbacks
# =============================================================================

## Register an output callback for an agent
## The callback will be invoked with (data: String) for each output
func register_output_callback(agent_id: String, callback: Callable) -> bool:
	if not has_agent(agent_id):
		push_warning("AgentOrchestrator: Cannot register callback - unknown agent: %s" % agent_id)
		return false

	var session := get_session(agent_id)
	session.add_callback(callback)
	return true


## Unregister an output callback for an agent
func unregister_output_callback(agent_id: String, callback: Callable) -> bool:
	if not has_agent(agent_id):
		return false

	var session := get_session(agent_id)
	session.remove_callback(callback)
	return true


# =============================================================================
# Internal - Bridge Signal Handlers
# =============================================================================

func _on_agent_spawned(agent_id: String, project_path: String, cols: int, rows: int) -> void:
	# Find matching pending spawn
	var preset := ""
	for i in range(_pending_spawns.size() - 1, -1, -1):
		var pending: Dictionary = _pending_spawns[i]
		if pending["project_path"] == project_path:
			preset = pending.get("preset", "")
			_pending_spawns.remove_at(i)
			break

	# Create session
	var session := AgentSession.new(agent_id, project_path, preset)
	session.cols = cols
	session.rows = rows
	session.state = AgentState.RUNNING

	_sessions[agent_id] = session

	print("AgentOrchestrator: Agent spawned: %s (project: %s)" % [agent_id, project_path])
	agent_created.emit(agent_id, session)
	agent_state_changed.emit(agent_id, AgentState.SPAWNING, AgentState.RUNNING)
	agent_count_changed.emit(_sessions.size())


func _on_agent_output(agent_id: String, data: String) -> void:
	if not has_agent(agent_id):
		# Agent might have been removed but output arrived late
		return

	var session := get_session(agent_id)

	# Emit signal for general listeners
	agent_output_received.emit(agent_id, data)

	# Invoke registered callbacks
	session.invoke_callbacks(data)


func _on_agent_exited(agent_id: String, exit_code: int, reason: String) -> void:
	if not has_agent(agent_id):
		push_warning("AgentOrchestrator: Exit received for unknown agent: %s" % agent_id)
		return

	var session := get_session(agent_id)
	var old_state := session.state

	session.state = AgentState.EXITED
	session.exit_code = exit_code
	session.exit_reason = reason

	print("AgentOrchestrator: Agent exited: %s (code: %d, reason: %s)" % [agent_id, exit_code, reason])
	agent_state_changed.emit(agent_id, old_state, AgentState.EXITED)
	agent_exit.emit(agent_id, exit_code, reason)


func _on_agent_resized(agent_id: String, cols: int, rows: int) -> void:
	if not has_agent(agent_id):
		return

	var session := get_session(agent_id)
	session.cols = cols
	session.rows = rows


func _on_agent_list_received(agents: Array) -> void:
	# Sync local state with bridge's authoritative list
	var bridge_ids := PackedStringArray()

	for agent_data: Dictionary in agents:
		var agent_id: String = agent_data.get("agent_id", "")
		if agent_id == "":
			continue

		bridge_ids.append(agent_id)

		if not has_agent(agent_id):
			# Agent exists on bridge but not locally - create session
			var session := AgentSession.new(
				agent_id,
				agent_data.get("project_path", ""),
				agent_data.get("preset", "")
			)
			session.cols = agent_data.get("cols", 80)
			session.rows = agent_data.get("rows", 24)
			session.state = AgentState.RUNNING

			_sessions[agent_id] = session
			agent_created.emit(agent_id, session)

	# Check for agents that exist locally but not on bridge (stale)
	var to_remove: Array[String] = []
	for agent_id: String in _sessions.keys():
		if agent_id not in bridge_ids:
			var session := get_session(agent_id)
			if session.state != AgentState.EXITED:
				# Mark as exited
				var old_state := session.state
				session.state = AgentState.EXITED
				session.exit_reason = "removed_from_bridge"
				agent_state_changed.emit(agent_id, old_state, AgentState.EXITED)
				agent_exit.emit(agent_id, -1, "removed_from_bridge")

	agent_count_changed.emit(_sessions.size())


func _on_agent_status_received(agent_id: String, status: String, project_path: String, cols: int, rows: int) -> void:
	if not has_agent(agent_id):
		# Create session if we don't have it
		var session := AgentSession.new(agent_id, project_path)
		session.cols = cols
		session.rows = rows
		session.state = AgentState.RUNNING if status == "running" else AgentState.EXITED

		_sessions[agent_id] = session
		agent_created.emit(agent_id, session)
		agent_count_changed.emit(_sessions.size())
	else:
		var session := get_session(agent_id)
		session.cols = cols
		session.rows = rows

		var new_state := AgentState.RUNNING if status == "running" else AgentState.EXITED
		if session.state != new_state:
			var old_state := session.state
			session.state = new_state
			agent_state_changed.emit(agent_id, old_state, new_state)


# =============================================================================
# Public API - Cleanup
# =============================================================================

## Remove an exited agent from tracking
func remove_agent(agent_id: String) -> bool:
	if not has_agent(agent_id):
		return false

	var session := get_session(agent_id)
	if session.state != AgentState.EXITED:
		push_warning("AgentOrchestrator: Cannot remove non-exited agent: %s" % agent_id)
		return false

	_sessions.erase(agent_id)
	agent_removed.emit(agent_id)
	agent_count_changed.emit(_sessions.size())
	return true


## Remove all exited agents
func cleanup_exited() -> int:
	var removed := 0
	var to_remove: Array[String] = []

	for agent_id: String in _sessions.keys():
		var session := get_session(agent_id)
		if session.state == AgentState.EXITED:
			to_remove.append(agent_id)

	for agent_id in to_remove:
		_sessions.erase(agent_id)
		agent_removed.emit(agent_id)
		removed += 1

	if removed > 0:
		agent_count_changed.emit(_sessions.size())

	return removed


# =============================================================================
# Public API - Resource Limits
# =============================================================================

## Set maximum concurrent agents
func set_max_concurrent_agents(count: int) -> void:
	_max_concurrent_agents = max(1, count)


## Get maximum concurrent agents
func get_max_concurrent_agents() -> int:
	return _max_concurrent_agents


## Set maximum agents per project
func set_max_agents_per_project(count: int) -> void:
	_max_agents_per_project = max(1, count)


## Get maximum agents per project
func get_max_agents_per_project() -> int:
	return _max_agents_per_project


## Check if spawning is allowed (within resource limits)
func can_spawn_agent(project_path: String = "") -> bool:
	if get_active_count() >= _max_concurrent_agents:
		return false
	if project_path != "" and get_project_agent_count(project_path) >= _max_agents_per_project:
		return false
	return true


## Get resource limit status
func get_resource_status() -> Dictionary:
	return {
		"active_agents": get_active_count(),
		"max_agents": _max_concurrent_agents,
		"running_agents": get_running_count(),
		"exited_agents": get_sessions_by_state(AgentState.EXITED).size(),
		"can_spawn": can_spawn_agent()
	}


# =============================================================================
# Public API - Kill All
# =============================================================================

## Kill all running agents
func kill_all_agents(signal_num: int = 0) -> int:
	var killed := 0
	for session: AgentSession in _sessions.values():
		if session.state == AgentState.RUNNING or session.state == AgentState.SPAWNING:
			var err := kill_agent(session.agent_id, signal_num)
			if err == OK:
				killed += 1
	return killed


## Restart an agent by killing it and spawning a new one with the same config.
## Returns the new agent ID on success, or empty string on failure.
## Note: The caller should wait for agent_created signal to get the new agent.
func restart_agent(agent_id: String) -> Error:
	if not has_agent(agent_id):
		push_error("AgentOrchestrator: Cannot restart - unknown agent ID: %s" % agent_id)
		return ERR_DOES_NOT_EXIST

	var session := get_session(agent_id)
	var project_path := session.project_path
	var preset := session.preset
	var cols := session.cols
	var rows := session.rows

	# Kill the current agent
	var err := kill_agent(agent_id)
	if err != OK and session.state != AgentState.EXITED:
		push_warning("AgentOrchestrator: Failed to kill agent for restart: %s" % agent_id)
		# Continue anyway - the agent may already be exited

	# Remove the old agent from tracking
	if session.state == AgentState.EXITED:
		remove_agent(agent_id)

	# Spawn a new agent with the same config
	return spawn_agent(project_path, preset, cols, rows)
