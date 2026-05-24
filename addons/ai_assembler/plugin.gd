@tool
extends EditorPlugin

const DOCK_SCENE: PackedScene = preload("res://addons/ai_assembler/ai_assembler_dock.tscn")

var _dock: Control


func _enter_tree() -> void:
	# The dock scene owns the request UI and the parser; the plugin only mounts it into the editor.
	_dock = DOCK_SCENE.instantiate() as Control
	if _dock == null:
		push_error("AI Assembler dock scene did not instantiate as a Control.")
		return

	if _dock.has_method("set_editor_interface"):
		_dock.call("set_editor_interface", get_editor_interface())

	if not scene_changed.is_connected(_on_scene_changed):
		scene_changed.connect(_on_scene_changed)

	add_control_to_dock(DOCK_SLOT_RIGHT_UL, _dock)
	_on_scene_changed(get_editor_interface().get_edited_scene_root())


func _exit_tree() -> void:
	if scene_changed.is_connected(_on_scene_changed):
		scene_changed.disconnect(_on_scene_changed)

	if _dock != null:
		remove_control_from_docks(_dock)
		_dock.queue_free()
		_dock = null


func _on_scene_changed(scene_root: Node) -> void:
	if _dock != null and _dock.has_method("set_scene_root"):
		_dock.call("set_scene_root", scene_root)
