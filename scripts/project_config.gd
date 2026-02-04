extends Node


## ProjectConfig - Manages recent projects and presets for agent spawning
##
## Stores recent projects list and provides preset configurations
## for spawning new agent sessions.


# =============================================================================
# Signals
# =============================================================================

## Emitted when recent projects list changes
signal recent_projects_changed

## Emitted when presets are loaded/changed
signal presets_changed


# =============================================================================
# Constants
# =============================================================================

## Maximum number of recent projects to track
const MAX_RECENT_PROJECTS := 10

## Config file path for persisting recent projects
const CONFIG_FILE_PATH := "user://project_config.json"

## Key for storing bridge auth token (stored separately for security)
const BRIDGE_TOKEN_KEY := "bridge_auth_token"

## Key for storing remote bridge connection settings
const REMOTE_CONNECTION_KEY := "remote_connection"


# =============================================================================
# Types
# =============================================================================

## Recent project entry
class RecentProject:
	var path: String
	var name: String
	var last_opened: int  # Unix timestamp
	var preset: String  # Last used preset
	var preferred_layout: String  # Project-specific layout name
	var kill_agents_on_switch: bool  # Whether to kill agents when switching away
	var custom_settings: Dictionary  # Additional project-specific settings

	func _init(p_path: String = "", p_name: String = "") -> void:
		path = p_path
		name = p_name if p_name != "" else _extract_name(p_path)
		last_opened = Time.get_unix_time_from_system()
		preset = ""
		preferred_layout = ""  # Empty means use default behavior
		kill_agents_on_switch = true  # Default to killing agents
		custom_settings = {}

	static func _extract_name(p_path: String) -> String:
		if p_path == "":
			return "Unknown"
		var parts := p_path.split("/")
		if parts.size() > 0:
			return parts[-1]
		return p_path

	func to_dict() -> Dictionary:
		return {
			"path": path,
			"name": name,
			"last_opened": last_opened,
			"preset": preset,
			"preferred_layout": preferred_layout,
			"kill_agents_on_switch": kill_agents_on_switch,
			"custom_settings": custom_settings
		}

	static func from_dict(data: Dictionary) -> RecentProject:
		var project := RecentProject.new(
			data.get("path", ""),
			data.get("name", "")
		)
		project.last_opened = data.get("last_opened", 0)
		project.preset = data.get("preset", "")
		project.preferred_layout = data.get("preferred_layout", "")
		project.kill_agents_on_switch = data.get("kill_agents_on_switch", true)
		project.custom_settings = data.get("custom_settings", {})
		return project


## Remote connection settings for connecting to PC-hosted bridge
class RemoteConnection:
	var enabled: bool  # Whether to use remote connection instead of local
	var host: String  # IP address or hostname of remote PC
	var port: int  # WebSocket port (default 9000)
	var token: String  # Authentication token for remote bridge
	var auto_reconnect: bool  # Whether to auto-reconnect on disconnect
	var last_connected: int  # Unix timestamp of last successful connection

	func _init() -> void:
		enabled = false
		host = ""
		port = 9000
		token = ""
		auto_reconnect = true
		last_connected = 0

	func to_dict() -> Dictionary:
		return {
			"enabled": enabled,
			"host": host,
			"port": port,
			"token": token,
			"auto_reconnect": auto_reconnect,
			"last_connected": last_connected
		}

	static func from_dict(data: Dictionary) -> RemoteConnection:
		var conn := RemoteConnection.new()
		conn.enabled = data.get("enabled", false)
		conn.host = data.get("host", "")
		conn.port = data.get("port", 9000)
		conn.token = data.get("token", "")
		conn.auto_reconnect = data.get("auto_reconnect", true)
		conn.last_connected = data.get("last_connected", 0)
		return conn

	func get_websocket_url() -> String:
		if host == "":
			return ""
		return "ws://%s:%d" % [host, port]

	func is_configured() -> bool:
		return host != "" and port > 0


## Preset configuration
class Preset:
	var name: String
	var description: String
	var icon: String
	var cols: int
	var rows: int
	var env_vars: Dictionary
	var args: PackedStringArray  ## Command-line arguments for the agent
	var initial_prompt: String  ## Initial prompt to send after spawn

	func _init(p_name: String = "default") -> void:
		name = p_name
		description = ""
		icon = "⚡"
		cols = 80
		rows = 24
		env_vars = {}
		args = PackedStringArray()
		initial_prompt = ""

	func to_dict() -> Dictionary:
		return {
			"name": name,
			"description": description,
			"icon": icon,
			"cols": cols,
			"rows": rows,
			"env_vars": env_vars,
			"args": Array(args),
			"initial_prompt": initial_prompt
		}

	static func from_dict(data: Dictionary) -> Preset:
		var preset := Preset.new(data.get("name", "default"))
		preset.description = data.get("description", "")
		preset.icon = data.get("icon", "⚡")
		preset.cols = data.get("cols", 80)
		preset.rows = data.get("rows", 24)
		preset.env_vars = data.get("env_vars", {})
		var args_array: Array = data.get("args", [])
		for arg in args_array:
			preset.args.append(str(arg))
		preset.initial_prompt = data.get("initial_prompt", "")
		return preset


# =============================================================================
# State
# =============================================================================

## Recent projects list (most recent first)
var _recent_projects: Array[RecentProject] = []

## Available presets
var _presets: Dictionary = {}  # name -> Preset

## Bridge authentication token
var _bridge_token: String = ""

## Remote connection settings
var _remote_connection: RemoteConnection = RemoteConnection.new()


# =============================================================================
# Lifecycle
# =============================================================================

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_load_config()
	_init_default_presets()


# =============================================================================
# Public API - Recent Projects
# =============================================================================

## Get recent projects list (most recent first)
func get_recent_projects() -> Array[RecentProject]:
	return _recent_projects.duplicate()


## Add or update a project in recent list
func add_recent_project(path: String, preset: String = "") -> void:
	# Check if already exists
	var existing_idx := -1
	for i in range(_recent_projects.size()):
		if _recent_projects[i].path == path:
			existing_idx = i
			break

	if existing_idx >= 0:
		# Move to front and update timestamp
		var project := _recent_projects[existing_idx]
		_recent_projects.remove_at(existing_idx)
		project.last_opened = Time.get_unix_time_from_system()
		if preset != "":
			project.preset = preset
		_recent_projects.insert(0, project)
	else:
		# Add new project
		var project := RecentProject.new(path)
		project.preset = preset
		_recent_projects.insert(0, project)

	# Trim to max size
	while _recent_projects.size() > MAX_RECENT_PROJECTS:
		_recent_projects.pop_back()

	_save_config()
	recent_projects_changed.emit()


## Remove a project from recent list
func remove_recent_project(path: String) -> void:
	for i in range(_recent_projects.size() - 1, -1, -1):
		if _recent_projects[i].path == path:
			_recent_projects.remove_at(i)
			_save_config()
			recent_projects_changed.emit()
			return


## Clear all recent projects
func clear_recent_projects() -> void:
	_recent_projects.clear()
	_save_config()
	recent_projects_changed.emit()


## Check if a path exists in recent projects
func has_recent_project(path: String) -> bool:
	for project in _recent_projects:
		if project.path == path:
			return true
	return false


## Get the last used preset for a project
func get_last_preset(path: String) -> String:
	for project in _recent_projects:
		if project.path == path:
			return project.preset
	return ""


## Get a project by path
func get_project(path: String) -> RecentProject:
	for project in _recent_projects:
		if project.path == path:
			return project
	return null


## Update project settings
func update_project_settings(path: String, settings: Dictionary) -> void:
	for project in _recent_projects:
		if project.path == path:
			if settings.has("preset"):
				project.preset = settings["preset"]
			if settings.has("preferred_layout"):
				project.preferred_layout = settings["preferred_layout"]
			if settings.has("kill_agents_on_switch"):
				project.kill_agents_on_switch = settings["kill_agents_on_switch"]
			if settings.has("custom_settings"):
				project.custom_settings.merge(settings["custom_settings"], true)
			project.last_opened = Time.get_unix_time_from_system()
			_save_config()
			recent_projects_changed.emit()
			return


## Get preferred layout for a project
func get_project_layout(path: String) -> String:
	for project in _recent_projects:
		if project.path == path:
			return project.preferred_layout
	return ""


## Set preferred layout for a project
func set_project_layout(path: String, layout_name: String) -> void:
	update_project_settings(path, {"preferred_layout": layout_name})


## Get kill agents setting for a project
func get_project_kill_agents(path: String) -> bool:
	for project in _recent_projects:
		if project.path == path:
			return project.kill_agents_on_switch
	return true  # Default to killing agents


## Set kill agents setting for a project
func set_project_kill_agents(path: String, value: bool) -> void:
	update_project_settings(path, {"kill_agents_on_switch": value})


# =============================================================================
# Public API - Bridge Authentication
# =============================================================================

## Get the stored bridge authentication token
func get_bridge_token() -> String:
	return _bridge_token


## Set the bridge authentication token
func set_bridge_token(token: String) -> void:
	_bridge_token = token
	_save_config()


## Check if a bridge token is set
func has_bridge_token() -> bool:
	return _bridge_token != ""


## Clear the bridge authentication token
func clear_bridge_token() -> void:
	_bridge_token = ""
	_save_config()


## Generate a new random bridge token (32 hex characters)
func generate_bridge_token() -> String:
	var bytes := PackedByteArray()
	for i in range(16):
		bytes.append(randi() % 256)
	var token := bytes.hex_encode()
	set_bridge_token(token)
	return token


# =============================================================================
# Public API - Remote Connection
# =============================================================================

## Emitted when remote connection settings change
signal remote_connection_changed

## Get the remote connection settings
func get_remote_connection() -> RemoteConnection:
	return _remote_connection


## Check if remote connection is enabled
func is_remote_connection_enabled() -> bool:
	return _remote_connection.enabled and _remote_connection.is_configured()


## Enable or disable remote connection
func set_remote_connection_enabled(enabled: bool) -> void:
	_remote_connection.enabled = enabled
	_save_config()
	remote_connection_changed.emit()


## Set the remote connection host and port
func set_remote_connection_host(host: String, port: int = 9000) -> void:
	_remote_connection.host = host
	_remote_connection.port = port
	_save_config()
	remote_connection_changed.emit()


## Set the remote connection authentication token
func set_remote_connection_token(token: String) -> void:
	_remote_connection.token = token
	_save_config()
	remote_connection_changed.emit()


## Enable or disable auto-reconnect for remote connection
func set_remote_auto_reconnect(enabled: bool) -> void:
	_remote_connection.auto_reconnect = enabled
	_save_config()


## Update the last connected timestamp
func update_remote_last_connected() -> void:
	_remote_connection.last_connected = Time.get_unix_time_from_system()
	_save_config()


## Get the full WebSocket URL for remote connection
func get_remote_websocket_url() -> String:
	return _remote_connection.get_websocket_url()


## Configure remote connection with all settings at once
func configure_remote_connection(host: String, port: int, token: String, enabled: bool = true) -> void:
	_remote_connection.host = host
	_remote_connection.port = port
	_remote_connection.token = token
	_remote_connection.enabled = enabled
	_save_config()
	remote_connection_changed.emit()


## Clear remote connection settings
func clear_remote_connection() -> void:
	_remote_connection = RemoteConnection.new()
	_save_config()
	remote_connection_changed.emit()


# =============================================================================
# Public API - Presets
# =============================================================================

## Get all available presets
func get_presets() -> Array[Preset]:
	var result: Array[Preset] = []
	for preset in _presets.values():
		result.append(preset)
	return result


## Get preset names
func get_preset_names() -> PackedStringArray:
	var names := PackedStringArray()
	for name in _presets.keys():
		names.append(name)
	return names


## Get a preset by name
func get_preset(name: String) -> Preset:
	return _presets.get(name)


## Check if a preset exists
func has_preset(name: String) -> bool:
	return name in _presets


## Add or update a preset
func set_preset(preset: Preset) -> void:
	_presets[preset.name] = preset
	_save_config()
	presets_changed.emit()


## Remove a preset
func remove_preset(name: String) -> void:
	if _presets.has(name):
		_presets.erase(name)
		_save_config()
		presets_changed.emit()


## Get the default preset
func get_default_preset() -> Preset:
	if _presets.has("default"):
		return _presets["default"]
	# Return a basic default
	return Preset.new("default")


# =============================================================================
# Internal - Config Persistence
# =============================================================================

func _load_config() -> void:
	if not FileAccess.file_exists(CONFIG_FILE_PATH):
		return

	var file := FileAccess.open(CONFIG_FILE_PATH, FileAccess.READ)
	if not file:
		push_warning("ProjectConfig: Failed to open config file")
		return

	var json_text := file.get_as_text()
	file.close()

	var json := JSON.new()
	var error := json.parse(json_text)
	if error != OK:
		push_warning("ProjectConfig: Failed to parse config JSON: %s" % json.get_error_message())
		return

	var data: Dictionary = json.data

	# Load recent projects
	var recent_data: Array = data.get("recent_projects", [])
	_recent_projects.clear()
	for project_data: Dictionary in recent_data:
		_recent_projects.append(RecentProject.from_dict(project_data))

	# Load presets
	var presets_data: Dictionary = data.get("presets", {})
	for preset_name: String in presets_data:
		var preset_dict: Dictionary = presets_data[preset_name]
		_presets[preset_name] = Preset.from_dict(preset_dict)

	# Load bridge token
	_bridge_token = data.get(BRIDGE_TOKEN_KEY, "")

	# Load remote connection settings
	var remote_data: Dictionary = data.get(REMOTE_CONNECTION_KEY, {})
	if not remote_data.is_empty():
		_remote_connection = RemoteConnection.from_dict(remote_data)


func _save_config() -> void:
	var data := {
		"recent_projects": [],
		"presets": {}
	}

	# Save recent projects
	for project in _recent_projects:
		data["recent_projects"].append(project.to_dict())

	# Save presets
	for preset_name: String in _presets:
		var preset: Preset = _presets[preset_name]
		data["presets"][preset_name] = preset.to_dict()

	# Save bridge token
	if _bridge_token != "":
		data[BRIDGE_TOKEN_KEY] = _bridge_token

	# Save remote connection settings
	if _remote_connection.is_configured():
		data[REMOTE_CONNECTION_KEY] = _remote_connection.to_dict()

	var json_text := JSON.stringify(data, "\t")

	var file := FileAccess.open(CONFIG_FILE_PATH, FileAccess.WRITE)
	if not file:
		push_error("ProjectConfig: Failed to write config file")
		return

	file.store_string(json_text)
	file.close()


func _init_default_presets() -> void:
	# Only add defaults if no presets exist
	if _presets.size() > 0:
		return

	# Default preset
	var default_preset := Preset.new("default")
	default_preset.description = "Standard terminal session"
	default_preset.icon = "⚡"
	default_preset.cols = 80
	default_preset.rows = 24
	_presets["default"] = default_preset

	# Wide preset
	var wide_preset := Preset.new("wide")
	wide_preset.description = "Wide terminal for detailed output"
	wide_preset.icon = "📐"
	wide_preset.cols = 120
	wide_preset.rows = 30
	_presets["wide"] = wide_preset

	# Compact preset
	var compact_preset := Preset.new("compact")
	compact_preset.description = "Compact terminal for limited space"
	compact_preset.icon = "📦"
	compact_preset.cols = 60
	compact_preset.rows = 20
	_presets["compact"] = compact_preset

	_save_config()


# =============================================================================
# Public API - Project-Specific Presets
# =============================================================================

## Project-specific presets cache (project_path -> Array[Preset])
var _project_presets_cache: Dictionary = {}

## Default preset name for a project (project_path -> String)
var _project_default_preset: Dictionary = {}


## Load presets from a project's .hoc/config.toml file
## Returns an array of project-specific presets, or empty if none found
func load_project_presets(project_path: String) -> Array[Preset]:
	# Check cache first
	if _project_presets_cache.has(project_path):
		return _project_presets_cache[project_path]

	var result: Array[Preset] = []
	var config_path := project_path.path_join(".hoc").path_join("config.toml")

	if not FileAccess.file_exists(config_path):
		_project_presets_cache[project_path] = result
		return result

	var file := FileAccess.open(config_path, FileAccess.READ)
	if not file:
		push_warning("ProjectConfig: Failed to open project config: %s" % config_path)
		_project_presets_cache[project_path] = result
		return result

	var toml_text := file.get_as_text()
	file.close()

	# Parse TOML manually (simple parser for our specific format)
	result = _parse_toml_presets(toml_text)

	# Parse default preset name
	_project_default_preset[project_path] = _parse_toml_default_preset(toml_text)

	_project_presets_cache[project_path] = result
	return result


## Get project presets combined with global presets
## Project presets take precedence over global ones with same name
func get_presets_for_project(project_path: String) -> Array[Preset]:
	var project_presets := load_project_presets(project_path)
	var result: Array[Preset] = []
	var seen_names: Dictionary = {}

	# Add project presets first (they take precedence)
	for preset in project_presets:
		result.append(preset)
		seen_names[preset.name] = true

	# Add global presets that aren't overridden
	for preset in _presets.values():
		if not seen_names.has(preset.name):
			result.append(preset)

	return result


## Get the default preset name for a project
## Returns the project's default if set, otherwise "default"
func get_default_preset_name(project_path: String) -> String:
	# Ensure project presets are loaded
	load_project_presets(project_path)

	if _project_default_preset.has(project_path):
		var default_name: String = _project_default_preset[project_path]
		if default_name != "":
			return default_name

	return "default"


## Clear the project presets cache (call when project config may have changed)
func clear_project_cache(project_path: String = "") -> void:
	if project_path == "":
		_project_presets_cache.clear()
		_project_default_preset.clear()
	else:
		_project_presets_cache.erase(project_path)
		_project_default_preset.erase(project_path)


## Parse TOML preset entries from config text
func _parse_toml_presets(toml_text: String) -> Array[Preset]:
	var result: Array[Preset] = []
	var lines := toml_text.split("\n")

	var current_preset: Preset = null
	var in_preset := false

	for line in lines:
		var trimmed := line.strip_edges()

		# Skip empty lines and comments
		if trimmed == "" or trimmed.begins_with("#"):
			continue

		# Check for [[presets]] section header
		if trimmed == "[[presets]]":
			# Save previous preset if exists
			if current_preset != null:
				result.append(current_preset)
			current_preset = Preset.new()
			in_preset = true
			continue

		# Check for other section headers (ends current preset)
		if trimmed.begins_with("[") and trimmed != "[[presets]]":
			if current_preset != null:
				result.append(current_preset)
				current_preset = null
			in_preset = false
			continue

		# Parse key-value pairs in preset section
		if in_preset and current_preset != null:
			var eq_pos := trimmed.find("=")
			if eq_pos > 0:
				var key := trimmed.substr(0, eq_pos).strip_edges()
				var value := trimmed.substr(eq_pos + 1).strip_edges()

				match key:
					"name":
						current_preset.name = _parse_toml_string(value)
					"description":
						current_preset.description = _parse_toml_string(value)
					"icon":
						current_preset.icon = _parse_toml_string(value)
					"cols":
						current_preset.cols = int(value)
					"rows":
						current_preset.rows = int(value)
					"initial_prompt":
						current_preset.initial_prompt = _parse_toml_string(value)
					"args":
						current_preset.args = _parse_toml_string_array(value)

	# Don't forget the last preset
	if current_preset != null:
		result.append(current_preset)

	return result


## Parse default_preset from TOML config
func _parse_toml_default_preset(toml_text: String) -> String:
	var lines := toml_text.split("\n")
	var in_default_section := false

	for line in lines:
		var trimmed := line.strip_edges()

		if trimmed == "" or trimmed.begins_with("#"):
			continue

		# Check for [default_preset] section
		if trimmed == "[default_preset]":
			in_default_section = true
			continue

		# Other sections end default_preset section
		if trimmed.begins_with("["):
			in_default_section = false
			continue

		if in_default_section:
			var eq_pos := trimmed.find("=")
			if eq_pos > 0:
				var key := trimmed.substr(0, eq_pos).strip_edges()
				var value := trimmed.substr(eq_pos + 1).strip_edges()
				if key == "name":
					return _parse_toml_string(value)

	return ""


## Parse a TOML string value (remove quotes)
func _parse_toml_string(value: String) -> String:
	var v := value.strip_edges()
	if v.begins_with("\"") and v.ends_with("\""):
		return v.substr(1, v.length() - 2)
	if v.begins_with("'") and v.ends_with("'"):
		return v.substr(1, v.length() - 2)
	return v


## Parse a TOML array of strings
func _parse_toml_string_array(value: String) -> PackedStringArray:
	var result := PackedStringArray()
	var v := value.strip_edges()

	# Remove brackets
	if v.begins_with("[") and v.ends_with("]"):
		v = v.substr(1, v.length() - 2)

	# Split by comma and parse each element
	var parts := v.split(",")
	for part in parts:
		var trimmed := part.strip_edges()
		if trimmed != "":
			result.append(_parse_toml_string(trimmed))

	return result
