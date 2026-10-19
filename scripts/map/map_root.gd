## The hand-placed map (scenes/map/thornhill.tscn): camp, graveyard, the sites out in the zone,
## the forest, NPC spots and level pads. Open the scene in the Godot editor to move, add or
## delete things; in the editor this node also builds a preview of the terrain and caves (not
## saved) so props can be placed on the real ground. The game instances the scene under World.
##
##   move     select a prop, drag it (W) in the viewport; it drops onto the ground by itself
##   add      drag a scene from res://scenes/props/ into the viewport (or onto a group node)
##   remove   select and Delete;  copy: Ctrl+D
##   NPCs     move the NpcSpot nodes under NPCs (npc_id names the GameData.NPCS entry)
##   ground   a FlatPad levels the terrain around itself (sites on a hillside); the preview
##            rebuilds when you move one, or press "Rebuild Preview" in the Inspector
@tool
class_name MapRoot
extends Node3D

static var preview_terrain: Terrain = null

@export_tool_button("Rebuild Preview", "Reload") var rebuild_preview_button = _build_preview
@export_tool_button("Snap All To Ground", "ToolMove") var snap_button = func() -> void: snap_all(preview_terrain)

var _preview: Node3D
var _rebuild_queued := false


func _ready() -> void:
	if Engine.is_editor_hint():
		_build_preview.call_deferred()


## The level pads the terrain should flatten (FlatPad nodes anywhere under the map).
func pads() -> Array:
	var out := []
	for n in find_children("*", "", true, false):
		if n is FlatPad:
			out.append({"center": Vector2(n.global_position.x, n.global_position.z), "radius": n.radius, "blend": n.blend})
	return out


## Game: drop every prop onto the terrain the world built (normally a no-op: the editor
## placed them on the same ground).
func snap_all(terrain: Terrain) -> void:
	if terrain == null:
		return
	for p in get_tree().get_nodes_in_group("map_props"):
		if is_ancestor_of(p):
			p.snap_to_ground(terrain)


## Where each NPC stands: {npc_id: Transform3D}.
func npc_spots() -> Dictionary:
	var out := {}
	for n in find_children("*", "", true, false):
		if n is NpcSpot and n.npc_id != "":
			out[n.npc_id] = n.global_transform
	return out


# ---------------------------------------------------------------- editor preview

func queue_rebuild() -> void:
	if _rebuild_queued:
		return
	_rebuild_queued = true
	get_tree().create_timer(0.4).timeout.connect(func() -> void:
		_rebuild_queued = false
		_build_preview())


func _build_preview() -> void:
	if _preview:
		_preview.queue_free()
	_preview = Node3D.new()
	_preview.name = "_EditorPreview"
	add_child(_preview) # no owner: never saved into the scene
	var terrain := Terrain.new()
	terrain.add_world_features(pads())
	preview_terrain = terrain
	var body := StaticBody3D.new()
	_preview.add_child(body)
	terrain.build(body)
	for cave_name in Terrain.GD.CAVES:
		var data := Cave.load_data(cave_name)
		if data.is_empty():
			continue
		var inst := Cave.rock_mesh(data)
		if inst == null:
			continue
		var o: Array = data.origin
		inst.position = Vector3(o[0], o[1], o[2])
		_preview.add_child(inst)
	snap_all(terrain)
