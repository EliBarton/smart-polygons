@tool
class_name SmartPolygon2D
extends Polygon2D


# The shape type enum is intentionally stable because the AI assembler serializes it as an integer.
enum ShapeType {
	RECTANGLE = 0,
	CIRCLE = 1,
	STAR = 2,
	CAPSULE = 3,
	TRIANGLE = 4,
}


var _shape_type: ShapeType = ShapeType.RECTANGLE
var _size: Vector2 = Vector2(128.0, 128.0)
var _resolution: int = 16
var _star_inner_radius: float = 0.5
var _pivot_offset: Vector2 = Vector2.ZERO


@export var shape_type: ShapeType:
	get:
		return _shape_type
	set(value):
		if _shape_type == value:
			return
		_shape_type = value
		_rebuild_polygon()

@export var size: Vector2:
	get:
		return _size
	set(value):
		if _size == value:
			return
		_size = value
		_rebuild_polygon()

@export_range(3, 256, 1)
var resolution: int:
	get:
		return _resolution
	set(value):
		if _resolution == value:
			return
		_resolution = value
		_rebuild_polygon()

@export_range(0.0, 0.95, 0.01)
var star_inner_radius: float:
	get:
		return _star_inner_radius
	set(value):
		if _star_inner_radius == value:
			return
		_star_inner_radius = value
		_rebuild_polygon()

@export var pivot_offset: Vector2:
	get:
		return _pivot_offset
	set(value):
		if _pivot_offset == value:
			return
		_pivot_offset = value
		_rebuild_polygon()


func _ready() -> void:
	# Recalculate once the node is inside the tree so the editor always shows the current shape.
	_rebuild_polygon()


func _rebuild_polygon() -> void:
	# Polygon2D consumes a PackedVector2Array, so each shape generator returns a fully centered outline.
	var raw_points := _build_polygon()

	# Shift every point by the pivot offset without moving the node itself.
	if _pivot_offset != Vector2.ZERO:
		var shifted_points := PackedVector2Array()
		for point in raw_points:
			shifted_points.append(point - _pivot_offset)
		polygon = shifted_points
	else:
		polygon = raw_points


func _build_polygon() -> PackedVector2Array:
	match shape_type:
		ShapeType.CIRCLE:
			return _build_circle_polygon()
		ShapeType.STAR:
			return _build_star_polygon()
		ShapeType.CAPSULE:
			return _build_capsule_polygon()
		ShapeType.TRIANGLE:
			return _build_triangle_polygon()
		_:
			return _build_rectangle_polygon()


func _normalized_size() -> Vector2:
	# The generator works with positive dimensions only and keeps a small floor to avoid degenerate polygons.
	return Vector2(maxf(abs(size.x), 0.001), maxf(abs(size.y), 0.001))


func _build_rectangle_polygon() -> PackedVector2Array:
	var half_size: Vector2 = _normalized_size() * 0.5
	var points := PackedVector2Array()
	points.append(Vector2(-half_size.x, -half_size.y))
	points.append(Vector2(half_size.x, -half_size.y))
	points.append(Vector2(half_size.x, half_size.y))
	points.append(Vector2(-half_size.x, half_size.y))
	return points


func _build_circle_polygon() -> PackedVector2Array:
	# The circle is inscribed in the requested size, so a non-square size still produces a true circle.
	var half_size: Vector2 = _normalized_size() * 0.5
	var radius: float = minf(half_size.x, half_size.y)
	var segment_count: int = maxi(int(resolution), 3)
	var points := PackedVector2Array()

	for segment_index in range(segment_count):
		var angle := (TAU * float(segment_index) / float(segment_count)) - (PI * 0.5)
		points.append(Vector2(cos(angle) * radius, sin(angle) * radius))

	return points


func _build_star_polygon() -> PackedVector2Array:
	# Star points alternate between an outer ring and an inner ring.
	var half_size: Vector2 = _normalized_size() * 0.5
	var outer_radius: float = minf(half_size.x, half_size.y)
	var point_count: int = maxi(int(resolution), 3)
	var inner_ratio: float = clampf(star_inner_radius, 0.0, 0.99)
	var inner_radius: float = outer_radius * inner_ratio
	var points := PackedVector2Array()
	var vertex_count: int = point_count * 2

	for vertex_index in range(vertex_count):
		var use_outer_ring := vertex_index % 2 == 0
		var radius := outer_radius if use_outer_ring else inner_radius
		var angle := (-PI * 0.5) + (TAU * float(vertex_index) / float(vertex_count))
		points.append(Vector2(cos(angle) * radius, sin(angle) * radius))

	return points


func _build_capsule_polygon() -> PackedVector2Array:
	# A capsule is a rounded rectangle whose corner radius equals half of the shortest dimension.
	var normalized_size: Vector2 = _normalized_size()
	var corner_radius: float = minf(normalized_size.x, normalized_size.y) * 0.5
	var segment_count: int = maxi(int(resolution), 3)
	return _build_rounded_rectangle_polygon(normalized_size, corner_radius, segment_count)


func _build_triangle_polygon() -> PackedVector2Array:
	# The triangle is centered by its centroid so the node position remains visually stable in the editor.
	var normalized_size: Vector2 = _normalized_size()
	var half_width: float = normalized_size.x * 0.5
	var height: float = normalized_size.y
	var apex_y: float = -(height * 2.0 / 3.0)
	var base_y: float = height / 3.0
	var points := PackedVector2Array()
	points.append(Vector2(0.0, apex_y))
	points.append(Vector2(half_width, base_y))
	points.append(Vector2(-half_width, base_y))
	return points


func _build_rounded_rectangle_polygon(rect_size: Vector2, corner_radius: float, segment_count: int) -> PackedVector2Array:
	var half_size: Vector2 = rect_size * 0.5
	var radius: float = clampf(corner_radius, 0.0, minf(half_size.x, half_size.y))

	if radius <= 0.0:
		return _build_rectangle_polygon()

	# The outline is traced clockwise from the top edge of the top-right corner.
	# Each corner arc contributes a smooth quarter-circle, and the straight edges are implicit between arc endpoints.
	var top := -half_size.y
	var bottom := half_size.y
	var left := -half_size.x
	var right := half_size.x

	var points := PackedVector2Array()
	_append_arc(points, Vector2(right - radius, top + radius), radius, -PI * 0.5, 0.0, segment_count)
	_append_arc(points, Vector2(right - radius, bottom - radius), radius, 0.0, PI * 0.5, segment_count, true)
	_append_arc(points, Vector2(left + radius, bottom - radius), radius, PI * 0.5, PI, segment_count, true)
	_append_arc(points, Vector2(left + radius, top + radius), radius, PI, PI * 1.5, segment_count, true)
	return points


func _append_arc(points: PackedVector2Array, center: Vector2, radius: float, start_angle: float, end_angle: float, segment_count: int, skip_first_point: bool = false) -> void:
	for step_index in range(segment_count + 1):
		if skip_first_point and step_index == 0:
			continue

		var t := float(step_index) / float(segment_count)
		var angle := lerpf(start_angle, end_angle, t)
		points.append(center + Vector2(cos(angle), sin(angle)) * radius)
