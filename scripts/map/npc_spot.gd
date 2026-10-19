## Where an NPC stands and faces on the map (npc_id = a GameData.NPCS key). In the editor it
## shows the hero body and the NPC's name so you can see who is where; in the game the World
## spawns the NPC here (Scenery._build_npcs).
@tool
class_name NpcSpot
extends Marker3D

@export var npc_id := "":
	set(v):
		npc_id = v
		_refresh()

var _shown: Node3D


func _enter_tree() -> void:
	if Engine.is_editor_hint():
		set_notify_transform(true)
		_refresh.call_deferred()


func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSFORM_CHANGED and Engine.is_editor_hint() and MapRoot.preview_terrain:
		var p := global_position
		var y := MapRoot.preview_terrain.height_at(p.x, p.z)
		if absf(p.y - y) > 0.001:
			global_position = Vector3(p.x, y, p.z)


func _refresh() -> void:
	if not Engine.is_editor_hint() or not is_inside_tree():
		return
	if _shown:
		_shown.queue_free()
	_shown = Node3D.new()
	add_child(_shown) # editor only, never saved
	var body: Node3D = load("res://assets/hero.glb").instantiate()
	body.rotation.y = PI
	_shown.add_child(body)
	var label := Label3D.new()
	var data: Dictionary = preload("res://scripts/core/game_data.gd").NPCS.get(npc_id, {})
	label.text = data.get("name", "? " + npc_id)
	label.position.y = 2.3
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.font_size = 48
	label.outline_size = 10
	label.modulate = Color(1.0, 0.85, 0.3)
	_shown.add_child(label)
