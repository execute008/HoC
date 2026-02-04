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

	func _init(p_name: String = "default") -> void:
		name = p_name
		description = ""
		icon = "⚡"
		cols = 80
		rows = 24
		env_vars = {}

	func to_dict() -> Dictionary:
		return {
			"name": name,
			"description": description,
			"icon": icon,
			"cols": cols,
			"rows": rows,
			"env_vars": env_vars
		}

	static func from_dict(data: Dictionary) -> Preset:
		var preset := Preset.new(data.get("name", "default"))
		preset.description = data.get("description", "")
		preset.icon = data.get("icon", "⚡")
		preset.cols = data.get("cols", 80)
		preset.rows = data.get("rows", 24)
		preset.env_vars = data.get("env_vars", {})
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
