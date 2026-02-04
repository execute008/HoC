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
func connect_to_bridge(url: String) -> Error:
	if _state == State.CONNECTED or _state == State.CONNECTING:
		push_warning("BridgeClient: Already connected or connecting")
		return ERR_ALREADY_IN_USE

	_url = url
	_reconnect_attempt = 0
	_reconnect_delay = DEFAULT_RECONNECT_DELAY

	return _do_connect()


## Connect to localhost bridge on given port
func connect_to_localhost(port: int = 9000) -> Error:
	return connect_to_bridge("ws://127.0.0.1:%d" % port)


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
	return OK


func _on_connected() -> void:
	_state = State.CONNECTED
	_reconnect_attempt = 0
	_reconnect_delay = DEFAULT_RECONNECT_DELAY
	_auto_reconnect = true

	# Start ping timer
	_ping_timer.start()

	print("BridgeClient: Connected to %s" % _url)
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
			welcome_received.emit(version, server_id)

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
			error_received.emit(message, code, agent_id)

		_:
			push_warning("BridgeClient: Unknown message type: %s" % msg_type)


func _send_message(data: Dictionary) -> Error:
	if _state != State.CONNECTED:
		push_error("BridgeClient: Cannot send message - not connected")
		return ERR_CONNECTION_ERROR

	# Add protocol version
	data["version"] = PROTOCOL_VERSION

	var json_str := JSON.stringify(data)
	var err := _socket.send_text(json_str)

	if err != OK:
		push_error("BridgeClient: Failed to send message: %s" % error_string(err))
		return err

	return OK
