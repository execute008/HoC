extends Node3D


## Main scene controller
##
## Handles initialization tasks like registering existing panels with the registry.


func _ready() -> void:
	# Wait a frame for all nodes to be ready
	await get_tree().process_frame

	# Register any existing panels with the registry
	_register_existing_panels()


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
