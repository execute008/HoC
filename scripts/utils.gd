extends Node
## Utils - Shared utility functions available as autoload


## Recursively search for a node of the given class name in the scene tree.
static func find_node_by_class(node: Node, target_class: String) -> Node:
	if node.get_class() == target_class:
		return node
	for child in node.get_children():
		var result = find_node_by_class(child, target_class)
		if result:
			return result
	return null


## Format a unix timestamp as a human-readable "time ago" string.
static func format_time_ago(timestamp: int) -> String:
	var now := int(Time.get_unix_time_from_system())
	var diff: int = now - timestamp

	if diff < 60:
		return "just now"
	elif diff < 3600:
		var mins := diff / 60
		return "%d min ago" % mins
	elif diff < 86400:
		var hours := diff / 3600
		return "%d hour%s ago" % [hours, "s" if hours > 1 else ""]
	elif diff < 604800:
		var days := diff / 86400
		return "%d day%s ago" % [days, "s" if days > 1 else ""]
	else:
		var weeks := diff / 604800
		return "%d week%s ago" % [weeks, "s" if weeks > 1 else ""]
