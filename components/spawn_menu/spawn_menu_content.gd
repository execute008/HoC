class_name SpawnMenuContent
extends Control


## SpawnMenuContent - 2D UI content for the spawn panel menu
##
## Displays available panel types as buttons that can be clicked to spawn new panels.


## Emitted when a panel type is selected for spawning
signal panel_type_selected(type_key: String)

## Emitted when the menu should be closed
signal close_requested


# UI References
var _title_label: Label
var _panel_list: VBoxContainer
var _close_button: Button


func _ready() -> void:
	_setup_ui()
	_populate_panel_types()


func _setup_ui() -> void:
	# Main container
	var main_container := VBoxContainer.new()
	main_container.name = "MainContainer"
	main_container.set_anchors_preset(Control.PRESET_FULL_RECT)
	main_container.add_theme_constant_override("separation", 10)
	add_child(main_container)

	# Add margin
	var margin := MarginContainer.new()
	margin.name = "Margin"
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	margin.add_theme_constant_override("margin_left", 20)
	margin.add_theme_constant_override("margin_right", 20)
	margin.add_theme_constant_override("margin_top", 15)
	margin.add_theme_constant_override("margin_bottom", 15)
	main_container.add_child(margin)

	var inner_container := VBoxContainer.new()
	inner_container.name = "InnerContainer"
	inner_container.add_theme_constant_override("separation", 12)
	margin.add_child(inner_container)

	# Title
	_title_label = Label.new()
	_title_label.name = "TitleLabel"
	_title_label.text = "Spawn Panel"
	_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title_label.add_theme_font_size_override("font_size", 24)
	_title_label.add_theme_color_override("font_color", Color(0.9, 0.9, 0.95))
	inner_container.add_child(_title_label)

	# Separator
	var separator := HSeparator.new()
	separator.name = "Separator"
	inner_container.add_child(separator)

	# Scroll container for panel list
	var scroll := ScrollContainer.new()
	scroll.name = "ScrollContainer"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	inner_container.add_child(scroll)

	# Panel list container
	_panel_list = VBoxContainer.new()
	_panel_list.name = "PanelList"
	_panel_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_panel_list.add_theme_constant_override("separation", 8)
	scroll.add_child(_panel_list)


func _populate_panel_types() -> void:
	# Clear existing buttons
	for child in _panel_list.get_children():
		child.queue_free()

	# Get panel types from registry constant
	var panel_types := PanelRegistry.PANEL_TYPES

	for type_key in panel_types:
		var type_info: Dictionary = panel_types[type_key]
		_create_panel_button(type_key, type_info)


func _create_panel_button(type_key: String, type_info: Dictionary) -> void:
	var button := Button.new()
	button.name = "Button_" + type_key
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.custom_minimum_size = Vector2(0, 60)

	# Create button content with icon and text
	var hbox := HBoxContainer.new()
	hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hbox.add_theme_constant_override("separation", 12)
	button.add_child(hbox)

	# Icon label (emoji)
	var icon_label := Label.new()
	icon_label.text = type_info.get("icon", "📄")
	icon_label.add_theme_font_size_override("font_size", 28)
	icon_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hbox.add_child(icon_label)

	# Text container
	var text_container := VBoxContainer.new()
	text_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text_container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	text_container.add_theme_constant_override("separation", 2)
	hbox.add_child(text_container)

	# Name label
	var name_label := Label.new()
	name_label.text = type_info.get("name", type_key)
	name_label.add_theme_font_size_override("font_size", 18)
	name_label.add_theme_color_override("font_color", Color.WHITE)
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	text_container.add_child(name_label)

	# Description label
	var desc_label := Label.new()
	desc_label.text = type_info.get("description", "")
	desc_label.add_theme_font_size_override("font_size", 12)
	desc_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.75))
	desc_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	text_container.add_child(desc_label)

	# Style the button
	_style_button(button)

	# Connect signal
	button.pressed.connect(_on_panel_button_pressed.bind(type_key))

	_panel_list.add_child(button)


func _style_button(button: Button) -> void:
	# Create button style
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.2, 0.2, 0.25, 0.9)
	style.border_color = Color(0.3, 0.3, 0.35)
	style.set_border_width_all(1)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(12)
	button.add_theme_stylebox_override("normal", style)

	# Hover style
	var hover_style := style.duplicate()
	hover_style.bg_color = Color(0.25, 0.25, 0.3, 0.95)
	hover_style.border_color = Color(0.4, 0.6, 0.9)
	button.add_theme_stylebox_override("hover", hover_style)

	# Pressed style
	var pressed_style := style.duplicate()
	pressed_style.bg_color = Color(0.3, 0.4, 0.5, 0.95)
	pressed_style.border_color = Color(0.5, 0.7, 1.0)
	button.add_theme_stylebox_override("pressed", pressed_style)


func _on_panel_button_pressed(type_key: String) -> void:
	panel_type_selected.emit(type_key)


func refresh_panel_list() -> void:
	_populate_panel_types()
