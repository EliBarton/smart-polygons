# AI Polygon Assembler & SmartPolygon2D Architecture

## Project Overview
We are building a procedural Godot 4 Editor toolset that allows users to type a prompt in the editor, which an LLM processes to automatically assemble 2D vector art using a custom parametric node. 

The system consists of two Godot editor plugins:
1.  **SmartPolygon2D**: A custom `@tool` node extending `Polygon2D` that generates complex `PackedVector2Array` shapes based on simple exported parameters (shape_type, size, color, etc.).
2.  **AI Assembler Dock**: An editor dock with a text input and button. It sends a prompt to an LLM API, receives a JSON schema of shapes, and procedurally builds `SmartPolygon2D` nodes into the active scene.

## Strict Godot 4 Guidelines
*   Always use Godot 4 GDScript syntax.
*   Use `@export` instead of `export`.
*   Use `await` instead of `yield()`.
*   When a tool script adds nodes to the editor scene tree, you MUST set `node.owner = EditorInterface.get_edited_scene_root()` for the node to be visible and saved in the scene.
*   Always use static typing where possible (e.g., `var my_node: Node2D = Node2D.new()`).

## Component 1: SmartPolygon2D
*   **Path**: `res://addons/smart_polygon/`
*   **Properties**: 
    *   `shape_type` (Enum: RECTANGLE, CIRCLE, STAR, CAPSULE)
    *   `size` (Vector2)
    *   `resolution` (int)
    *   `star_inner_radius` (float)
*   **Behavior**: When parameters change, recalculate the `polygon` property.

## Component 2: AI Assembler Dock
*   **Path**: `res://addons/ai_assembler/`
*   **UI**: A VBoxContainer with a `TextEdit` for the prompt, an `OptionButton` to select the LLM provider (OpenAI or Gemini), a `LineEdit` for the API Key, and a `Button` to generate.
*   **LLM JSON Output Schema Required**:
```json
    {
      "nodes": [
        { "name": "String", "type": int, "size_x": float, "size_y": float, "color": "hex_string", "pos_x": float, "pos_y": float }
      ]
    }
    ```
*   **Behavior**: Parse the JSON array, instantiate `SmartPolygon2D` nodes, apply the properties, and add them as children of a new `Node2D` container in the currently edited scene.