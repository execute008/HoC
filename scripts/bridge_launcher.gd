extends Node


## BridgeLauncher - Autoload singleton for managing the bridge process
##
## Automatically launches the hoc-bridge WebSocket server on game start
## and ensures cleanup on game exit. Handles port detection to avoid
## launching duplicates.


## Emitted when bridge starts successfully
signal bridge_started(pid: int)

## Emitted when bridge fails to start
signal bridge_failed(error: String)

## Emitted when bridge process exits
signal bridge_exited(exit_code: int)


## Default bridge port
const DEFAULT_PORT := 9000

## Bridge binary name
const BRIDGE_BINARY := "hoc-bridge"

## Connection check timeout in milliseconds
const PORT_CHECK_TIMEOUT_MS := 1000


## Bridge process ID (-1 if not running)
var _bridge_pid: int = -1

## Whether we launched the bridge (vs it was already running)
var _we_launched_bridge: bool = false

## Bridge port
var _port: int = DEFAULT_PORT

## Authentication token
var _token: String = ""

## Whether using remote bridge mode (skip local launch)
var _remote_mode: bool = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS

	# Check if remote connection is enabled
	var project_config := get_node_or_null("/root/ProjectConfig")
	if project_config and project_config.is_remote_connection_enabled():
		_remote_mode = true
		print("BridgeLauncher: Remote mode enabled, skipping local bridge launch")
		# Emit bridge_started to signal that connection can proceed
		# BridgeClient will handle remote connection directly
		bridge_started.emit(-1)
		return

	# Load or generate token from ProjectConfig
	_init_token()

	# Auto-launch bridge
	_launch_bridge()


## Initialize the authentication token
func _init_token() -> void:
	var project_config := get_node_or_null("/root/ProjectConfig")
	if project_config:
		if project_config.has_bridge_token():
			_token = project_config.get_bridge_token()
		else:
			# Generate a new token if none exists
			_token = project_config.generate_bridge_token()
			print("BridgeLauncher: Generated new auth token")
	else:
		push_warning("BridgeLauncher: ProjectConfig not found, token auth disabled")


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_cleanup_bridge()
	elif what == NOTIFICATION_EXIT_TREE:
		_cleanup_bridge()


## Get the bridge binary path
func get_bridge_binary_path() -> String:
	var base_path := ProjectSettings.globalize_path("res://")
	var bin_path := base_path.path_join("bin").path_join(BRIDGE_BINARY)

	# On Windows, add .exe extension
	if OS.get_name() == "Windows":
		bin_path += ".exe"

	return bin_path


## Check if bridge is already running by testing the port
func is_bridge_running() -> bool:
	var tcp := StreamPeerTCP.new()
	var err := tcp.connect_to_host("127.0.0.1", _port)

	if err != OK:
		return false

	# Wait for connection with timeout
	var start_time := Time.get_ticks_msec()
	while tcp.get_status() == StreamPeerTCP.STATUS_CONNECTING:
		tcp.poll()
		if Time.get_ticks_msec() - start_time > PORT_CHECK_TIMEOUT_MS:
			tcp.disconnect_from_host()
			return false
		OS.delay_msec(10)

	var connected := tcp.get_status() == StreamPeerTCP.STATUS_CONNECTED
	tcp.disconnect_from_host()
	return connected


## Get the bridge process ID
func get_bridge_pid() -> int:
	return _bridge_pid


## Get the bridge port
func get_bridge_port() -> int:
	return _port


## Get the authentication token
func get_bridge_token() -> String:
	return _token


## Check if we launched the bridge
func did_we_launch_bridge() -> bool:
	return _we_launched_bridge


## Check if using remote bridge mode
func is_remote_mode() -> bool:
	return _remote_mode


## Launch the bridge process
func _launch_bridge() -> void:
	# Check if bridge binary exists
	var binary_path := get_bridge_binary_path()
	if not FileAccess.file_exists(binary_path):
		var error_msg := "Bridge binary not found at: %s" % binary_path
		push_error("BridgeLauncher: %s" % error_msg)
		bridge_failed.emit(error_msg)
		return

	# Check if bridge is already running
	if is_bridge_running():
		print("BridgeLauncher: Bridge already running on port %d" % _port)
		_we_launched_bridge = false
		bridge_started.emit(-1)
		return

	# Build command arguments
	var args: PackedStringArray = [
		"--port", str(_port),
		"--bind", "127.0.0.1"
	]

	# Add token if available
	if _token != "":
		args.append("--token")
		args.append(_token)

	# Launch bridge process
	_bridge_pid = OS.create_process(binary_path, args)

	if _bridge_pid <= 0:
		var error_msg := "Failed to launch bridge process"
		push_error("BridgeLauncher: %s" % error_msg)
		_bridge_pid = -1
		bridge_failed.emit(error_msg)
		return

	_we_launched_bridge = true
	print("BridgeLauncher: Bridge started with PID %d on port %d" % [_bridge_pid, _port])
	bridge_started.emit(_bridge_pid)


## Kill the bridge process if we launched it
func _cleanup_bridge() -> void:
	if not _we_launched_bridge or _bridge_pid <= 0:
		return

	print("BridgeLauncher: Stopping bridge process (PID %d)" % _bridge_pid)

	var err := OS.kill(_bridge_pid)
	if err != OK:
		push_warning("BridgeLauncher: Failed to kill bridge process: %s" % error_string(err))
	else:
		bridge_exited.emit(0)

	_bridge_pid = -1
	_we_launched_bridge = false


