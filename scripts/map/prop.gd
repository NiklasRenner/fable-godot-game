## A placed prop on the map (scenes/props/*.tscn). Sticks to the ground: in the editor it drops
## onto the terrain whenever you move it (so you can drag it around in the top view), and the
## game snaps it again after building the terrain, in case the ground changed since.
##   lift     metres above (or below) the ground: a crate stacked on another, a tree sunk in a bit
##   snap     off: keep the height exactly as placed
##   stretch  scales only the model (and its collider), e.g. long flat boulders
@tool
class_name MapProp
extends Node3D

@export var lift := 0.0:
	set(v):
		lift = v
		_snap()
@export var snap := true
@export var stretch := Vector3.ONE:
	set(v):
		stretch = v
		_apply_stretch()

var _snapping := false
var _base_shape: CylinderShape3D
var _base_y := 0.0


func _enter_tree() -> void:
	add_to_group("map_props")
	if Engine.is_editor_hint():
		set_notify_transform(true)


func _ready() -> void:
	_apply_stretch()


func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSFORM_CHANGED and Engine.is_editor_hint():
		_snap()


## Puts the prop on `terrain` (defaults to the one the editor's map preview built).
func snap_to_ground(terrain: Terrain = null) -> void:
	if terrain == null:
		terrain = MapRoot.preview_terrain
	if terrain == null or not snap or _snapping or not is_inside_tree():
		return
	_snapping = true
	var p := global_position
	var y := terrain.height_at(p.x, p.z) + lift
	if absf(p.y - y) > 0.001:
		global_position = Vector3(p.x, y, p.z)
	_snapping = false


func _snap() -> void:
	if Engine.is_editor_hint():
		snap_to_ground()


func _apply_stretch() -> void:
	var model := get_node_or_null("Model") as Node3D
	if model:
		model.scale = stretch
	var col := get_node_or_null("Collider") as CollisionShape3D
	if col and col.shape is CylinderShape3D and stretch != Vector3.ONE:
		if _base_shape == null:
			_base_shape = col.shape
			_base_y = col.position.y
		var s := _base_shape.duplicate() as CylinderShape3D
		s.radius = _base_shape.radius * maxf(stretch.x, stretch.z)
		s.height = _base_shape.height * stretch.y
		col.shape = s
		col.position.y = _base_y * stretch.y
