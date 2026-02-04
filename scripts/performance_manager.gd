extends Node


## PerformanceManager - Central performance monitoring and optimization for VR
##
## Monitors frame time, GPU performance, and provides automatic quality adjustments
## to maintain stable 72fps on Quest 2/3. Handles panel throttling, output buffering,
## and memory management.


# =============================================================================
# Signals
# =============================================================================

## Emitted when frame time exceeds target threshold
signal frame_time_exceeded(frame_time_ms: float, target_ms: float)

## Emitted when performance level changes
signal performance_level_changed(level: PerformanceLevel)

## Emitted when memory warning is triggered
signal memory_warning(usage_mb: float, limit_mb: float)


# =============================================================================
# Types
# =============================================================================

## Performance levels for automatic quality adjustment
enum PerformanceLevel {
	HIGH,       ## Full quality, no throttling
	MEDIUM,     ## Reduced update rates
	LOW,        ## Aggressive throttling
	CRITICAL    ## Emergency mode - minimal updates
}


# =============================================================================
# Constants
# =============================================================================

## Target frame rate for Quest (72Hz is native)
const TARGET_FPS := 72

## Target GPU frame time in milliseconds (11ms for 72fps with headroom)
const TARGET_FRAME_TIME_MS := 11.0

## Warning threshold for frame time
const WARNING_FRAME_TIME_MS := 13.5

## Critical threshold for frame time (frame drop imminent)
const CRITICAL_FRAME_TIME_MS := 16.0

## Memory warning threshold in MB
const MEMORY_WARNING_MB := 1500.0

## Memory critical threshold in MB
const MEMORY_CRITICAL_MB := 2000.0

## Distance thresholds for panel LOD (meters)
const PANEL_NEAR_DISTANCE := 2.0
const PANEL_MID_DISTANCE := 5.0
const PANEL_FAR_DISTANCE := 10.0

## Update rate multipliers for distant panels
const UPDATE_RATE_NEAR := 1.0      ## Full update rate
const UPDATE_RATE_MID := 0.5       ## Half update rate
const UPDATE_RATE_FAR := 0.25      ## Quarter update rate
const UPDATE_RATE_CULLED := 0.0    ## No updates

## Frame time history buffer size for averaging
const FRAME_TIME_HISTORY_SIZE := 60


# =============================================================================
# State
# =============================================================================

var _current_level: PerformanceLevel = PerformanceLevel.HIGH
var _frame_time_history: Array[float] = []
var _average_frame_time_ms: float = 0.0
var _peak_frame_time_ms: float = 0.0
var _frame_count: int = 0
var _last_level_change_frame: int = 0
var _level_change_cooldown_frames := 30  # Prevent rapid level changes

var _xr_camera: XRCamera3D
var _panel_registry: Node
var _panel_update_accumulators: Dictionary = {}  # panel_id -> float

## Performance statistics
var stats := {
	"fps": 0.0,
	"frame_time_ms": 0.0,
	"average_frame_time_ms": 0.0,
	"peak_frame_time_ms": 0.0,
	"gpu_frame_time_ms": 0.0,
	"performance_level": "HIGH",
	"throttled_panels": 0,
	"active_panels": 0,
	"memory_usage_mb": 0.0
}


# =============================================================================
# Lifecycle
# =============================================================================

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS

	# Initialize frame time history
	_frame_time_history.resize(FRAME_TIME_HISTORY_SIZE)
	_frame_time_history.fill(TARGET_FRAME_TIME_MS)

	# Get autoload references
	_panel_registry = get_node_or_null("/root/PanelRegistry")

	# Find XR camera on next frame (after scene setup)
	call_deferred("_find_xr_camera")


func _process(delta: float) -> void:
	_frame_count += 1

	# Update frame time statistics
	var frame_time_ms := delta * 1000.0
	_update_frame_time_stats(frame_time_ms)

	# Check performance and adjust level
	_check_performance_level()

	# Update panel throttling based on distance
	if _panel_registry and _xr_camera:
		_update_panel_throttling(delta)

	# Update stats dictionary
	_update_stats(frame_time_ms)

	# Periodic memory check (every 60 frames)
	if _frame_count % 60 == 0:
		_check_memory_usage()


func _find_xr_camera() -> void:
	var root := get_tree().root
	_xr_camera = _find_node_by_class(root, "XRCamera3D") as XRCamera3D


func _find_node_by_class(node: Node, target_class: String) -> Node:
	if node.get_class() == target_class:
		return node
	for child in node.get_children():
		var result = _find_node_by_class(child, target_class)
		if result:
			return result
	return null


# =============================================================================
# Frame Time Tracking
# =============================================================================

func _update_frame_time_stats(frame_time_ms: float) -> void:
	# Update history ring buffer
	var history_idx := _frame_count % FRAME_TIME_HISTORY_SIZE
	_frame_time_history[history_idx] = frame_time_ms

	# Calculate average
	var sum := 0.0
	for t in _frame_time_history:
		sum += t
	_average_frame_time_ms = sum / FRAME_TIME_HISTORY_SIZE

	# Track peak (reset every second)
	if frame_time_ms > _peak_frame_time_ms:
		_peak_frame_time_ms = frame_time_ms

	if _frame_count % TARGET_FPS == 0:
		_peak_frame_time_ms = frame_time_ms


func _check_performance_level() -> void:
	# Don't change level too frequently
	if _frame_count - _last_level_change_frame < _level_change_cooldown_frames:
		return

	var new_level := _current_level

	if _average_frame_time_ms > CRITICAL_FRAME_TIME_MS:
		new_level = PerformanceLevel.CRITICAL
	elif _average_frame_time_ms > WARNING_FRAME_TIME_MS:
		new_level = PerformanceLevel.LOW
	elif _average_frame_time_ms > TARGET_FRAME_TIME_MS:
		new_level = PerformanceLevel.MEDIUM
	else:
		# Only upgrade level if we have headroom
		if _average_frame_time_ms < TARGET_FRAME_TIME_MS * 0.8:
			if _current_level == PerformanceLevel.CRITICAL:
				new_level = PerformanceLevel.LOW
			elif _current_level == PerformanceLevel.LOW:
				new_level = PerformanceLevel.MEDIUM
			elif _current_level == PerformanceLevel.MEDIUM:
				new_level = PerformanceLevel.HIGH

	if new_level != _current_level:
		var old_level := _current_level
		_current_level = new_level
		_last_level_change_frame = _frame_count

		print("PerformanceManager: Level changed from %s to %s (avg frame time: %.2fms)" % [
			PerformanceLevel.keys()[old_level],
			PerformanceLevel.keys()[new_level],
			_average_frame_time_ms
		])

		performance_level_changed.emit(new_level)

	# Emit warning if frame time exceeds target
	if _average_frame_time_ms > TARGET_FRAME_TIME_MS:
		frame_time_exceeded.emit(_average_frame_time_ms, TARGET_FRAME_TIME_MS)


# =============================================================================
# Panel Throttling
# =============================================================================

func _update_panel_throttling(delta: float) -> void:
	if not _panel_registry:
		return

	var panels: Array = _panel_registry.get_all_panels()
	var camera_pos := _xr_camera.global_position if _xr_camera else Vector3.ZERO
	var throttled_count := 0

	stats["active_panels"] = panels.size()

	for panel in panels:
		if not is_instance_valid(panel):
			continue

		var panel_id: int = panel.get_meta("panel_registry_id", -1)
		if panel_id < 0:
			continue

		# Calculate distance to camera
		var distance: float = panel.global_position.distance_to(camera_pos)

		# Determine update rate based on distance and performance level
		var update_rate: float = _get_panel_update_rate(distance)

		# Adjust for performance level
		update_rate *= _get_performance_multiplier()

		# Accumulate update time
		if not _panel_update_accumulators.has(panel_id):
			_panel_update_accumulators[panel_id] = 0.0

		_panel_update_accumulators[panel_id] += delta * update_rate

		# Check if panel should update this frame
		var should_update: bool = _panel_update_accumulators[panel_id] >= (1.0 / TARGET_FPS)

		if should_update:
			_panel_update_accumulators[panel_id] = 0.0

		# Apply throttling to panel
		if panel.has_method("set_update_throttled"):
			panel.set_update_throttled(not should_update)
			if not should_update:
				throttled_count += 1

	stats["throttled_panels"] = throttled_count


func _get_panel_update_rate(distance: float) -> float:
	if distance < PANEL_NEAR_DISTANCE:
		return UPDATE_RATE_NEAR
	elif distance < PANEL_MID_DISTANCE:
		return UPDATE_RATE_MID
	elif distance < PANEL_FAR_DISTANCE:
		return UPDATE_RATE_FAR
	else:
		return UPDATE_RATE_CULLED


func _get_performance_multiplier() -> float:
	match _current_level:
		PerformanceLevel.HIGH:
			return 1.0
		PerformanceLevel.MEDIUM:
			return 0.75
		PerformanceLevel.LOW:
			return 0.5
		PerformanceLevel.CRITICAL:
			return 0.25
	return 1.0


# =============================================================================
# Memory Management
# =============================================================================

func _check_memory_usage() -> void:
	var memory_usage := OS.get_static_memory_usage() / (1024.0 * 1024.0)
	stats["memory_usage_mb"] = memory_usage

	if memory_usage > MEMORY_CRITICAL_MB:
		push_warning("PerformanceManager: Critical memory usage: %.1f MB" % memory_usage)
		memory_warning.emit(memory_usage, MEMORY_CRITICAL_MB)
		_trigger_memory_cleanup()
	elif memory_usage > MEMORY_WARNING_MB:
		memory_warning.emit(memory_usage, MEMORY_WARNING_MB)


func _trigger_memory_cleanup() -> void:
	# Request garbage collection hints
	# In GDScript we can't force GC, but we can help by clearing caches

	# Clean up panel update accumulators for dead panels
	var valid_ids := PackedInt32Array()
	if _panel_registry:
		for panel in _panel_registry.get_all_panels():
			var panel_id: int = panel.get_meta("panel_registry_id", -1)
			if panel_id >= 0:
				valid_ids.append(panel_id)

	var to_remove: Array[int] = []
	for panel_id: int in _panel_update_accumulators.keys():
		if panel_id not in valid_ids:
			to_remove.append(panel_id)

	for panel_id in to_remove:
		_panel_update_accumulators.erase(panel_id)


func _update_stats(frame_time_ms: float) -> void:
	stats["fps"] = 1000.0 / maxf(frame_time_ms, 0.001)
	stats["frame_time_ms"] = frame_time_ms
	stats["average_frame_time_ms"] = _average_frame_time_ms
	stats["peak_frame_time_ms"] = _peak_frame_time_ms
	stats["performance_level"] = PerformanceLevel.keys()[_current_level]

	# Try to get GPU frame time from RenderingServer
	var gpu_time := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
	stats["gpu_frame_time_ms"] = gpu_time / 1000.0 if gpu_time > 0 else frame_time_ms


# =============================================================================
# Public API
# =============================================================================

## Get current performance level
func get_performance_level() -> PerformanceLevel:
	return _current_level


## Get current performance statistics
func get_stats() -> Dictionary:
	return stats.duplicate()


## Check if performance is within target
func is_performance_good() -> bool:
	return _average_frame_time_ms <= TARGET_FRAME_TIME_MS


## Get recommended viewport scale based on performance
func get_recommended_viewport_scale() -> float:
	match _current_level:
		PerformanceLevel.HIGH:
			return 1.0
		PerformanceLevel.MEDIUM:
			return 0.9
		PerformanceLevel.LOW:
			return 0.75
		PerformanceLevel.CRITICAL:
			return 0.5
	return 1.0


## Force a specific performance level (for testing)
func set_performance_level(level: PerformanceLevel) -> void:
	_current_level = level
	_last_level_change_frame = _frame_count
	performance_level_changed.emit(level)


## Check if a panel should be updated based on distance
func should_update_panel(panel: Node3D) -> bool:
	if not _xr_camera:
		return true

	var distance := panel.global_position.distance_to(_xr_camera.global_position)
	var update_rate := _get_panel_update_rate(distance) * _get_performance_multiplier()

	return update_rate > 0.0


## Get throttle factor for a panel based on distance (0.0 = fully throttled, 1.0 = full speed)
func get_panel_throttle_factor(panel: Node3D) -> float:
	if not _xr_camera:
		return 1.0

	var distance := panel.global_position.distance_to(_xr_camera.global_position)
	return _get_panel_update_rate(distance) * _get_performance_multiplier()


## Register a panel for throttling management
func register_panel(panel_id: int) -> void:
	if not _panel_update_accumulators.has(panel_id):
		_panel_update_accumulators[panel_id] = 0.0


## Unregister a panel from throttling management
func unregister_panel(panel_id: int) -> void:
	_panel_update_accumulators.erase(panel_id)
