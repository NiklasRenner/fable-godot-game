## A monster. Spawned by the server through World.MonsterSpawner with {kind, pos, id, wander}.
## AI runs only on the server: idle/wander -> chase -> attack, leash back home, respawn. Movement
## follows the world's navmesh (World._bake_navmesh); a monster that spawns or gets wedged inside
## something is snapped back onto it.
class_name Monster
extends Unit


var kind := "boar"
var stats: Dictionary
var home := Vector3.ZERO
var wander_radius := 6.0 # how far from home it strolls while idle (cave rooms are small)
var state := "idle" # server only: idle | chase | return | dead
var tagged_peer := 0 # synced: the peer whose player first engaged it; XP and loot are theirs (0 = free)

const INTEREST_RADIUS := 70.0  # a client only has monsters within this range of its character...
const INTEREST_RELEASE := 85.0 # ...and keeps them until they are this far (no flapping at the edge)
var _interest := {} # server: peer -> bool, last visibility decision
var _next_interest := 0.0

# server-only
var _target: Node = null
var _next_swing := 0.0
var _respawn_at := 0.0
var _wander_to := Vector3.ZERO
var _next_wander := 0.0
var _threat := {} # player node -> threat
var _settle_ticks := 60 # after (re)spawning, always run collision so it drops onto the floor
var _path := PackedVector3Array() # current navmesh path (server), see _move_towards
var _path_i := 0
var _path_goal := Vector3.ZERO
var _next_path := 0.0
var _stuck_since := 0.0
var _stuck_from := Vector3.ZERO
const UNSTICK_MAX := 6.0 # never move a monster further than this to get it onto the navmesh

@onready var world: Node3D = get_tree().get_first_node_in_group("world")


func setup(data: Dictionary) -> void:
	kind = data.kind
	home = data.pos
	wander_radius = float(data.get("wander", 6.0))
	position = home
	stats = GameData.MONSTERS[kind]
	display_name = stats.name
	level = stats.level
	max_health = stats.max_health
	health = max_health


func _ready() -> void:
	add_to_group("monsters")
	if stats.is_empty():
		stats = GameData.MONSTERS[kind]
	model.scale = Vector3.ONE * stats.scale
	var model_key: String = stats.get("model", kind)
	if GameData.MODELS.has(model_key):
		# a humanoid-rig model with a profile (trolls): its clip speed and weapon grip come from there
		var profile: Dictionary = GameData.MODELS[model_key]
		walk_anim_speed = stats.speed / (float(profile.run_speed) * stats.scale)
		load_model(profile.path, profile)
		if stats.has("weapon"):
			Outfit.dress(model, profile, {"weapon": stats.weapon})
	else:
		walk_anim_speed = stats.speed / 4.0 # the quadruped rigs' trot (import_meshy.py quadruped)
		load_model("res://assets/%s.glb" % model_key)
	super._ready()
	_wander_to = home
	if is_server():
		# Interest management: each client is only sent (and only spawns) the monsters near its
		# character; MultiplayerSpawner despawns them on that client when they go out of range.
		$MultiplayerSynchronizer.add_visibility_filter(_visible_to_peer)
		_next_interest = now() + rng.randf_range(0.0, 0.5) # stagger the checks across monsters
		# The navmesh syncs on the next physics frame; only then can a bad spawn be corrected.
		await get_tree().physics_frame
		await get_tree().physics_frame
		if not is_dead:
			_unstick()


## Server: is this monster of interest to `peer` (within range of its character, with hysteresis)?
func _visible_to_peer(peer: int) -> bool:
	if peer == 1:
		return true # the server itself (also the host's own client)
	var p: Node3D = world.get_player(peer) if world else null
	if p == null:
		return false
	var d := global_position.distance_to(p.global_position)
	var was: bool = _interest.get(peer, false)
	var vis := d < (INTEREST_RELEASE if was else INTEREST_RADIUS)
	_interest[peer] = vis
	return vis


## Tagged by someone else: grey name and bar, like WoW.
func nameplate_color() -> Color:
	if tagged_peer != 0 and tagged_peer != multiplayer.get_unique_id():
		return Color(0.6, 0.6, 0.6)
	return super.nameplate_color()


func plate_rim() -> Color:
	return UITheme.ELITE if stats.get("rank", "") == "boss" else super.plate_rim()


func shows_nameplate() -> bool:
	var p := get_tree().get_first_node_in_group("local_player")
	if p == null or p.local_target == self or p.hovered == self:
		return true
	return WorldLabel.near_local_player(get_tree(), global_position, WorldLabel.RANGE_NEAR)


func head_height() -> float:
	return (1.6 if stats.shape == "quadruped" else 1.9) * stats.scale


# ---------------------------------------------------------------- server AI

func _physics_process(delta: float) -> void:
	if not is_server():
		return
	if now() >= _next_interest:
		_next_interest = now() + 0.5
		$MultiplayerSynchronizer.update_visibility()
	if is_dead:
		if now() >= _respawn_at:
			_respawn()
		publish_transform()
		return
	velocity.y -= GRAVITY * delta
	match state:
		"idle": _tick_idle()
		"chase": _tick_chase()
		"return": _tick_return()
	# A monster standing still on the ground skips the (concave-mesh) collision step entirely:
	# with thirty of them, that is most of the physics budget.
	if _settle_ticks > 0 or velocity.x != 0.0 or velocity.z != 0.0 or not is_on_floor():
		_settle_ticks = maxi(0, _settle_ticks - 1)
		move_with_step()
	else:
		velocity.y = 0.0
	moving = Vector2(velocity.x, velocity.z).length() > 0.3
	update_effects()
	publish_transform()


## A monster squares up while it has a target (chasing or swinging), not while it walks home.
func _combat_ready() -> bool:
	return state == "chase"


func _tick_idle() -> void:
	var nearest := _nearest_player(stats.aggro_radius)
	if nearest:
		_aggro(nearest)
		return
	# Wander lazily near home.
	if now() >= _next_wander:
		_next_wander = now() + rng.randf_range(3.0, 8.0)
		var a := rng.randf() * TAU
		var d := rng.randf_range(0.0, wander_radius)
		_wander_to = home + Vector3(cos(a) * d, 0, sin(a) * d)
		var map := get_world_3d().navigation_map
		if NavigationServer3D.map_get_iteration_id(map) > 0:
			_wander_to = NavigationServer3D.map_get_closest_point(map, _wander_to) # not into a tree
	_move_towards(_wander_to, stats.speed * 0.4 * speed_multiplier(), 1.0)


func _tick_chase() -> void:
	if not is_instance_valid(_target) or _target.is_dead or _target.is_ghost:
		_pick_next_target()
		if _target == null:
			state = "return"
			return
	if global_position.distance_to(home) > stats.leash_radius:
		state = "return"
		_threat.clear()
		_target = null
		return
	if global_position.distance_to(_target.global_position) > GameData.MELEE_RANGE - 0.6:
		_move_towards(_target.global_position, stats.speed * speed_multiplier(), 0.0)
		return
	velocity.x = 0
	velocity.z = 0
	face_towards(_target.global_position)
	if now() >= _next_swing and now() >= stun_until:
		_next_swing = now() + stats.attack_speed
		attack_tick += 1
		var dmg := GameData.roll_damage(rng, stats.dmg_min, stats.dmg_max, level, _target.level)
		_target.take_damage(dmg, self)
		world.combat_event.rpc(display_name, get_path(), _target.get_path(), dmg, "melee")


func _tick_return() -> void:
	# Evade: regen fully and walk home.
	if _move_towards(home, stats.speed, 1.5):
		state = "idle"
		tagged_peer = 0
		heal_full()
		velocity.x = 0
		velocity.z = 0
	else:
		health = mini(max_health, health + 2)


## Walks along the navmesh towards `point` (a fresh path every 0.6 s or when the goal moves);
## straight at it once the path runs out. Returns true when within `stop_dist` of the point.
func _move_towards(point: Vector3, speed: float, stop_dist: float) -> bool:
	var d := point - global_position
	d.y = 0
	if d.length() <= stop_dist:
		velocity.x = 0
		velocity.z = 0
		_path.clear()
		return true
	if now() >= _next_path or point.distance_to(_path_goal) > 1.5:
		_next_path = now() + 0.6
		_path_goal = point
		_path = NavigationServer3D.map_get_path(get_world_3d().navigation_map, global_position, point, true)
		_path_i = 0
	var waypoint := point
	if _path.size() > 1:
		while _path_i < _path.size() - 1 and Vector2(_path[_path_i].x - global_position.x, _path[_path_i].z - global_position.z).length() < 0.8:
			_path_i += 1
		waypoint = _path[_path_i]
	var dir := waypoint - global_position
	dir.y = 0
	if dir.length() < 0.05:
		dir = d
	dir = dir.normalized()
	velocity.x = dir.x * speed
	velocity.z = dir.z * speed
	if speed > 0.01:
		rotation.y = atan2(-dir.x, -dir.z)
	_check_stuck()
	return false


## Wanted to move but didn't for a while (spawned into a rock, wedged on a tent): put it back on
## the navmesh at the nearest walkable point.
func _check_stuck() -> void:
	if global_position.distance_to(_stuck_from) > 0.4:
		_stuck_from = global_position
		_stuck_since = now()
	elif now() - _stuck_since > 1.5:
		_stuck_since = now()
		_unstick()


## Server: snaps to the nearest point on the navmesh (never inside a tree or a wall).
func _unstick() -> void:
	var map := get_world_3d().navigation_map
	if NavigationServer3D.map_get_iteration_id(map) == 0:
		return # no navmesh (yet)
	var q := NavigationServer3D.map_get_closest_point(map, global_position)
	# Only a nudge: a far answer means the map hasn't taken in the navmesh yet (it answers (0,0,0)
	# then, which once teleported every monster into the camp at start-up) or the monster is
	# somewhere it shouldn't be judged from; either way staying put is safer.
	if q.distance_to(global_position) > 0.2 and q.distance_to(global_position) < UNSTICK_MAX:
		global_position = q + Vector3.UP * 0.3
		_path.clear()
		_settle_ticks = 10


func _nearest_player(max_dist: float) -> Node:
	var best: Node = null
	var best_d := max_dist
	for p in get_tree().get_nodes_in_group("players"):
		if p.is_dead or p.is_ghost:
			continue
		var d: float = global_position.distance_to(p.global_position)
		if d < best_d:
			best_d = d
			best = p
	return best


func _aggro(player: Node, from_ally := false) -> void:
	if tagged_peer == 0:
		tagged_peer = player.peer_id
	_threat[player] = _threat.get(player, 0) + 1
	_target = player
	state = "chase"
	last_combat_time = now()
	if not from_ally:
		_call_for_help(player)


## Social aggro: idle monsters of the same kind nearby join in, so a pack can't be picked
## apart one at a time from range.
func _call_for_help(player: Node) -> void:
	for m in get_tree().get_nodes_in_group("monsters"):
		if m == self or m.is_dead or m.kind != kind or m.state != "idle":
			continue
		if global_position.distance_to(m.global_position) <= GameData.SOCIAL_AGGRO_RADIUS:
			m._aggro(player, true)


func _pick_next_target() -> void:
	_target = null
	var best := -1
	for p in _threat.keys():
		if is_instance_valid(p) and not p.is_dead and not p.is_ghost and _threat[p] > best:
			best = _threat[p]
			_target = p


func _on_damaged(amount: int, source: Node) -> void:
	if source == null or source.get("faction") != "player":
		return
	if tagged_peer == 0:
		tagged_peer = source.peer_id
	_threat[source] = _threat.get(source, 0) + amount
	if state != "chase" or _target == null or not is_instance_valid(_target) or _target.is_dead:
		_aggro(source)
	elif _threat[source] > _threat.get(_target, 0) * 1.1:
		_target = source


func _die(killer: Node) -> void:
	super._die(killer)
	state = "dead"
	_target = null
	_threat.clear()
	_respawn_at = now() + stats.respawn_time
	# The kill belongs to whoever tagged the monster, not whoever landed the last hit.
	var tagger: Node = world.get_player(tagged_peer) if tagged_peer != 0 else null
	var credited: Node = tagger if is_instance_valid(tagger) and tagger.has_method("gain_xp") else killer
	if credited and credited.has_method("gain_xp"):
		credited.gain_xp(stats.xp)
		credited.on_kill(kind)
		world.combat_event.rpc(display_name, get_path(), get_path(), 0, "dies")
		world.spawn_loot(global_position, GameData.roll_loot(kind, rng), credited.peer_id)
	tagged_peer = 0


func _respawn() -> void:
	is_dead = false
	heal_full()
	position = home
	velocity = Vector3.ZERO
	state = "idle"
	tagged_peer = 0
	_settle_ticks = 60
	_unstick()
