extends Control


## Demo content script for WorkspacePanel testing


@onready var status_label: Label = $VBoxContainer/StatusLabel
@onready var button: Button = $VBoxContainer/CenterContainer/VBoxContainer/Button
@onready var slider: HSlider = $VBoxContainer/CenterContainer/VBoxContainer/HSlider
@onready var checkbox: CheckBox = $VBoxContainer/CenterContainer/VBoxContainer/CheckBox


func _ready() -> void:
	button.pressed.connect(_on_button_pressed)
	slider.value_changed.connect(_on_slider_changed)
	checkbox.toggled.connect(_on_checkbox_toggled)
	_update_status("Ready")


func _on_button_pressed() -> void:
	_update_status("Button clicked!")


func _on_slider_changed(value: float) -> void:
	_update_status("Slider: %.0f%%" % value)


func _on_checkbox_toggled(pressed: bool) -> void:
	_update_status("Feature: " + ("Enabled" if pressed else "Disabled"))


func _update_status(text: String) -> void:
	if status_label:
		status_label.text = text
