## A cave built by tools/build_cave.py: the carved rock mesh (with a trimesh collider), torches,
## and the data the world needs from it: terrain zones + the hole for the entrance shaft, and
## monster spawns including the boss. Every peer builds it; only the monsters are spawned by the
## server. Reads assets/caves/<name>.out.json (the tool's derived, world-space output).
@tool # its static data helpers are used by the map editor; _ready only runs in the game
class_name Cave
extends Node3D

var data: Dictionary = {}


static func load_data(name: String) -> Dictionary:
	var path := "res://assets/caves/%s.out.json" % name
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("Cave data missing: %s (run tools/build_cave.py %s)" % [path, name])
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	return parsed if parsed is Dictionary else {}


func _init(name: String) -> void:
	self.name = "Cave_" + name
	data = load_data(name)


## Terrain zones (flat under the hill, the hill itself, a floor over the footprint), as Terrain expects them.
static func zones_of(cave_data: Dictionary) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for z in cave_data.get("zones", []):
		var zone := {"mode": z.mode, "center": Vector2(z.center[0], z.center[1]), "radius": float(z.radius),
			"blend": float(z.get("blend", 0.0)), "height": float(z.height), "reserve": z.get("reserve", true)}
		if z.mode == "mound":
			zone["seed"] = float(z.seed)
			zone["back"] = Vector2(z.back[0], z.back[1])
		out.append(zone)
	return out


func hole() -> Dictionary:
	return hole_of(data)


static func hole_of(cave_data: Dictionary) -> Dictionary:
	var h: Dictionary = cave_data.get("hole", {})
	return {"a": Vector2(h.a[0], h.a[1]), "b": Vector2(h.b[0], h.b[1]), "radius": float(h.radius)} if not h.is_empty() else {}


## [{kind, pos: Vector3, wander: float}] — wander keeps idle dwellers inside their room.
func spawns() -> Array:
	var out := []
	for s in data.get("spawns", []):
		out.append({"kind": s.kind, "pos": Vector3(s.pos[0], s.pos[1], s.pos[2]), "wander": float(s.get("wander", 6.0))})
	return out


func _ready() -> void:
	if Engine.is_editor_hint() or data.is_empty():
		return
	var o: Array = data.origin
	position = Vector3(o[0], o[1], o[2])
	var inst := rock_mesh(data)
	if inst == null:
		push_error("Cave mesh missing: " + str(data.mesh))
		return
	add_child(inst)
	var body := StaticBody3D.new()
	body.collision_layer = 1 # walkable like terrain
	body.collision_mask = 0
	add_child(body)
	for mi in inst.find_children("cave_collision*", "MeshInstance3D", true, false):
		var cs := CollisionShape3D.new()
		cs.shape = mi.mesh.create_trimesh_shape()
		body.add_child(cs)
	for t in data.get("torches", []):
		add_child(_torch(Vector3(t[0], t[1], t[2]) - position))


## The cave's rock, as the game and the map editor's preview show it. The .glb carries two meshes:
## "cave" to look at and a coarser, hidden "cave_collision" to walk on (a quarter of the
## triangles: physics against a concave mesh is what the dwellers pay for). Where it's grass (the
## hill) and where stone is baked into the vertex colours; the terrain's material in cave mode
## reads that paint and textures both like the ground around it.
static func rock_mesh(cave_data: Dictionary) -> Node3D:
	var scene: PackedScene = load(cave_data.mesh)
	if scene == null:
		return null
	var inst: Node3D = scene.instantiate()
	var rock: Material = load("res://assets/terrain/cave.tres")
	for mi in inst.find_children("*", "MeshInstance3D", true, false):
		if mi.name.begins_with("cave_collision"):
			mi.visible = false
		else:
			mi.material_override = rock
			mi.layers = 1 | FxKit.GROUND_LAYER # spell decals land on the cave floor too
	return inst


func _torch(pos: Vector3) -> Node3D:
	var t := StatusFx.torch(0.7, 2.2, 9.0)
	t.position = pos
	return t
