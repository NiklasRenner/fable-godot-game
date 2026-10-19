## Levels the terrain around itself at the ground's natural height there (a site on a
## hillside: a farm, a hunting camp). radius is fully flat, blend eases back to the hills.
@tool
class_name FlatPad
extends Marker3D

@export var radius := 7.0:
	set(v):
		radius = v
		_changed()
@export var blend := 8.0:
	set(v):
		blend = v
		_changed()


func _enter_tree() -> void:
	if Engine.is_editor_hint():
		set_notify_transform(true)


func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSFORM_CHANGED:
		_changed()


func _changed() -> void:
	if not Engine.is_editor_hint() or not is_inside_tree():
		return
	var root := get_parent()
	while root and not root is MapRoot:
		root = root.get_parent()
	if root:
		root.queue_rebuild()
