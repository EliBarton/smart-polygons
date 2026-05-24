@tool
extends EditorPlugin

const CUSTOM_TYPE_NAME := "SmartPolygon2D"
const CUSTOM_TYPE_BASE := "Polygon2D"
const CUSTOM_TYPE_SCRIPT: Script = preload("res://addons/smart_polygon/smart_polygon_2d.gd")
const CUSTOM_TYPE_ICON: Texture2D = preload("res://icon.svg")


func _enter_tree() -> void:
	# Register the custom node type so it appears in the editor's Create Node dialog.
	add_custom_type(CUSTOM_TYPE_NAME, CUSTOM_TYPE_BASE, CUSTOM_TYPE_SCRIPT, CUSTOM_TYPE_ICON)


func _exit_tree() -> void:
	# Remove the custom type when the plugin is disabled to keep the editor registry clean.
	remove_custom_type(CUSTOM_TYPE_NAME)
