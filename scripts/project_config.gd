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


# =============================================================================
# Types
# =============================================================================

## Recent project entry
class RecentProject:
	var path: String
	var name: String
	var last_opened: int  # Unix timestamp
	var preset: String  # Last used preset

	func _init(p_path: String = "", p_name: String = "") -> void:
		path = p_path
		name = p_name if p_name != "" else _extract_name(p_path)
		last_opened = Time.get_unix_time_from_system()
		preset = ""

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
			"preset": preset
		}

	static func from_dict(data: Dictionary) -> RecentProject:
		var project := RecentProject.new(
			data.get("path", ""),
			data.get("name", "")
		)
		project.last_opened = data.get("last_opened", 0)
		project.preset = data.get("preset", "")
		return project


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
