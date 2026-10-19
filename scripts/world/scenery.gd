## The procedural set dressing that isn't on the hand-edited map (scenes/map/thornhill.tscn):
## thousands of grass tufts, flowers and pebbles, and the NPCs, spawned at the map's NpcSpots.
## Deterministic (seeded) so every peer builds the same world.
class_name Scenery
extends RefCounted

const NPC_SCENE := preload("res://scenes/npc.tscn")

var terrain: Terrain
var props: Node3D
var _scenes := {}


func _init(terrain_: Terrain, props_root: Node3D) -> void:
	terrain = terrain_
	props = props_root


func build_all(npc_spots: Dictionary) -> void:
	_build_scatter()
	_build_npcs(npc_spots)


func _scene(file: String) -> PackedScene:
	if not _scenes.has(file):
		_scenes[file] = load("res://assets/%s.glb" % file)
	return _scenes[file]


## Thousands of grass tufts, flowers and pebbles with one MultiMesh each. Grass and flowers are
## painted cards (assets/fx/*_card.png, crossed quads, clutter.gdshader); pebbles are a model.
const CLUTTER := {"grass": ["res://assets/fx/grass_card.png", 0.75], "flower": ["res://assets/fx/flower_card.png", 0.6]}

func _build_scatter() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 1234
	var half := Terrain.HALF - 4.0
	_collect_footprints()
	for spec in [["grass", 5000, 0.7, 1.4], ["flower", 620, 0.8, 1.2], ["prop_rock_small", 500, 0.6, 1.6]]:
		var file: String = spec[0]
		var pebbles := file == "prop_rock_small"
		var mesh: Mesh = _card_mesh(CLUTTER[file][0], CLUTTER[file][1]) if CLUTTER.has(file) else null
		var inst: Node3D = null
		if mesh == null:
			inst = _scene(file).instantiate()
			mesh = inst.find_children("*", "MeshInstance3D", true, false)[0].mesh
		var xforms := []
		var attempts := 0
		while xforms.size() < spec[1] and attempts < spec[1] * 4:
			attempts += 1
			var x := rng.randf_range(-half, half)
			var z := rng.randf_range(-half, half)
			if Terrain.road_distance(x, z) < Terrain.ROAD_HALF_WIDTH:
				continue
			if not pebbles and terrain.slope_at(x, z) > 0.35:
				continue
			if _under_prop(x, z):
				continue # no grass growing through a tent floor, a crate or a bedroll
			if not pebbles and terrain.is_reserved(x, z, 0.5):
				# The camp keeps some tufts and flowers (a third as many), away from the fire.
				var camp := Vector2(x, z).length() < Terrain.FLAT_RADIUS
				if not camp or Vector2(x, z).length() < 5.0 or rng.randf() > 0.33:
					continue
			var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3.ONE * rng.randf_range(spec[2], spec[3]))
			xforms.append(Transform3D(basis, Vector3(x, terrain.height_at(x, z), z)))
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = mesh
		mm.instance_count = xforms.size()
		for i in range(xforms.size()):
			mm.set_instance_transform(i, xforms[i])
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mmi.name = "Scatter_" + file
		props.add_child(mmi)
		if inst:
			inst.free()


## Ground footprints of the placed props (scenes/map: tents, crates, bedrolls, rocks...), as
## {cell: [[inverse transform, centre, half extents x z]]} in FOOTPRINT_CELL-metre cells. Trees are left
## out (their bounds are the canopy) and so are fences (thin, and grass along them looks right).
const FOOTPRINT_CELL := 4.0
var footprints := {}

func _collect_footprints() -> void:
	footprints.clear()
	for prop in props.get_tree().get_nodes_in_group("map_props"):
		var file: String = (prop as Node).scene_file_path.get_file()
		if file.begins_with("tree") or file.begins_with("fence"):
			continue
		var box := AABB()
		var first := true
		for mi in prop.find_children("*", "MeshInstance3D", true, false):
			var b: AABB = (prop.global_transform.affine_inverse() * mi.global_transform) * mi.get_aabb()
			box = b if first else box.merge(b)
			first = false
		if first:
			continue
		var inv: Transform3D = (prop as Node3D).global_transform.affine_inverse()
		var centre := Vector3(box.get_center().x, 0, box.get_center().z)
		var half := Vector2(box.size.x, box.size.z) * 0.5
		var entry := [inv, centre, half]
		var g: Vector3 = prop.global_position
		var reach: float = (prop.global_transform.basis * Vector3(half.x, 0, half.y)).length() + centre.length()
		for cx in range(floori((g.x - reach) / FOOTPRINT_CELL), floori((g.x + reach) / FOOTPRINT_CELL) + 1):
			for cz in range(floori((g.z - reach) / FOOTPRINT_CELL), floori((g.z + reach) / FOOTPRINT_CELL) + 1):
				var k := Vector2i(cx, cz)
				if not footprints.has(k):
					footprints[k] = []
				footprints[k].append(entry)


func _under_prop(x: float, z: float) -> bool:
	var k := Vector2i(floori(x / FOOTPRINT_CELL), floori(z / FOOTPRINT_CELL))
	for entry in footprints.get(k, []):
		var p: Vector3 = entry[0] * Vector3(x, 0, z) - entry[1]
		# the prop's local frame ignores height: compare the horizontal offset with the box
		if absf(p.x) < entry[2].x and absf(p.z) < entry[2].y:
			return true
	return false


## Two crossed upright quads `width` wide, as tall as the card's aspect, standing on the origin.
func _card_mesh(path: String, width: float) -> Mesh:
	var tex: Texture2D = load(path)
	var h := width * tex.get_height() / tex.get_width()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for a in [0.0, PI / 2.0]:
		var d := Vector3(cos(a), 0, sin(a)) * width * 0.5
		var c := [-d, d, d + Vector3(0, h, 0), -d + Vector3(0, h, 0)]
		var uv := [Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0)]
		for i in [0, 1, 2, 0, 2, 3]:
			st.set_uv(uv[i])
			st.set_normal(Vector3.UP)
			st.add_vertex(c[i])
	var mesh := st.commit()
	var mat := ShaderMaterial.new()
	mat.shader = load("res://assets/fx/clutter.gdshader")
	mat.set_shader_parameter("card", tex)
	mesh.surface_set_material(0, mat)
	return mesh


## Every NPC in GameData.NPCS stands at its NpcSpot on the map.
func _build_npcs(spots: Dictionary) -> void:
	for id in GameData.NPCS:
		if not spots.has(id):
			push_error("NPC %s has no NpcSpot on the map" % id)
			continue
		var npc := NPC_SCENE.instantiate()
		npc.setup(id)
		npc.transform = spots[id]
		npc.name = "npc_" + id
		props.add_child(npc)
