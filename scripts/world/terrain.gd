## Procedural terrain: a seeded noise heightmap, raised at the edges like a bowl, smooth-shaded and
## textured Classic-style: assets/terrain/terrain.gdshader blends four tiling painted layers (grass,
## dry grass, dirt road, rock) by weights baked into the vertex colours. "Zones" flatten it (the camp, the graveyard, cave entrances) or
## put a floor under it (so hills never dip into a cave below); "holes" leave openings in the mesh
## where cave shafts break the surface. The collider is a trimesh of the same mesh, so holes are
## real. Every peer builds the identical mesh from the seed, so nothing about it is synced.
@tool # the map editor (scenes/map) builds it to preview the ground
class_name Terrain
extends RefCounted

const GD := preload("res://scripts/core/game_data.gd") # the autoload isn't there in the editor

const GRID := 100           # vertices per side
const SPACING := 2.0        # metres between vertices -> ~198 m square
const HEIGHT_SCALE := 9.0
const FLAT_RADIUS := 14.0   # flat area around the player spawn (the camp)
const GRAVEYARD_RADIUS := 11.0
const ROAD_HALF_WIDTH := 2.2
const HALF := (GRID - 1) * SPACING * 0.5

## Dirt roads as polylines (x, z).
const ROADS := [
	[Vector2(0, 0), Vector2(13, 1), Vector2(26, 5), Vector2(40, 12)],       # east, to the boar fields
	[Vector2(0, 0), Vector2(-13, -1), Vector2(-26, -6), Vector2(-36, -17), Vector2(-42, -30)],  # west, to the troll warren's mouth
	[Vector2(0, 0), Vector2(1, 14), Vector2(6, 36)],                        # south, to the graveyard
]

## Zones: {mode: "flat"|"floor"|"mound"|"reserve", center: Vector2, radius, blend, height}.
## flat = height exactly inside radius, blending to the natural terrain over `blend` (kept clear of
## grass and flowers unless reserve = false); floor = never lower than height; mound = a hill added
## on top (see hill_height; also carries seed and back); reserve = no height effect, just kept clear.
var zones: Array[Dictionary] = [
	{"mode": "flat", "center": Vector2.ZERO, "radius": FLAT_RADIUS, "blend": 12.0, "height": 0.0},
	{"mode": "flat", "center": GD.GRAVEYARD, "radius": GRAVEYARD_RADIUS, "blend": 10.0, "height": 0.0},
]
## Holes: stadiums {a: Vector2, b: Vector2, radius} where no terrain triangles are emitted.
var holes: Array[Dictionary] = []

const MATERIAL := "res://assets/terrain/terrain.tres"

var noise := FastNoiseLite.new()


func _init() -> void:
	noise.seed = 7
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 0.022
	noise.fractal_octaves = 3


func height_at(x: float, z: float) -> float:
	var h := noise.get_noise_2d(x, z) * HEIGHT_SCALE
	h += sin(x * 0.05) * cos(z * 0.04) * 2.0
	var edge := maxf(absf(x), absf(z)) / (GRID * SPACING * 0.5)
	h += clampf((edge - 0.85) / 0.15, 0.0, 1.0) * 10.0 # raise the map edges like a bowl
	for zone in zones:
		if zone.mode == "mound" or zone.mode == "reserve":
			continue
		var t := clampf((Vector2(x, z).distance_to(zone.center) - zone.radius) / zone.blend, 0.0, 1.0)
		if zone.mode == "floor":
			if t < 1.0:
				h = maxf(h, zone.height - t * 30.0) # the floor falls away across the blend
		else:
			h = lerpf(zone.height, h, t)
	for zone in zones:
		if zone.mode == "mound":
			h += hill_height(x, z, zone)
	return h


## The hill a cave mouth leads into, raised on top of the (flattened) ground. MUST match
## hill_height() in tools/build_cave.py, which carves the cave to fit under it; the bake writes
## probe heights into the cave's .out.json and the selftest compares them against this.
static func hill_height(x: float, z: float, m: Dictionary) -> float:
	var c: Vector2 = m.center
	var r: float = m.radius
	var sd: float = m.seed
	var ang := atan2(z - c.y, x - c.x)
	var r_here := r * (1.0 + 0.12 * sin(2 * ang + sd) + 0.07 * sin(3 * ang - 1.3 * sd) + 0.04 * sin(5 * ang + 0.7 * sd))
	var crown: Vector2 = c + m.back * r * 0.15
	var dm := clampf(crown.distance_to(Vector2(x, z)) / r_here, 0.0, 1.0)
	var bump := pow(1.0 - dm * dm, 1.5) * (1.0 - 0.35 * dm) + 0.35 * dm * (1.0 - dm) * (1.0 - dm)
	var lumps := 0.12 * (sin(x * 0.21 + sd) * cos(z * 0.17 - sd) + 0.6 * sin(x * 0.4 - z * 0.33 + 2 * sd))
	return m.height * bump * (1.0 + lumps)


## Everything the ground depends on besides the noise, in a fixed order: the caves (flatten under
## the hill, the hill, the hole of the entrance shaft), then the map's level pads, each at the
## height the ground had there. The World and the map editor's preview both call this, so they
## build the identical ground.
func add_world_features(pads: Array) -> void:
	for cave_name in GD.CAVES:
		var data := Cave.load_data(cave_name)
		zones.append_array(Cave.zones_of(data))
		var h := Cave.hole_of(data)
		if not h.is_empty():
			holes.append(h)
	for pad in pads:
		var c: Vector2 = pad.center
		zones.append({"mode": "flat", "center": c, "radius": float(pad.radius), "blend": float(pad.blend),
			"height": height_at(c.x, c.y), "reserve": false})


func in_hole(x: float, z: float) -> bool:
	for hole in holes:
		var q: Vector2 = Geometry2D.get_closest_point_to_segment(Vector2(x, z), hole.a, hole.b)
		if q.distance_to(Vector2(x, z)) <= hole.radius:
			return true
	return false


## Distance from (x, z) to the nearest road centre line.
static func road_distance(x: float, z: float) -> float:
	var p := Vector2(x, z)
	var best := 1e9
	for road in ROADS:
		for i in range(road.size() - 1):
			best = minf(best, p.distance_to(Geometry2D.get_closest_point_to_segment(p, road[i], road[i + 1])))
	return best


## Flat zones (camp, graveyard, cave mouths), holes and roads are kept clear of grass and flowers
## (trees are placed by hand in the map scene).
func is_reserved(x: float, z: float, margin: float) -> bool:
	for zone in zones:
		if (zone.mode == "reserve" or (zone.mode == "flat" and zone.get("reserve", true))) \
				and Vector2(x, z).distance_to(zone.center) < zone.radius + margin:
			return true
	if in_hole(x, z):
		return true
	return road_distance(x, z) < ROAD_HALF_WIDTH + margin


## Steepness proxy used to thin out plants on rock.
func slope_at(x: float, z: float) -> float:
	var h := height_at(x, z)
	return absf(height_at(x + 0.5, z) - h) + absf(height_at(x, z + 0.5) - h)


## Builds the visual mesh (minus the holes) and a trimesh collider of it under `body`.
func build(body: StaticBody3D) -> void:
	var verts := []
	var normals := {} # grid vertex -> smooth normal
	for zi in range(GRID):
		var row := []
		for xi in range(GRID):
			var x := xi * SPACING - HALF
			var z := zi * SPACING - HALF
			var v := Vector3(x, height_at(x, z), z)
			row.append(v)
			normals[v] = normal_at(x, z)
		verts.append(row)

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for zi in range(GRID - 1):
		for xi in range(GRID - 1):
			var a: Vector3 = verts[zi][xi]
			var b: Vector3 = verts[zi][xi + 1]
			var c: Vector3 = verts[zi + 1][xi]
			var d: Vector3 = verts[zi + 1][xi + 1]
			# Godot front faces are clockwise when seen from the front (from above here).
			if not (_touches_hole(a) or _touches_hole(b) or _touches_hole(c)):
				_tri(st, normals, a, b, c)
			if not (_touches_hole(b) or _touches_hole(d) or _touches_hole(c)):
				_tri(st, normals, b, d, c)
	var mesh := st.commit()
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = load(MATERIAL)
	mi.layers = 1 | FxKit.GROUND_LAYER # spell decals land on it
	body.add_child(mi)
	var cs := CollisionShape3D.new()
	cs.shape = mesh.create_trimesh_shape()
	body.add_child(cs)


func _touches_hole(v: Vector3) -> bool:
	return not holes.is_empty() and in_hole(v.x, v.z)


func _tri(st: SurfaceTool, normals: Dictionary, a: Vector3, b: Vector3, c: Vector3) -> void:
	for v in [a, b, c]:
		var n: Vector3 = normals[v]
		st.set_normal(n)
		st.set_color(_layer_weights(v, n))
		st.add_vertex(v)


## Smooth normal from the height field (central differences over one grid step).
func normal_at(x: float, z: float) -> Vector3:
	var dx := height_at(x + SPACING, z) - height_at(x - SPACING, z)
	var dz := height_at(x, z + SPACING) - height_at(x, z - SPACING)
	return Vector3(-dx, 2.0 * SPACING, -dz).normalized()


## Layer weights for the shader as a colour: r = dry grass, g = dirt road, b = rock (grass is what's
## left). Drier with height and in noisy patches, rock on steep slopes, dirt on the roads.
func _layer_weights(v: Vector3, n: Vector3) -> Color:
	var w := Vector4(1, 0, 0, 0) # grass, dry, dirt, rock
	w = w.lerp(Vector4(0, 1, 0, 0), clampf(v.y / 14.0, 0.0, 1.0))
	w = w.lerp(Vector4(0, 1, 0, 0), clampf(noise.get_noise_2d(v.x * 6.0, v.z * 6.0) * 0.5 + 0.2, 0.0, 0.5))
	w = w.lerp(Vector4(0, 0, 0, 1), clampf(((1.0 - n.y) - 0.15) * 3.0, 0.0, 1.0))
	w = w.lerp(Vector4(0, 0, 1, 0), clampf((ROAD_HALF_WIDTH + 1.0 - road_distance(v.x, v.z)) / 1.5, 0.0, 1.0))
	return Color(w.y, w.z, w.w, 1.0)
