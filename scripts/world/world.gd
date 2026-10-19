## The zone: builds terrain + scenery on every peer (deterministic), and on the server runs the
## spawners for players, monsters and loot. Also the broadcast channel for combat/VFX events and
## the local "spirit realm" look while the local player is a ghost.
extends Node3D

const PLAYER_SCENE := preload("res://scenes/player.tscn")
const MONSTER_SCENE := preload("res://scenes/monster.tscn")
const LOOT_SCENE := preload("res://scenes/loot_bag.tscn")
const FLOATING_TEXT := preload("res://scripts/world/floating_text.gd")
const MIN_SPAWN_GAP := 7.0 # monsters spawn at least this far apart

signal combat_event_received(source: String, target: Node, amount: int, kind: String)

var terrain := Terrain.new()
var caves: Array[Cave] = []
var vfx: Node3D
var player_spawn := Vector3.ZERO
var spirit_realm := false
var _monster_id := 0
var _loot_id := 0
var _env_backup := {}
var nav_region: NavigationRegion3D # server only, see _bake_navmesh
var _spirit_particles: GPUParticles3D

@onready var players_root: Node3D = $Players
@onready var player_spawner: MultiplayerSpawner = $PlayerSpawner
@onready var monster_spawner: MultiplayerSpawner = $MonsterSpawner
@onready var loot_spawner: MultiplayerSpawner = $LootSpawner


func _ready() -> void:
	add_to_group("world")
	# The ground: noise, then the caves and the map's level pads (Terrain.add_world_features; the
	# map editor's preview does the same, so props placed there sit on this exact ground).
	for name in GameData.CAVES:
		var cave := Cave.new(name)
		caves.append(cave)
		$Props.add_child(cave)
	terrain.add_world_features($Map.pads())
	terrain.build($Terrain)
	$Map.snap_all(terrain)
	Scenery.new(terrain, $Props).build_all($Map.npc_spots())
	Audio.start_music()
	player_spawn = Vector3(0, height_at(0, 0) + 1.0, 0)
	vfx = Node3D.new()
	vfx.name = "VFX"
	vfx.set_script(load("res://scripts/world/vfx.gd"))
	add_child(vfx)
	player_spawner.spawn_function = _spawn_player
	monster_spawner.spawn_function = _spawn_monster
	loot_spawner.spawn_function = _spawn_loot


func height_at(x: float, z: float) -> float:
	return terrain.height_at(x, z)


func get_npc(id: String) -> Node:
	return $Props.get_node_or_null("npc_" + id)


func get_player(peer: int) -> Node:
	return players_root.get_node_or_null(str(peer))


# ---------------------------------------------------------------- server lifecycle

func start_server() -> void:
	multiplayer.peer_connected.connect(func(peer: int) -> void: print("[World] peer %d connected" % peer))
	multiplayer.peer_disconnected.connect(server_remove_player)
	_bake_navmesh()
	_spawn_monsters()


## Server only: a navigation mesh over everything static (terrain, cave floors, props) so
## monsters path around trees, tents and tunnel bends instead of walking into them. Baked once
## at start-up from the colliders; takes about 0.2 s.
func _bake_navmesh() -> void:
	var t0 := Time.get_ticks_msec()
	var nm := NavigationMesh.new()
	nm.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
	nm.geometry_collision_mask = 1 | 4
	nm.cell_size = 0.4 # agent sizes must be multiples of the cell sizes, or the bake warns
	nm.cell_height = 0.2
	nm.agent_radius = 0.8
	nm.agent_height = 1.8
	nm.agent_max_climb = Unit.STEP_HEIGHT
	nm.agent_max_slope = 50.0
	nm.region_min_size = 4.0
	nm.edge_max_length = 8.0
	var src := NavigationMeshSourceGeometryData3D.new()
	NavigationServer3D.parse_source_geometry_data(nm, src, self)
	NavigationServer3D.bake_from_source_geometry_data(nm, src)
	nav_region = NavigationRegion3D.new()
	nav_region.name = "NavRegion"
	nav_region.navigation_mesh = nm
	add_child(nav_region)
	print("[World] navmesh: %d polygons in %d ms" % [nm.get_polygon_count(), Time.get_ticks_msec() - t0])


## Server: spawn a player for a logged-in peer from its saved character data.
func server_add_player(peer: int, data: Dictionary) -> void:
	print("[World] player %d enters as %s (%s)" % [peer, data.name, data.get("class", "warrior")])
	var p: Node = player_spawner.spawn({"peer": peer, "class": data.get("class", "warrior"), "name": data.name})
	p.apply_save(data)


func server_remove_player(peer: int) -> void:
	print("[World] player %d leaves" % peer)
	var p := get_player(peer)
	if p:
		p.queue_free()


func _spawn_monsters() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 99
	var taken: Array[Vector3] = []
	# Boars east and south-east of the camp, out to the edge of the woods; trolls along the road west,
	# between the camp and their warren; wolves in the pines to the north.
	for i in range(7):
		_spawn_spread(rng, "boar", -0.9, 1.35, 24.0, 64.0, taken)
	for i in range(6):
		_spawn_spread(rng, "troll", -2.56 - 0.45, -2.56 + 0.45, 26.0, 46.0, taken)
	for i in range(7):
		_spawn_spread(rng, "wolf", -1.8, -0.9, 36.0, 70.0, taken)
	# Cave dwellers, where the cave plan put them.
	for cave in caves:
		for s in cave.spawns():
			_monster_id += 1
			monster_spawner.spawn({"kind": s.kind, "pos": s.pos, "id": _monster_id, "wander": s.wander})
	print("[World] spawned %d monsters" % _monster_id)


## Picks a spawn in the angular sector [a0, a1] at radius [r0, r1], at least MIN_SPAWN_GAP from
## every earlier spawn (best effort), so monsters use the space instead of stacking up.
func _spawn_spread(rng: RandomNumberGenerator, kind: String, a0: float, a1: float, r0: float, r1: float, taken: Array[Vector3]) -> void:
	var best := Vector3.ZERO
	var best_gap := -1.0
	for attempt in range(40):
		var a := rng.randf_range(a0, a1)
		var r := rng.randf_range(r0, r1)
		var pos := Vector3(cos(a) * r, 0, sin(a) * r)
		var gap := INF
		for t in taken:
			gap = minf(gap, pos.distance_to(t))
		if gap >= MIN_SPAWN_GAP:
			best = pos
			break
		if gap > best_gap:
			best_gap = gap
			best = pos
	taken.append(best)
	_monster_id += 1
	best.y = height_at(best.x, best.z) + 0.5
	monster_spawner.spawn({"kind": kind, "pos": best, "id": _monster_id})


## Server only.
## `owner_peer` has first dibs for LootBag.OWNER_SECONDS (0 = free for all).
func spawn_loot(pos: Vector3, items: Array, owner_peer := 0) -> void:
	if items.is_empty():
		return
	_loot_id += 1
	loot_spawner.spawn({"pos": pos, "items": items, "id": _loot_id, "owner": owner_peer})


# ---------------------------------------------------------------- spawn functions (run on all peers)

func _spawn_player(data: Dictionary) -> Node:
	var p := PLAYER_SCENE.instantiate()
	p.name = str(data.peer)
	p.set_meta("spawn_class", data.get("class", "warrior"))
	p.set_meta("spawn_name", data.get("name", ""))
	p.position = player_spawn + Vector3(randf_range(-2, 2), 0, randf_range(-2, 2))
	if data.peer == multiplayer.get_unique_id():
		p.bot_mode = Net.bot_mode
	return p


func _spawn_monster(data: Dictionary) -> Node:
	var m := MONSTER_SCENE.instantiate()
	m.name = "%s_%d" % [data.kind, data.id]
	m.setup(data)
	return m


func _spawn_loot(data: Dictionary) -> Node:
	var bag := LOOT_SCENE.instantiate()
	bag.name = "loot_%d" % data.id
	bag.setup(data)
	return bag


# ---------------------------------------------------------------- broadcasts (server -> everyone)

## Something hit something: combat log, floating numbers and hit effects on every peer.
@rpc("authority", "call_local", "reliable")
func combat_event(source: String, source_path: NodePath, target_path: NodePath, amount: int, kind: String) -> void:
	var target := get_node_or_null(target_path)
	combat_event_received.emit(source, target, amount, kind)
	vfx.on_combat_event(get_node_or_null(source_path), target, amount, kind)
	if target is Node3D and GameData.visuals_enabled():
		var ft: Label3D = FLOATING_TEXT.new()
		add_child(ft)
		ft.show_text(target.global_position + Vector3(0, 2.4, 0), amount, kind, target.get("faction") == "player")


## Cosmetic-only (no damage): charge_start, level_up, cast_start, frostbolt, ...
@rpc("authority", "call_local", "reliable")
func vfx_event(kind: String, source_path: NodePath, target_path: NodePath) -> void:
	vfx.play(kind, get_node_or_null(source_path), get_node_or_null(target_path))


# ---------------------------------------------------------------- spirit realm (local ghost look)

func _process(_delta: float) -> void:
	var p := get_tree().get_first_node_in_group("local_player")
	set_spirit_realm(p != null and p.is_ghost)
	if _spirit_particles and p:
		_spirit_particles.global_position = p.global_position + Vector3(0, 3, 0)


func set_spirit_realm(on: bool) -> void:
	if on == spirit_realm:
		return
	spirit_realm = on
	var env: Environment = $WorldEnvironment.environment
	if on:
		_env_backup = {"sat": env.adjustment_saturation, "bright": env.adjustment_brightness,
			"fog": env.fog_density, "fogc": env.fog_light_color, "amb": env.ambient_light_color}
		env.adjustment_saturation = 0.15
		env.adjustment_brightness = 0.75
		env.fog_density = 0.012
		env.fog_light_color = Color(0.45, 0.55, 0.8)
		env.ambient_light_color = Color(0.5, 0.6, 0.9)
		_spirit_particles = _make_spirit_particles()
		add_child(_spirit_particles)
	else:
		env.adjustment_saturation = _env_backup.sat
		env.adjustment_brightness = _env_backup.bright
		env.fog_density = _env_backup.fog
		env.fog_light_color = _env_backup.fogc
		env.ambient_light_color = _env_backup.amb
		if _spirit_particles:
			_spirit_particles.queue_free()
			_spirit_particles = null


func _make_spirit_particles() -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.amount = 160
	p.lifetime = 6.0
	var mat := ParticleProcessMaterial.new()
	mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	mat.emission_box_extents = Vector3(22, 6, 22)
	mat.direction = Vector3(0, 1, 0)
	mat.spread = 180.0
	mat.initial_velocity_min = 0.2
	mat.initial_velocity_max = 0.6
	mat.gravity = Vector3(0, 0.15, 0)
	mat.turbulence_enabled = true
	mat.turbulence_noise_strength = 0.6
	mat.turbulence_noise_scale = 2.0
	mat.scale_min = 0.5
	mat.scale_max = 1.4
	var ramp := Gradient.new()
	ramp.set_color(0, Color(0.7, 0.85, 1.0, 0.0))
	ramp.add_point(0.3, Color(0.7, 0.85, 1.0, 0.8))
	ramp.set_color(ramp.get_point_count() - 1, Color(0.7, 0.85, 1.0, 0.0))
	var rt := GradientTexture1D.new()
	rt.gradient = ramp
	mat.color_ramp = rt
	p.process_material = mat
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.08, 0.08, 0.08)
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.7, 0.85, 1.0)
	m.emission_enabled = true
	m.emission = Color(0.6, 0.8, 1.0)
	m.emission_energy_multiplier = 2.0
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.vertex_color_use_as_albedo = true
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mesh.material = m
	p.draw_pass_1 = mesh
	return p
