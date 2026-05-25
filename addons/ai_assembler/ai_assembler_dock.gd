@tool
extends VBoxContainer


const SMART_POLYGON_SCRIPT: Script = preload("res://addons/smart_polygon/smart_polygon_2d.gd")
const OPENAI_ENDPOINT := "https://api.openai.com/v1/chat/completions"
const GEMINI_ENDPOINT_TEMPLATE := "https://generativelanguage.googleapis.com/v1beta/models/%s:generateContent?key=%s"
const GENERATED_CONTAINER_NAME := "AI_Generated_Shapes"
const API_KEY_CONFIG_PATH := "user://ai_assembler.cfg"
const API_KEY_CONFIG_SECTION := "credentials"
const API_KEY_CONFIG_KEY := "api_key"
const MODEL_CONFIG_SECTION := "models"
const OPENAI_MODEL_CONFIG_KEY := "openai_model"
const GEMINI_MODEL_CONFIG_KEY := "gemini_model"
const FAST_REQUEST_TIMEOUT := 180.0
const SLOW_REQUEST_TIMEOUT := 600.0
const SHAPE_RECTANGLE := 0
const SHAPE_CIRCLE := 1
const SHAPE_STAR := 2
const SHAPE_CAPSULE := 3
const SHAPE_TRIANGLE := 4

enum Provider {
	OPENAI = 0,
	GEMINI = 1,
}

const DEFAULT_MODEL_IDS := {
	Provider.OPENAI: "gpt-5.4-mini",
	Provider.GEMINI: "gemini-2.5-flash",
}

const MODEL_CATALOG := {
	Provider.OPENAI: [
		{"label": "GPT-5.4 Mini", "model_id": "gpt-5.4-mini"},
		{"label": "GPT-5.5", "model_id": "gpt-5.5"},
		{"label": "GPT-5.4 Nano", "model_id": "gpt-5.4-nano"},
	],
	Provider.GEMINI: [
		{"label": "Gemini 3.5 Flash", "model_id": "gemini-3.5-flash"},
		{"label": "Gemini 3.1 Pro", "model_id": "gemini-3.1-pro-preview"},
		{"label": "Gemini 2.5 Flash", "model_id": "gemini-2.5-flash"},
		{"label": "Gemini 2.5 Pro", "model_id": "gemini-2.5-pro"},
		{"label": "Gemini 3 Pro Preview", "model_id": "gemini-3-pro-preview"},
	],
}


var editor_interface: EditorInterface
var _scene_root: Node
var _generated_container: Node2D
var _request_in_flight := false
var _active_request_timeout := FAST_REQUEST_TIMEOUT
var _last_user_prompt: String = ""
var _pending_provider_id := Provider.OPENAI
var _pending_previous_container: Node2D
var _pending_container_name: String = GENERATED_CONTAINER_NAME
var _pending_existing_json: String = ""
var _pending_edit_mode := false


@onready var prompt_text_edit: TextEdit = $PromptTextEdit
@onready var provider_option_button: OptionButton = $ProviderOptionButton
@onready var model_option_button: OptionButton = $ModelOptionButton
@onready var api_key_line_edit: LineEdit = $ApiKeyLineEdit
@onready var generate_button: Button = $GenerateButton
@onready var status_label: Label = $StatusLabel
@onready var generate_request: HTTPRequest = $GenerateRequest


func set_editor_interface(value: EditorInterface) -> void:
	editor_interface = value
	_update_scene_state()


func set_scene_root(value: Node) -> void:
	_scene_root = value
	_update_scene_state()


func _ready() -> void:
	# Configure the dock controls once the scene is live so the plugin can safely reuse the scene at any time.
	_configure_ui()
	_load_preferences()
	_wire_signals()
	_update_scene_state()


func _configure_ui() -> void:
	prompt_text_edit.placeholder_text = "Describe the scene you want the LLM to assemble."
	prompt_text_edit.custom_minimum_size = Vector2(0.0, 180.0)
	prompt_text_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY

	provider_option_button.clear()
	provider_option_button.add_item("OpenAI", Provider.OPENAI)
	provider_option_button.add_item("Gemini", Provider.GEMINI)
	provider_option_button.selected = 0
	provider_option_button.fit_to_longest_item = true

	model_option_button.clear()
	model_option_button.allow_reselect = true
	model_option_button.fit_to_longest_item = true
	_populate_model_options(provider_option_button.get_selected_id(), DEFAULT_MODEL_IDS.get(Provider.OPENAI, "gpt-5.4-mini"))

	api_key_line_edit.placeholder_text = "OpenAI or Gemini API key"
	api_key_line_edit.secret = true
	api_key_line_edit.clear_button_enabled = true

	generate_button.text = "Generate"
	generate_button.disabled = false

	status_label.text = "Ready."
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART

	generate_request.use_threads = true
	generate_request.timeout = FAST_REQUEST_TIMEOUT


func _update_scene_state() -> void:
	if editor_interface == null:
		return

	if generate_button == null or status_label == null:
		return

	if _scene_root == null or not is_instance_valid(_scene_root):
		_scene_root = editor_interface.get_edited_scene_root()

	var has_scene := _scene_root != null and is_instance_valid(_scene_root)
	generate_button.disabled = _request_in_flight or not has_scene

	if not has_scene:
		_set_status("Open or create a scene before generating.")
	elif status_label.text == "Open or create a scene before generating.":
		_set_status("Ready.")


func _wire_signals() -> void:
	if not generate_button.pressed.is_connected(_on_generate_button_pressed):
		generate_button.pressed.connect(_on_generate_button_pressed)

	if not generate_request.request_completed.is_connected(_on_request_completed):
		generate_request.request_completed.connect(_on_request_completed)

	if not provider_option_button.item_selected.is_connected(_on_provider_option_selected):
		provider_option_button.item_selected.connect(_on_provider_option_selected)

	if not model_option_button.item_selected.is_connected(_on_model_option_selected):
		model_option_button.item_selected.connect(_on_model_option_selected)

	if not api_key_line_edit.text_changed.is_connected(_on_api_key_text_changed):
		api_key_line_edit.text_changed.connect(_on_api_key_text_changed)


func _on_provider_option_selected(index: int) -> void:
	var provider_id := provider_option_button.get_item_id(index)
	var saved_model_id := _get_saved_model_id(provider_id)
	_populate_model_options(provider_id, saved_model_id)


func _on_model_option_selected(index: int) -> void:
	var provider_id := provider_option_button.get_selected_id()
	var model_id := _get_model_id_at_index(index)
	if model_id.is_empty():
		return

	_save_model_selection(provider_id, model_id)


func _on_generate_button_pressed() -> void:
	if editor_interface == null:
		_set_status("The editor interface is not available.")
		return

	if _request_in_flight:
		_set_status("A request is already in flight.")
		return

	_update_scene_state()
	if _scene_root == null or not is_instance_valid(_scene_root):
		_set_status("Open or create a scene before generating.")
		return

	var api_key := api_key_line_edit.text.strip_edges()
	if api_key.is_empty():
		_set_status("Enter an API key before generating.")
		return

	var user_prompt := prompt_text_edit.text.strip_edges()
	if user_prompt.is_empty():
		_set_status("Enter a scene prompt first.")
		return

	_last_user_prompt = user_prompt
	_clear_pending_generation_context()

	var selection_container := _get_round_trip_container_from_selection()
	var existing_json_state := ""
	if selection_container != null:
		existing_json_state = _serialize_existing_container(selection_container)
		if existing_json_state.is_empty():
			selection_container = null

	if selection_container != null:
		_pending_previous_container = selection_container
		_pending_container_name = str(selection_container.name)
		_pending_existing_json = existing_json_state
		_pending_edit_mode = true
	elif _generated_container != null and is_instance_valid(_generated_container):
		_pending_previous_container = _generated_container
		_pending_container_name = str(_generated_container.name)
	else:
		_pending_container_name = GENERATED_CONTAINER_NAME

	var provider_id := provider_option_button.get_selected_id()
	_pending_provider_id = provider_id
	var model_id := _get_selected_model_id(provider_id)
	_active_request_timeout = _request_timeout_for_model(model_id)
	generate_request.timeout = _active_request_timeout
	var request_url := ""
	var request_headers := PackedStringArray(["Content-Type: application/json"])
	var request_body := ""

	match provider_id:
		Provider.GEMINI:
			request_url = _build_gemini_request_url(api_key, model_id)
			request_body = _build_gemini_request_body(user_prompt, _pending_existing_json)
		_:
			request_url = OPENAI_ENDPOINT
			request_headers.append("Authorization: Bearer %s" % api_key)
			request_body = _build_openai_request_body(user_prompt, model_id, _pending_existing_json)

	_request_in_flight = true
	generate_button.disabled = true
	_set_status("Sending request to %s..." % _provider_name(provider_id))

	var error := generate_request.request(request_url, request_headers, HTTPClient.METHOD_POST, request_body)
	if error != OK:
		_request_in_flight = false
		generate_button.disabled = false
		_clear_pending_generation_context()
		_set_status("Failed to start request: %s" % error_string(error))


func _load_preferences() -> void:
	var config := _load_preferences_config()
	api_key_line_edit.text = str(config.get_value(API_KEY_CONFIG_SECTION, API_KEY_CONFIG_KEY, ""))
	_apply_saved_model_selection(config)


func _save_api_key(api_key: String) -> void:
	_save_config_value(API_KEY_CONFIG_SECTION, API_KEY_CONFIG_KEY, api_key)


func _save_model_selection(provider_id: int, model_id: String) -> void:
	_save_config_value(MODEL_CONFIG_SECTION, _model_config_key(provider_id), model_id)


func _save_config_value(section: String, key: String, value: Variant) -> void:
	var config := _load_preferences_config()
	config.set_value(section, key, value)
	var error := config.save(API_KEY_CONFIG_PATH)
	if error != OK:
		push_warning("Failed to save the AI Assembler preferences: %s" % error_string(error))


func _load_preferences_config() -> ConfigFile:
	var config := ConfigFile.new()
	var error := config.load(API_KEY_CONFIG_PATH)
	if error != OK and error != ERR_FILE_NOT_FOUND:
		push_warning("Failed to load the AI Assembler preferences: %s" % error_string(error))
	return config


func _on_api_key_text_changed(new_text: String) -> void:
	_save_api_key(new_text)


func _apply_saved_model_selection(config: ConfigFile) -> void:
	var provider_id := provider_option_button.get_selected_id()
	var saved_model_id := str(config.get_value(MODEL_CONFIG_SECTION, _model_config_key(provider_id), _default_model_id_for_provider(provider_id)))
	_populate_model_options(provider_id, saved_model_id)


func _populate_model_options(provider_id: int, preferred_model_id: String = "") -> void:
	model_option_button.clear()

	var model_entries: Array = MODEL_CATALOG.get(provider_id, [])
	for model_entry_variant in model_entries:
		if model_entry_variant is not Dictionary:
			continue

		var model_entry := model_entry_variant as Dictionary
		var model_label := str(model_entry.get("label", "Model"))
		var model_id := str(model_entry.get("model_id", ""))
		if model_id.is_empty():
			continue

		model_option_button.add_item(model_label)
		var item_index := model_option_button.item_count - 1
		model_option_button.set_item_metadata(item_index, model_id)

	var model_to_select := preferred_model_id
	if model_to_select.is_empty():
		model_to_select = _default_model_id_for_provider(provider_id)

	var selected_index := _find_model_index(model_to_select)
	if selected_index == -1 and model_option_button.item_count > 0:
		selected_index = 0

	if selected_index != -1:
		model_option_button.select(selected_index)


func _find_model_index(model_id: String) -> int:
	for item_index in range(model_option_button.item_count):
		var item_metadata := model_option_button.get_item_metadata(item_index)
		if str(item_metadata) == model_id:
			return item_index

	return -1


func _get_model_id_at_index(index: int) -> String:
	if index < 0 or index >= model_option_button.item_count:
		return ""

	return str(model_option_button.get_item_metadata(index))


func _get_selected_model_id(provider_id: int) -> String:
	var selected_index := model_option_button.get_selected()
	var selected_model_id := _get_model_id_at_index(selected_index)
	if not selected_model_id.is_empty():
		return selected_model_id

	return _default_model_id_for_provider(provider_id)


func _default_model_id_for_provider(provider_id: int) -> String:
	return str(DEFAULT_MODEL_IDS.get(provider_id, "gpt-5.4-mini"))


func _model_config_key(provider_id: int) -> String:
	match provider_id:
		Provider.GEMINI:
			return GEMINI_MODEL_CONFIG_KEY
		_:
			return OPENAI_MODEL_CONFIG_KEY


func _get_saved_model_id(provider_id: int) -> String:
	var config := _load_preferences_config()
	return str(config.get_value(MODEL_CONFIG_SECTION, _model_config_key(provider_id), _default_model_id_for_provider(provider_id)))


func _clear_pending_generation_context() -> void:
	_pending_provider_id = Provider.OPENAI
	_pending_previous_container = null
	_pending_container_name = GENERATED_CONTAINER_NAME
	_pending_existing_json = ""
	_pending_edit_mode = false


func _get_round_trip_container_from_selection() -> Node2D:
	if editor_interface == null:
		return null

	var selection := editor_interface.get_selection()
	if selection == null:
		return null

	var selected_nodes := selection.get_selected_nodes()
	if selected_nodes.size() != 1:
		return null

	var selected_node := selected_nodes[0]
	if not (selected_node is Node2D):
		return null

	var container := selected_node as Node2D
	if container == null or not _has_smart_polygon_children(container):
		return null

	return container


func _has_smart_polygon_children(container: Node2D) -> bool:
	if container == null:
		return false

	for child in container.get_children():
		if child is SmartPolygon2D:
			return true

	return false


func _serialize_existing_container(container: Node2D) -> String:
	if container == null:
		return ""

	var nodes_array: Array[Dictionary] = []

	for child in container.get_children():
		if not (child is SmartPolygon2D):
			continue

		var polygon_child := child as SmartPolygon2D
		if polygon_child == null:
			continue

		var node_spec := {
			"name": str(polygon_child.name),
			"type": int(polygon_child.shape_type),
			"size_x": snappedf(polygon_child.size.x, 0.1),
			"size_y": snappedf(polygon_child.size.y, 0.1),
			"pivot_offset_x": snappedf(polygon_child.pivot_offset.x, 0.1),
			"pivot_offset_y": snappedf(polygon_child.pivot_offset.y, 0.1),
			"rotation": snappedf(polygon_child.rotation_degrees, 0.1),
			"resolution": int(polygon_child.resolution),
			"star_inner_radius": snappedf(polygon_child.star_inner_radius, 0.01),
			"color": "#" + polygon_child.color.to_html(false),
			"pos_x": snappedf(polygon_child.position.x, 0.1),
			"pos_y": snappedf(polygon_child.position.y, 0.1),
		}
		nodes_array.append(node_spec)

	var payload := {"nodes": nodes_array}
	return JSON.stringify(payload, "\t")


func _build_nodes_from_spec(node_specs: Array[Dictionary]) -> Array[Node]:
	var new_nodes: Array[Node] = []

	for node_spec in node_specs:
		var polygon_node := _instantiate_smart_polygon(node_spec)
		if polygon_node != null:
			new_nodes.append(polygon_node)

	return new_nodes


func _copy_node2d_state(source_node: Node2D, target_node: Node2D) -> void:
	if source_node == null or target_node == null:
		return

	target_node.position = source_node.position
	target_node.rotation_degrees = source_node.rotation_degrees
	target_node.scale = source_node.scale
	target_node.skew = source_node.skew
	target_node.visible = source_node.visible
	target_node.z_index = source_node.z_index
	target_node.z_as_relative = source_node.z_as_relative


func _clear_editor_selection() -> void:
	if editor_interface == null:
		return

	var selection := editor_interface.get_selection()
	if selection != null:
		selection.clear()


func _focus_editor_selection(node: Node) -> void:
	if editor_interface == null or node == null or not is_instance_valid(node):
		return

	var selection := editor_interface.get_selection()
	if selection == null:
		return

	selection.clear()
	selection.add_node(node)


func _on_request_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	_request_in_flight = false
	_update_scene_state()

	var previous_container: Node2D = null
	if is_instance_valid(_pending_previous_container):
		previous_container = _pending_previous_container
	var generated_container_name := _pending_container_name
	var provider_id := _pending_provider_id
	var pending_edit_mode := _pending_edit_mode
	_clear_pending_generation_context()

	if result != HTTPRequest.RESULT_SUCCESS:
		if result == HTTPRequest.RESULT_TIMEOUT:
			_set_status("The request timed out after %.0f seconds. Try a faster model or increase the timeout." % _active_request_timeout)
		else:
			_set_status("The HTTP request failed before a response was received.")
		return

	var response_text := body.get_string_from_utf8()
	var response_payload := JSON.parse_string(response_text)
	if response_payload == null:
		_set_status("The provider returned invalid JSON.")
		push_error("AI Assembler could not parse the response body: %s" % response_text)
		return

	if response_code < 200 or response_code >= 300:
		var error_message := _extract_error_message(response_payload)
		_set_status("The provider rejected the request: %s" % error_message)
		push_error(error_message)
		return

	var schema_text := _extract_schema_text(response_payload, provider_id)
	if schema_text.is_empty():
		_set_status("The model response did not contain a JSON schema payload.")
		push_error("Missing schema content in provider response.")
		return

	var schema_payload := JSON.parse_string(schema_text)
	if schema_payload == null or typeof(schema_payload) != TYPE_DICTIONARY:
		_set_status("The generated JSON schema was not valid.")
		push_error("Invalid schema payload: %s" % schema_text)
		return

	var node_specs := _extract_node_specs(schema_payload)
	if node_specs.is_empty():
		_set_status("The schema contained no nodes to build.")
		return

	if not pending_edit_mode:
		node_specs = _filter_subject_nodes(node_specs, _last_user_prompt)

	var scene_root := editor_interface.get_edited_scene_root()
	if scene_root == null:
		_set_status("Open or create a scene before applying generated nodes.")
		return

	var target_container: Node2D = previous_container
	var container_was_created := false
	if target_container == null:
		target_container = Node2D.new()
		target_container.name = generated_container_name
		target_container.position = Vector2.ZERO
		container_was_created = true
	elif str(target_container.name).is_empty():
		target_container.name = generated_container_name

	var old_children: Array[Node] = []
	for child in target_container.get_children():
		if child is Node:
			old_children.append(child)

	var new_children := _build_nodes_from_spec(node_specs)
	if new_children.is_empty():
		_set_status("Failed to build the generated node tree.")
		return

	var undo_redo = editor_interface.get_editor_undo_redo()
	var action_name := "Edit Smart Polygon Shapes" if pending_edit_mode else "Generate Smart Polygon Shapes"
	undo_redo.create_action(action_name)
	undo_redo.add_do_reference(target_container)
	undo_redo.add_undo_reference(target_container)
	for old_child in old_children:
		undo_redo.add_do_reference(old_child)
		undo_redo.add_undo_reference(old_child)
	for new_child in new_children:
		undo_redo.add_do_reference(new_child)
		undo_redo.add_undo_reference(new_child)

	undo_redo.add_do_method(self, "_apply_generated_nodes", target_container, scene_root, old_children, new_children, container_was_created)
	undo_redo.add_undo_method(self, "_restore_generated_nodes", target_container, scene_root, old_children, new_children, container_was_created)
	_clear_editor_selection()
	undo_redo.commit_action()

	_generated_container = target_container
	call_deferred("_focus_editor_selection", target_container)
	_set_status("Generated %d node(s) into the edited scene." % node_specs.size())


func _build_openai_request_body(user_text: String, model_id: String, existing_json: String = "") -> String:
	var payload := {
		"model": model_id,
		"temperature": 0.2,
		"response_format": {"type": "json_object"},
		"messages": [
			{
				"role": "system",
				"content": "You are a strict JSON generator for a Godot 4 editor plugin. Always follow the user instructions exactly. Do not rely on downstream correction; output the final layout, pose, pivots, and shapes directly in JSON."
			},
			{
				"role": "user",
				"content": _construct_prompt(user_text, existing_json)
			},
		],
	}
	return JSON.stringify(payload)


func _build_gemini_request_url(api_key: String, model_id: String) -> String:
	return GEMINI_ENDPOINT_TEMPLATE % [model_id, api_key]


func _request_timeout_for_model(model_id: String) -> float:
	var normalized_model_id := model_id.to_lower()
	if normalized_model_id.find("pro") != -1 or normalized_model_id.find("5.5") != -1:
		return SLOW_REQUEST_TIMEOUT

	return FAST_REQUEST_TIMEOUT


func _build_gemini_request_body(user_text: String, existing_json: String = "") -> String:
	var payload := {
		"generationConfig": {
			"temperature": 0.2,
			"responseMimeType": "application/json",
		},
		"contents": [
			{
				"role": "user",
				"parts": [
					{
						"text": _construct_prompt(user_text, existing_json),
					}
				],
			},
		],
	}
	return JSON.stringify(payload)


func _construct_prompt(user_text: String, existing_json: String = "") -> String:
	# The model is deliberately constrained to emit only the schema we can safely parse.
	var prompt_text := """
You are generating data for a Godot 4 editor tool that assembles 2D vector art.

Return ONLY a single valid JSON object. Do not include markdown, code fences, explanations, or extra keys outside the schema.

The JSON schema must be exactly:
{
	"nodes": [
		{
			"name": "String",
			"type": 0,
			"rotation": 0.0,
			"size_x": 128.0,
			"size_y": 128.0,
			"pivot_offset_x": 0.0,
			"pivot_offset_y": 0.0,
			"resolution": 16,
			"star_inner_radius": 0.5,
			"color": "#RRGGBB",
			"pos_x": 0.0,
			"pos_y": 0.0
		}
	]
}

Shape type integers are fixed:
- 0 = RECTANGLE
- 1 = CIRCLE
- 2 = STAR
- 3 = CAPSULE
- 4 = TRIANGLE

Rules:
- Output JSON only.
- Use numeric values for size, position, and pivot offset fields.
- Use numeric degrees for rotation, where 0.0 means no rotation.
- Order the nodes array from back to front so earlier nodes draw behind later nodes.
- Layering matters: build the background, then the body, then front-facing parts like faces, jaws, hands, and details.
- For posed characters, rotate limbs and necks in the JSON instead of relying on editor-side correction.
- Keep names short, readable, and valid as scene node names.
- The output must contain only the requested character or object, isolated in empty space.
- Do not create background, floor, ground plane, horizon, sky, room, stage, shadow, lighting, or other environment details.
- If the prompt describes a character, keep it in a neutral blind pose suitable for animation and posing.
- Prefer a T-pose or A-pose when anatomy allows it, with separated limbs and no environment.
- If the prompt describes an object, keep it centered and isolated, with no scene props.
- If the design needs no shapes, return {"nodes": []}.
- Use rectangles only when they are necessary parts of the subject.
- If a node name or prompt implies a role like Head, Eye, Arm, Leg, Torso, Limb, or Body, choose the matching shape instead of a rectangle.
- Use circles for heads, eyes, buttons, dots, or rounded body parts.
- Use capsules for limbs, connectors, beams, pipes, bodies, and other elongated forms.
- Use triangles for arrows, spikes, mountains, roofs, shards, and directional accents.
- Do not use stars unless the prompt explicitly asks for stars or decorative star-like details.
- For humanoid or bipedal characters, build a strict blind pose in the JSON itself instead of relying on editor-side corrections.
- Place the torso centered on the character's root.
- Place the head above the torso.
- Place arms horizontally from the shoulders in a true T-pose unless the prompt explicitly asks for a different pose.
- Place legs vertically beneath the hips, with feet aligned to the lower ends of the legs.
- For limbs and articulated parts, set pivot_offset so the joint stays anchored while the geometry extends away from the body.
- When pivot_offset is used, keep pos_x and pos_y at the actual joint or attachment point. Do not also shift position by half the shape size to compensate for pivot_offset.
- For capsule limbs, a common pivot_offset is [size_x / 2, 0] for left-facing parts and [-size_x / 2, 0] for right-facing parts.
- For vertical leg segments, a common pivot_offset is [0, -size_y / 2] so the joint sits at the top edge.
- The editor plugin does not apply humanoid pose correction after generation, so the JSON must already contain the final layout.
- For multi-node subjects, keep the node set focused on the subject anatomy or object parts only.
- Prefer more complex shapes when they improve the composition, especially capsules and triangles.
- Use triangles for spikes, arrows, accents, and details that would be difficult to achieve with circles or rectangles, especially when conveying sharp points.

"""

	if not existing_json.is_empty():
		prompt_text += """
CURRENT ASSET STATE:
The user wants to modify an existing asset. Here is the current JSON schema of the asset:
%s

INSTRUCTIONS FOR EDITING:
Modify the JSON above to fulfill the user's request.
- You may change sizes, colors, rotations, positions, pivot offsets, resolutions, and star inner radii of existing nodes.
- You may add new nodes or delete nodes if necessary.
- Keep the names of unmodified nodes exactly the same.
- Return the full updated JSON object, not a diff.
""" % existing_json

	prompt_text += """
USER REQUEST:
%s
""" % user_text
	return prompt_text


func _extract_schema_text(response_payload: Variant, provider_id: int) -> String:
	if typeof(response_payload) != TYPE_DICTIONARY:
		return ""

	var response_dictionary := response_payload as Dictionary
	if response_dictionary.has("nodes"):
		return JSON.stringify(response_dictionary)

	match provider_id:
		Provider.GEMINI:
			return _extract_gemini_schema_text(response_dictionary)
		_:
			return _extract_openai_schema_text(response_dictionary)


func _extract_openai_schema_text(response_dictionary: Dictionary) -> String:
	if response_dictionary.has("choices"):
		var choices = response_dictionary["choices"]
		if choices is Array and not choices.is_empty():
			var first_choice = choices[0]
			if first_choice is Dictionary:
				var message := (first_choice as Dictionary).get("message", {})
				if message is Dictionary:
					var content := (message as Dictionary).get("content", "")
					return _extract_json_object_text(str(content))

	if response_dictionary.has("output_text"):
		return _extract_json_object_text(str(response_dictionary["output_text"]))

	return ""


func _extract_gemini_schema_text(response_dictionary: Dictionary) -> String:
	if response_dictionary.has("candidates"):
		var candidates = response_dictionary["candidates"]
		if candidates is Array and not candidates.is_empty():
			var first_candidate = candidates[0]
			if first_candidate is Dictionary:
				var content := (first_candidate as Dictionary).get("content", {})
				if content is Dictionary:
					var parts := (content as Dictionary).get("parts", [])
					if parts is Array:
						var text_segments: Array[String] = []
						for part in parts:
							if part is Dictionary:
								var text := str((part as Dictionary).get("text", ""))
								if not text.is_empty():
									text_segments.append(text)
						return _extract_json_object_text("\n".join(text_segments))

	return ""


func _extract_json_object_text(raw_text: String) -> String:
	var start_index := raw_text.find("{")
	var end_index := raw_text.rfind("}")
	if start_index == -1 or end_index == -1 or end_index <= start_index:
		return ""
	return raw_text.substr(start_index, end_index - start_index + 1).strip_edges()


func _extract_error_message(response_payload: Variant) -> String:
	if typeof(response_payload) != TYPE_DICTIONARY:
		return "The provider returned an error response."

	var response_dictionary := response_payload as Dictionary
	if response_dictionary.has("error"):
		var error_value = response_dictionary["error"]
		if error_value is Dictionary:
			var message := str((error_value as Dictionary).get("message", "The provider returned an error response."))
			if not message.is_empty():
				return message

	return "The provider returned an error response."


func _extract_node_specs(schema_payload: Dictionary) -> Array[Dictionary]:
	var node_specs: Array[Dictionary] = []
	var raw_nodes := schema_payload.get("nodes", [])
	if raw_nodes is not Array:
		return node_specs

	var raw_node_array := raw_nodes as Array
	var used_names := {}

	for index in range(raw_node_array.size()):
		var raw_node = raw_node_array[index]
		if raw_node is Dictionary:
			var normalized_spec := _normalize_node_spec(raw_node as Dictionary, index, used_names)
			node_specs.append(normalized_spec)

	return node_specs


func _filter_subject_nodes(node_specs: Array[Dictionary], user_prompt: String) -> Array[Dictionary]:
	var prompt_text := user_prompt.strip_edges().to_lower()
	var wants_star_details := _contains_any(prompt_text, ["star", "burst", "spark", "badge", "accent", "ornament"])
	var filtered: Array[Dictionary] = []

	for node_spec in node_specs:
		var node_name := str(node_spec.get("name", "")).to_lower()
		if _is_environment_node(node_name):
			continue

		if not wants_star_details and _contains_any(node_name, ["star", "burst", "spark", "badge", "accent", "ornament", "asterisk"]):
			continue

		filtered.append(node_spec)

	if filtered.is_empty():
		return node_specs

	return filtered


func _is_environment_node(node_name: String) -> bool:
	var keywords := ["background", "bg", "floor", "ground", "groundplane", "ground_plane", "horizon", "sky", "scene", "room", "stage", "shadow", "lighting", "light", "sun", "moon", "cloud", "tree", "grass", "terrain", "landscape", "wall", "pedestal", "platform", "stand"]

	return _contains_any(node_name, keywords)


func _vector2_from_value(value: Variant, fallback: Vector2) -> Vector2:
	if value is Vector2:
		return value

	if value is Array and value.size() >= 2:
		return Vector2(float(value[0]), float(value[1]))

	if value is Dictionary:
		if value.has("x") or value.has("y"):
			return Vector2(float(value.get("x", fallback.x)), float(value.get("y", fallback.y)))

	return fallback


func _contains_any(source_text: String, keywords: Array) -> bool:
	for keyword in keywords:
		if source_text.find(keyword) != -1:
			return true

	return false


func _normalize_node_spec(raw_node: Dictionary, index: int, used_names: Dictionary) -> Dictionary:
	var shape_type := _shape_type_from_value(raw_node.get("type", SHAPE_RECTANGLE))
	var rotation_degrees := float(raw_node.get("rotation", 0.0))
	var width := float(raw_node.get("size_x", 128.0))
	var height := float(raw_node.get("size_y", 128.0))
	var color := _parse_color(raw_node.get("color", "#ffffff"))
	var position := Vector2(float(raw_node.get("pos_x", 0.0)), float(raw_node.get("pos_y", 0.0)))
	var pivot_offset := Vector2(float(raw_node.get("pivot_offset_x", 0.0)), float(raw_node.get("pivot_offset_y", 0.0)))
	if raw_node.has("pivot_offset"):
		pivot_offset = _vector2_from_value(raw_node.get("pivot_offset"), pivot_offset)
	var name := _make_unique_node_name(str(raw_node.get("name", "")), index, used_names)
	var star_inner_radius := clampf(float(raw_node.get("star_inner_radius", 0.5)), 0.0, 0.95)

	return {
		"name": name,
		"shape_type": shape_type,
		"rotation_degrees": rotation_degrees,
		"size": Vector2(width, height),
		"color": color,
		"position": position,
		"pivot_offset": pivot_offset,
		"star_inner_radius": star_inner_radius,
	}


func _shape_type_from_value(raw_value: Variant) -> int:
	if raw_value is int or raw_value is float:
		return clampi(int(roundf(float(raw_value))), SHAPE_RECTANGLE, SHAPE_TRIANGLE)

	var value_text := str(raw_value).strip_edges().to_upper()
	match value_text:
		"RECTANGLE":
			return SHAPE_RECTANGLE
		"CIRCLE":
			return SHAPE_CIRCLE
		"STAR":
			return SHAPE_STAR
		"CAPSULE":
			return SHAPE_CAPSULE
		"TRIANGLE":
			return SHAPE_TRIANGLE
		_:
			if value_text.is_valid_float():
				return clampi(int(roundf(float(value_text))), SHAPE_RECTANGLE, SHAPE_TRIANGLE)
			return SHAPE_RECTANGLE


func _parse_color(raw_value: Variant) -> Color:
	var color_text := str(raw_value).strip_edges()
	if color_text.is_empty():
		return Color.WHITE

	return Color.from_string(color_text, Color.WHITE)


func _make_unique_node_name(raw_name: String, index: int, used_names: Dictionary) -> String:
	var sanitized_name := _sanitize_node_name(raw_name)
	if sanitized_name.is_empty():
		sanitized_name = "Shape_%d" % index

	var unique_name := sanitized_name
	var suffix := 2
	while used_names.has(unique_name):
		unique_name = "%s_%d" % [sanitized_name, suffix]
		suffix += 1

	used_names[unique_name] = true
	return unique_name


func _sanitize_node_name(raw_name: String) -> String:
	var cleaned := String()
	for character_index in range(raw_name.length()):
		var character := raw_name.substr(character_index, 1)
		if _is_valid_node_name_character(character):
			cleaned += character
		else:
			cleaned += "_"

	cleaned = cleaned.strip_edges()
	while cleaned.find("__") != -1:
		cleaned = cleaned.replace("__", "_")

	if cleaned.is_empty():
		return cleaned

	var first_character := cleaned.substr(0, 1)
	if first_character.is_valid_int():
		cleaned = "Shape_%s" % cleaned

	return cleaned.left(64)


func _is_valid_node_name_character(character: String) -> bool:
	return (character >= "a" and character <= "z") or (character >= "A" and character <= "Z") or (character >= "0" and character <= "9") or character == "_"


func _create_generated_content(node_specs: Array[Dictionary], container_name: String) -> Node2D:
	var container := Node2D.new()
	container.name = container_name
	container.position = Vector2.ZERO

	for node_spec in node_specs:
		var polygon_node := _instantiate_smart_polygon(node_spec)
		if polygon_node == null:
			continue

		container.add_child(polygon_node)

	if container.get_child_count() == 0:
		push_warning("Generated content container was created but no SmartPolygon2D nodes were added.")

	return container


func _apply_generated_nodes(target_container: Node2D, scene_root: Node, old_children: Array, new_children: Array, container_was_created: bool) -> void:
	if target_container == null or scene_root == null:
		return

	_clear_editor_selection()

	if container_was_created and target_container.get_parent() == null:
		scene_root.add_child(target_container)
		target_container.owner = scene_root

	for old_child in old_children:
		if old_child is Node and old_child.get_parent() == target_container:
			target_container.remove_child(old_child)

	for new_child in new_children:
		if new_child is Node:
			target_container.add_child(new_child)
			_set_owner_recursive(new_child, scene_root)

	_set_owner_recursive(target_container, scene_root)
	_generated_container = target_container
	call_deferred("_focus_editor_selection", target_container)


func _restore_generated_nodes(target_container: Node2D, scene_root: Node, old_children: Array, new_children: Array, container_was_created: bool) -> void:
	if target_container == null or scene_root == null:
		return

	_clear_editor_selection()

	for new_child in new_children:
		if new_child is Node and new_child.get_parent() == target_container:
			target_container.remove_child(new_child)

	for old_child in old_children:
		if old_child is Node:
			target_container.add_child(old_child)
			_set_owner_recursive(old_child, scene_root)

	if container_was_created and target_container.get_parent() == scene_root:
		scene_root.remove_child(target_container)
		_generated_container = null
	else:
		_generated_container = target_container

	call_deferred("_focus_editor_selection", target_container if not container_was_created else null)


func _attach_container(parent: Node, container: Node2D, sibling_index: int = -1) -> void:
	if container == null or not is_instance_valid(container):
		return

	var current_parent := container.get_parent()
	if current_parent != null:
		current_parent.remove_child(container)

	var target_parent := parent
	if target_parent == null or not is_instance_valid(target_parent):
		target_parent = _get_edited_scene_root()

	if target_parent == null:
		return

	target_parent.add_child(container)
	if sibling_index >= 0 and sibling_index < target_parent.get_child_count():
		target_parent.move_child(container, sibling_index)

	_set_owner_recursive(container, _get_edited_scene_root())


func _detach_container(container: Node2D) -> void:
	if container == null or not is_instance_valid(container):
		return

	var current_parent := container.get_parent()
	if current_parent != null:
		current_parent.remove_child(container)


func _set_owner_recursive(node: Node, owner: Node) -> void:
	if node == null or not is_instance_valid(node):
		return

	node.owner = owner
	for child in node.get_children():
		if child is Node:
			_set_owner_recursive(child, owner)


func _get_edited_scene_root() -> Node:
	if editor_interface == null:
		return null

	return editor_interface.get_edited_scene_root()

func _instantiate_smart_polygon(node_spec: Dictionary) -> Polygon2D:
	var polygon_node := SMART_POLYGON_SCRIPT.new() as Polygon2D
	if polygon_node == null:
		push_error("The SmartPolygon2D script failed to instantiate.")
		return null

	polygon_node.name = str(node_spec.get("name", "Shape"))
	polygon_node.position = node_spec.get("position", Vector2.ZERO)
	polygon_node.rotation_degrees = float(node_spec.get("rotation_degrees", 0.0))
	polygon_node.color = node_spec.get("color", Color.WHITE)
	polygon_node.set("shape_type", int(node_spec.get("shape_type", SHAPE_RECTANGLE)))
	polygon_node.set("size", node_spec.get("size", Vector2(128.0, 128.0)))
	polygon_node.set("pivot_offset", node_spec.get("pivot_offset", Vector2.ZERO))
	polygon_node.set("star_inner_radius", float(node_spec.get("star_inner_radius", 0.5)))
	polygon_node.set("resolution", int(maxi(int(node_spec.get("resolution", 16)), 3)))

	return polygon_node


func _provider_name(provider_id: int) -> String:
	match provider_id:
		Provider.GEMINI:
			return "Gemini"
		_:
			return "OpenAI"


func _set_status(message: String) -> void:
	status_label.text = message
	print(message)
