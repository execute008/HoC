extends Node3D


## Main scene controller
##
## Handles initialization tasks like registering existing panels with the registry
## and restoring/saving workspace layouts between sessions.


func _ready() -> void:
	# Wait a frame for all nodes to be ready
	await get_tree().process_frame

	# Register any existing panels with the registry
	_register_existing_panels()

	# Restore previous session layout
	_restore_session_layout()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		# Save session layout before closing
		_save_session_layout()
		get_tree().quit()


func _register_existing_panels() -> void:
	# Find all WorkspacePanel instances in the scene
	var panels := _find_panels(self)

	for panel in panels:
		# Only register if not already registered
		if not panel.has_meta("panel_registry_id"):
			PanelRegistry.register_panel(panel)


func _find_panels(node: Node) -> Array[WorkspacePanel]:
	var result: Array[WorkspacePanel] = []

	if node is WorkspacePanel:
		result.append(node)

	for child in node.get_children():
		result.append_array(_find_panels(child))

	return result


func _restore_session_layout() -> void:
	# Check if LayoutManager is available
	var layout_manager := get_node_or_null("/root/LayoutManager")
	if not layout_manager:
		return

	# Restore session layout if it exists
	if layout_manager.has_layout("_session"):
		await layout_manager.load_layout("_session", false)  # Don't close existing panels
		print("MainScene: Restored session layout")
	elif layout_manager.has_layout(layout_manager.DEFAULT_LAYOUT_NAME):
		await layout_manager.load_layout(layout_manager.DEFAULT_LAYOUT_NAME, false)
		print("MainScene: Loaded default layout")


func _save_session_layout() -> void:
	# Check if LayoutManager is available
	var layout_manager := get_node_or_null("/root/LayoutManager")
	if not layout_manager:
		return

	# Save current layout as session layout
	layout_manager.save_session_layout()
	print("MainScene: Saved session layout")
