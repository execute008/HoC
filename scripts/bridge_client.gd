extends Node


## BridgeClient - WebSocket client for bridge communication
##
## Connects to the hoc-bridge WebSocket server and handles bidirectional
## JSON message exchange. Automatically reconnects on disconnect.


## Protocol version (must match server)
const PROTOCOL_VERSION := 1

## Default reconnect delay in seconds
const DEFAULT_RECONNECT_DELAY := 2.0

## Maximum reconnect delay in seconds (with exponential backoff)
const MAX_RECONNECT_DELAY := 30.0

## Ping interval in seconds
const PING_INTERVAL := 30.0

## Connection timeout in seconds
const CONNECTION_TIMEOUT := 10.0


# =============================================================================
# Signals - Connection State
# =============================================================================

## Emitted when successfully connected to the bridge
signal connected()

## Emitted when disconnected from the bridge
signal disconnected()

## Emitted when a connection error occurs
signal connection_error(error: String)

## Emitted when reconnecting (with attempt number)
signal reconnecting(attempt: int)


# =============================================================================
# Signals - Server Messages
# =============================================================================

## Emitted when welcome message is received
signal welcome_received(version: int, server_id: String)

## Emitted when pong response is received
signal pong_received(seq: int)

## Emitted when an agent is spawned
signal agent_spawned(agent_id: String, project_path: String, cols: int, rows: int)

## Emitted when agent output is received
signal agent_output(agent_id: String, data: String)

## Emitted when an agent exits
signal agent_exited(agent_id: String, exit_code: int, reason: String)

## Emitted when an agent terminal is resized
signal agent_resized(agent_id: String, cols: int, rows: int)

## Emitted when agent list is received
signal agent_list_received(agents: Array)

## Emitted when agent status is received
signal agent_status_received(agent_id: String, status: String, project_path: String, cols: int, rows: int)

## Emitted when server error is received
signal error_received(message: String, code: String, agent_id: String)

## Emitted when authentication succeeds
signal auth_success()

## Emitted when authentication fails
signal auth_failed(message: String)


# =============================================================================
# State
# =============================================================================

## WebSocket peer
var _socket: WebSocketPeer = null

## Current connection state
var _state: State = State.DISCONNECTED

## Bridge URL
var _url: String = ""

## Reconnect timer
var _reconnect_timer: Timer = null

## Current reconnect delay (for exponential backoff)
var _reconnect_delay: float = DEFAULT_RECONNECT_DELAY

## Reconnect attempt counter
var _reconnect_attempt: int = 0

## Auto-reconnect enabled
var _auto_reconnect: bool = true

## Ping timer
var _ping_timer: Timer = null

## Ping sequence counter
var _ping_seq: int = 0

## Last pong sequence received
var _last_pong_seq: int = 0

## Authentication token
var _auth_token: String = ""

## Whether authentication is required by the server
var _auth_required: bool = false

## Whether authentication is complete
var _authenticated: bool = false

## Whether we're connecting to a remote bridge (vs local)
var _is_remote: bool = false

## Connection timeout timer
var _connection_timer: Timer = null

## Connection start time (for timeout detection)
var _connection_start_time: float = 0.0


## Connection states
enum State {
	DISCONNECTED,
	CONNECTING,
	CONNECTED,
	RECONNECTING
}


# =============================================================================
# Lifecycle
# =============================================================================

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS

	# Setup reconnect timer
	_reconnect_timer = Timer.new()
	_reconnect_timer.one_shot = true
	_reconnect_timer.timeout.connect(_on_reconnect_timer_timeout)
	add_child(_reconnect_timer)

	# Setup ping timer
	_ping_timer = Timer.new()
	_ping_timer.wait_time = PING_INTERVAL
	_ping_timer.timeout.connect(_on_ping_timer_timeout)
	add_child(_ping_timer)

	# Setup connection timeout timer
	_connection_timer = Timer.new()
	_connection_timer.one_shot = true
	_connection_timer.wait_time = CONNECTION_TIMEOUT
	_connection_timer.timeout.connect(_on_connection_timeout)
	add_child(_connection_timer)

	# Auto-connect after bridge is started (or to remote if configured)
	_setup_auto_connect()


func _setup_auto_connect() -> void:
	# Wait a frame for other autoloads to initialize
	await get_tree().process_frame

	# Check if remote connection is configured
	var project_config := get_node_or_null("/root/ProjectConfig")
	if project_config and project_config.is_remote_connection_enabled():
		var remote: Variant = project_config.get_remote_connection()
		print("BridgeClient: Remote connection configured, connecting to %s:%d" % [remote.host, remote.port])
		_delayed_remote_connect(remote)
		return

	# Fall back to local bridge connection
	var bridge_launcher := get_node_or_null("/root/BridgeLauncher")
	if bridge_launcher:
		# Get token from launcher (which got it from ProjectConfig)
		var token: String = bridge_launcher.get_bridge_token()
		var port: int = bridge_launcher.get_bridge_port()

		# Connect to bridge started signal or connect now if already running
		if bridge_launcher.is_bridge_running():
			_delayed_connect(port, token)
		else:
			bridge_launcher.bridge_started.connect(func(_pid): _delayed_connect(port, token))
	else:
		push_warning("BridgeClient: BridgeLauncher not found, manual connection required")


func _delayed_connect(port: int, token: String) -> void:
	# Brief delay to ensure bridge is ready to accept connections
	await get_tree().create_timer(0.5).timeout
	_is_remote = false
	var err := connect_to_localhost(port, token)
	if err != OK:
		push_error("BridgeClient: Auto-connect failed: %s" % error_string(err))


func _delayed_remote_connect(remote) -> void:
	# Brief delay before connecting to remote
	await get_tree().create_timer(0.2).timeout
	_is_remote = true
	var url: String = remote.get_websocket_url()
	var token: String = remote.token
	print("BridgeClient: Connecting to remote bridge at %s" % url)
	var err := connect_to_bridge(url, token)
	if err != OK:
		push_error("BridgeClient: Remote connection failed: %s" % error_string(err))


func _process(_delta: float) -> void:
	if _socket == null:
		return

	_socket.poll()

	var socket_state := _socket.get_ready_state()

	match socket_state:
		WebSocketPeer.STATE_OPEN:
			if _state == State.CONNECTING:
				_on_connected()
			_process_messages()

		WebSocketPeer.STATE_CLOSING:
			pass  # Wait for close to complete

		WebSocketPeer.STATE_CLOSED:
			var code := _socket.get_close_code()
			var reason := _socket.get_close_reason()
			_on_disconnected(code, reason)


# =============================================================================
# Public API - Connection
# =============================================================================

## Connect to the bridge at the given URL
## Returns OK on success, or an error code
func connect_to_bridge(url: String, token: String = "") -> Error:
	if _state == State.CONNECTED or _state == State.CONNECTING:
		push_warning("BridgeClient: Already connected or connecting")
		return ERR_ALREADY_IN_USE

	_url = url
	_auth_token = token
	_authenticated = false
	_auth_required = false
	_reconnect_attempt = 0
	_reconnect_delay = DEFAULT_RECONNECT_DELAY

	return _do_connect()


## Connect to localhost bridge on given port
func connect_to_localhost(port: int = 9000, token: String = "") -> Error:
	_is_remote = false
	return connect_to_bridge("ws://127.0.0.1:%d" % port, token)


## Connect to a remote bridge at the given host and port
func connect_to_remote(host: String, port: int = 9000, token: String = "") -> Error:
	if host == "":
		push_error("BridgeClient: Remote host cannot be empty")
		return ERR_INVALID_PARAMETER
	_is_remote = true
	return connect_to_bridge("ws://%s:%d" % [host, port], token)


## Disconnect from the bridge
func disconnect_from_bridge() -> void:
	_auto_reconnect = false
	_reconnect_timer.stop()
	_ping_timer.stop()

	if _socket != null:
		_socket.close()
		_socket = null

	_state = State.DISCONNECTED
	disconnected.emit()


## Check if connected to the bridge
func is_connected_to_bridge() -> bool:
	return _state == State.CONNECTED


## Get current connection state
func get_state() -> State:
	return _state


## Enable or disable auto-reconnect
func set_auto_reconnect(enabled: bool) -> void:
	_auto_reconnect = enabled


## Check if auto-reconnect is enabled
func is_auto_reconnect_enabled() -> bool:
	return _auto_reconnect


## Check if authenticated with the bridge
func is_authenticated() -> bool:
	return _authenticated or not _auth_required


## Set the authentication token (for reconnections)
func set_auth_token(token: String) -> void:
	_auth_token = token


## Check if connected to a remote bridge (vs local)
func is_remote_connection() -> bool:
	return _is_remote


## Get the current connection URL
func get_connection_url() -> String:
	return _url


## Reconnect with current settings (useful after connection drop)
func reconnect() -> Error:
	if _url == "":
		push_error("BridgeClient: No URL to reconnect to")
		return ERR_UNCONFIGURED
	disconnect_from_bridge()
	return connect_to_bridge(_url, _auth_token)


# =============================================================================
# Public API - Messages
# =============================================================================

## Send a ping message
func send_ping() -> Error:
	_ping_seq += 1
	return _send_message({
		"type": "ping",
		"seq": _ping_seq
	})


## Request to spawn a new agent
func spawn_agent(project_path: String, preset: String = "", cols: int = 0, rows: int = 0) -> Error:
	var msg := {
		"type": "spawn_agent",
		"project_path": project_path
	}

	if preset != "":
		msg["preset"] = preset
	if cols > 0:
		msg["cols"] = cols
	if rows > 0:
		msg["rows"] = rows

	return _send_message(msg)


## Send input to an agent
func send_agent_input(agent_id: String, input: String) -> Error:
	return _send_message({
		"type": "agent_input",
		"agent_id": agent_id,
		"input": input
	})


## Kill an agent
func kill_agent(agent_id: String, sig: int = 0) -> Error:
	var msg := {
		"type": "kill_agent",
		"agent_id": agent_id
	}

	if sig > 0:
		msg["signal"] = sig

	return _send_message(msg)


## Resize an agent's terminal
func resize_terminal(agent_id: String, cols: int, rows: int) -> Error:
	return _send_message({
		"type": "resize_terminal",
		"agent_id": agent_id,
		"cols": cols,
		"rows": rows
	})


## Request list of all agents
func list_agents() -> Error:
	return _send_message({
		"type": "list_agents"
	})


## Request status of a specific agent
func get_agent_status(agent_id: String) -> Error:
	return _send_message({
		"type": "get_agent_status",
		"agent_id": agent_id
	})


# =============================================================================
# Internal - Connection
# =============================================================================

func _do_connect() -> Error:
	_socket = WebSocketPeer.new()
	var err := _socket.connect_to_url(_url)

	if err != OK:
		var error_msg := "Failed to initiate connection: %s" % error_string(err)
		push_error("BridgeClient: %s" % error_msg)
		connection_error.emit(error_msg)
		_socket = null
		return err

	_state = State.CONNECTING
	_connection_start_time = Time.get_ticks_msec() / 1000.0

	# Start connection timeout for remote connections
	if _is_remote:
		_connection_timer.start()

	return OK


func _on_connected() -> void:
	_state = State.CONNECTED
	_reconnect_attempt = 0
	_reconnect_delay = DEFAULT_RECONNECT_DELAY
	_auto_reconnect = true

	# Stop connection timeout timer
	_connection_timer.stop()

	# Start ping timer
	_ping_timer.start()

	# Update last connected time for remote connections
	if _is_remote:
		var project_config := get_node_or_null("/root/ProjectConfig")
		if project_config:
			project_config.update_remote_last_connected()

	print("BridgeClient: Connected to %s%s" % [_url, " (remote)" if _is_remote else " (local)"])
	connected.emit()


func _on_disconnected(code: int, reason: String) -> void:
	var was_connected := _state == State.CONNECTED
	_ping_timer.stop()
	_socket = null

	if was_connected:
		print("BridgeClient: Disconnected (code: %d, reason: %s)" % [code, reason])
		disconnected.emit()

	if _auto_reconnect and _url != "":
		_schedule_reconnect()
	else:
		_state = State.DISCONNECTED


func _schedule_reconnect() -> void:
	_state = State.RECONNECTING
	_reconnect_attempt += 1

	print("BridgeClient: Scheduling reconnect attempt %d in %.1fs" % [_reconnect_attempt, _reconnect_delay])
	reconnecting.emit(_reconnect_attempt)

	_reconnect_timer.wait_time = _reconnect_delay
	_reconnect_timer.start()

	# Exponential backoff
	_reconnect_delay = minf(_reconnect_delay * 1.5, MAX_RECONNECT_DELAY)


func _on_reconnect_timer_timeout() -> void:
	print("BridgeClient: Attempting reconnect...")
	var err := _do_connect()
	if err != OK:
		_schedule_reconnect()


func _on_ping_timer_timeout() -> void:
	if _state == State.CONNECTED:
		send_ping()


func _on_connection_timeout() -> void:
	if _state == State.CONNECTING:
		var error_msg := "Connection timeout after %.1fs" % CONNECTION_TIMEOUT
		push_warning("BridgeClient: %s" % error_msg)
		connection_error.emit(error_msg)

		# Close the socket and try to reconnect
		if _socket:
			_socket.close()
			_socket = null

		if _auto_reconnect:
			_schedule_reconnect()
		else:
			_state = State.DISCONNECTED


# =============================================================================
# Internal - Message Processing
# =============================================================================

func _process_messages() -> void:
	while _socket.get_available_packet_count() > 0:
		var packet := _socket.get_packet()
		var text := packet.get_string_from_utf8()
		_handle_message(text)


func _handle_message(text: String) -> void:
	var json := JSON.new()
	var err := json.parse(text)

	if err != OK:
		push_error("BridgeClient: Failed to parse message: %s" % json.get_error_message())
		return

	var data: Dictionary = json.data
	if not data is Dictionary:
		push_error("BridgeClient: Message is not a dictionary")
		return

	var msg_type: String = data.get("type", "")
	if msg_type == "":
		push_error("BridgeClient: Message missing type field")
		return

	_dispatch_message(msg_type, data)


func _dispatch_message(msg_type: String, data: Dictionary) -> void:
	match msg_type:
		"welcome":
			var version: int = data.get("version", 0)
			var server_id: String = data.get("server_id", "")
			_auth_required = data.get("auth_required", false)

			if _auth_required:
				if _auth_token != "":
					# Send authentication
					_send_auth()
				else:
					push_error("BridgeClient: Server requires authentication but no token provided")
					auth_failed.emit("No authentication token available")
					disconnect_from_bridge()
					return
			else:
				_authenticated = true

			welcome_received.emit(version, server_id)

		"auth_success":
			_authenticated = true
			print("BridgeClient: Authentication successful")
			auth_success.emit()

		"pong":
			var seq: int = data.get("seq", 0)
			_last_pong_seq = seq
			pong_received.emit(seq)

		"agent_spawned":
			var agent_id: String = data.get("agent_id", "")
			var project_path: String = data.get("project_path", "")
			var cols: int = data.get("cols", 80)
			var rows: int = data.get("rows", 24)
			agent_spawned.emit(agent_id, project_path, cols, rows)

		"agent_output":
			var agent_id: String = data.get("agent_id", "")
			var output_data: String = data.get("data", "")
			agent_output.emit(agent_id, output_data)

		"agent_exited":
			var agent_id: String = data.get("agent_id", "")
			var exit_code: int = data.get("exit_code", -1)
			var reason: String = data.get("reason", "")
			agent_exited.emit(agent_id, exit_code, reason)

		"agent_resized":
			var agent_id: String = data.get("agent_id", "")
			var cols: int = data.get("cols", 80)
			var rows: int = data.get("rows", 24)
			agent_resized.emit(agent_id, cols, rows)

		"agent_list":
			var agents: Array = data.get("agents", [])
			agent_list_received.emit(agents)

		"agent_status":
			var agent_id: String = data.get("agent_id", "")
			var status: String = data.get("status", "")
			var project_path: String = data.get("project_path", "")
			var cols: int = data.get("cols", 80)
			var rows: int = data.get("rows", 24)
			agent_status_received.emit(agent_id, status, project_path, cols, rows)

		"error":
			var message: String = data.get("message", "Unknown error")
			var code: String = data.get("code", "")
			var agent_id: String = data.get("agent_id", "")
			push_warning("BridgeClient: Server error: %s (code: %s)" % [message, code])

			# Handle auth failure specially
			if code == "auth_failed":
				_authenticated = false
				auth_failed.emit(message)

			error_received.emit(message, code, agent_id)

		_:
			push_warning("BridgeClient: Unknown message type: %s" % msg_type)


func _send_auth() -> Error:
	# Send authentication message - bypasses the auth check
	return _send_message_internal({
		"type": "authenticate",
		"token": _auth_token
	})


func _send_message(data: Dictionary) -> Error:
	if _state != State.CONNECTED:
		push_error("BridgeClient: Cannot send message - not connected")
		return ERR_CONNECTION_ERROR

	# Block messages if auth is required but not complete
	if _auth_required and not _authenticated:
		push_error("BridgeClient: Cannot send message - authentication required")
		return ERR_UNAUTHORIZED

	return _send_message_internal(data)


func _send_message_internal(data: Dictionary) -> Error:
	if _socket == null:
		push_error("BridgeClient: Socket is null")
		return ERR_CONNECTION_ERROR

	# Add protocol version
	data["version"] = PROTOCOL_VERSION

	var json_str := JSON.stringify(data)
	var err := _socket.send_text(json_str)

	if err != OK:
		push_error("BridgeClient: Failed to send message: %s" % error_string(err))
		return err

	return OK
