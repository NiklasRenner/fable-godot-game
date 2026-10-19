## A player character: one node per connected peer, named after the peer id.
## Authority is ALWAYS the server. Clients send intent (movement, and `request()` for everything
## else); the server simulates and the synced state flows back through MultiplayerSynchronizer,
## plus `notify()` events for the owning client's UI (messages, cooldowns, cast bar...).
##
## Behaviour lives in components so this file stays about state, lifecycle and the wire:
##   combat    (server) abilities, casting, queue, projectiles, auto-attack, charge
##   gear      (server) inventory, equipment, loot, vendor
##   questlog  (server) quest progress and turn-ins
##   targeting (client) target selection: tab, click, hover
##   bot       (client) headless test driver
class_name Player
extends Unit

signal target_changed(target: Node)
signal cooldown_started(ability_id: String, duration: float)
signal gcd_started(duration: float)
signal message(text: String)
signal auto_attack_changed(enabled: bool)
signal cast_started(ability_id: String, duration: float)
signal cast_stopped
signal cast_pushed_back(seconds: float)
signal loot_received(items: Array)
signal npc_opened(npc_id: String)
signal quests_changed

const TURN_SPEED := 2.6     # rad/s for keyboard turning
const JUMP_VELOCITY := 8.0

var peer_id := 1
var is_local := false
var bot_mode := false

# --- synced state (see player.tscn replication config) ---
var class_id := "warrior"
var char_name := "":
	set(v):
		char_name = v
		if v != "":
			display_name = v
var resource := 0          # rage for warriors, mana for mages
var max_resource := 100
var intellect := 0
var xp := 0
var auto_attack := false
var inventory: Array = []      # slots {"id": String, "n": int}; id "" = empty
var equipment: Dictionary = {} # slot -> item id
var armor := 0
var strength := 0
var stamina := 0
var copper := 0
var quests: Dictionary = {}    # quest_id -> {"state": "active"|"done", "progress": [int, ...]}
var corpse_position := Vector3.ZERO
var has_corpse := false

# --- client intent, sent to the server every physics tick ---
var input_dir := Vector2.ZERO # x = strafe, y = forward(-1)/back(+1)
var input_yaw := 0.0
var input_jump := false

# --- components ---
var combat: PlayerCombat
var gear: PlayerGear
var questlog: PlayerQuests
var targeting: Targeting
var bot: Bot

# --- server-only ---
var _jump_requested_at := -100.0 # server: when the last jump press arrived (kept briefly, see JUMP_GRACE)
var _last_floor_at := 0.0
const JUMP_GRACE := 0.15 # a press waits this long for ground, and ground counts this long after leaving it
var _off_floor_ticks := 0
var _resource_accum := 0.0
var _hp_regen_accum := 0.0
var _mana_spent_at := -100.0
var consuming := {}         # "food"/"drink" -> {heal, resource, ticks, next, name}: both can run at once
var _release_at := 0.0
var _release_requested := false
var _next_collect_refresh := 0.0

# --- visuals (all peers) ---
var _applied_equipment := {}
var _seen_quests := {}
var _footstep_t := 0.0
var _corpse_marker: Node3D = null
var _attachments: Array[Node] = [] # weapon, shoulder pieces: freed and rebuilt on every gear change

@onready var camera_rig: Node3D = $CameraRig
@onready var world: Node3D = get_tree().get_first_node_in_group("world")


func _ready() -> void:
	faction = "player"
	if get_meta("spawn_class", "") != "":
		class_id = get_meta("spawn_class")
		char_name = get_meta("spawn_name", "")
	peer_id = name.to_int()
	display_name = char_name if char_name != "" else "Hero %d" % peer_id
	max_health = cls().max_health
	health = max_health
	max_resource = cls().max_resource
	add_to_group("players")
	is_local = multiplayer.multiplayer_peer != null and peer_id == multiplayer.get_unique_id()
	walk_anim_speed = cls().speed / model_profile().run_speed
	load_model(model_profile().path, model_profile())
	super._ready()
	wall_min_slide_angle = deg_to_rad(5.0)
	camera_rig.set_active(is_local)
	combat = PlayerCombat.new(self)
	gear = PlayerGear.new(self)
	questlog = PlayerQuests.new(self)
	if is_local:
		add_to_group("local_player")
		targeting = Targeting.new(self)
		if bot_mode:
			bot = Bot.new(self)


func model_profile() -> Dictionary:
	return GameData.MODELS[cls().model]


func cls() -> Dictionary:
	return GameData.cls(class_id)


func uses_mana() -> bool:
	return cls().resource == "mana"


func head_height() -> float:
	return 2.1


func shows_nameplate() -> bool:
	return not is_local


## Client-side conveniences: the local target and the unit under the mouse (null when none).
var local_target: Node:
	get:
		return targeting.target if targeting else null
var hovered: Node:
	get:
		return targeting.hovered if targeting else null


# ---------------------------------------------------------------- the wire

## Client -> server intent. The server validates everything; the client only expresses a wish.
## actions: ability(id, target_path), target(path), cancel_cast(), equip(i), unequip(slot),
## destroy(i), loot(path), npc(npc_id, action, arg), release(), resurrect().
func request(action: String, args: Array = []) -> void:
	if is_server():
		_handle(action, args)
	else:
		_rpc_request.rpc_id(1, action, args)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_request(action: String, args: Array) -> void:
	if is_server() and multiplayer.get_remote_sender_id() == peer_id:
		_handle(action, args)


func _handle(action: String, args: Array) -> void:
	match action:
		"ability": combat.use(args[0], args[1])
		"target": combat.target_path = args[0]
		"cancel_cast": combat.cancel_cast()
		"equip": gear.equip(args[0])
		"unequip": gear.unequip(args[0])
		"destroy": gear.destroy(args[0])
		"loot": gear.loot(args[0])
		"npc": _npc_action(args[0], args[1], args[2])
		"release": _release_requested = true
		"resurrect": _resurrect()


## Server -> owning client. kinds: message(text), cooldown(id, s), gcd(s), auto_attack(on),
## cast(id, s) / cast("", 0) for stopped, cast_pushback(s), loot(items), set_target(path).
func notify(kind: String, args: Array = []) -> void:
	if peer_id == multiplayer.get_unique_id():
		_rpc_event(kind, args)
	else:
		_rpc_event.rpc_id(peer_id, kind, args)


@rpc("authority", "call_remote", "reliable")
func _rpc_event(kind: String, args: Array) -> void:
	match kind:
		"message": message.emit(args[0])
		"cooldown": cooldown_started.emit(args[0], args[1])
		"gcd": gcd_started.emit(args[0])
		"auto_attack": auto_attack_changed.emit(args[0])
		"cast":
			if args[0] == "":
				cast_stopped.emit()
			else:
				cast_started.emit(args[0], args[1])
		"cast_pushback": cast_pushed_back.emit(args[0])
		"loot": loot_received.emit(args[0])
		"set_target":
			var t := get_node_or_null(args[0])
			if t and targeting:
				targeting.set_target(t)


func say(text: String) -> void:
	notify("message", [text])


## Client: use an ability on the current target.
func use_ability(ability_id: String) -> void:
	request("ability", [ability_id, local_target.get_path() if is_instance_valid(local_target) else NodePath("")])


# ---------------------------------------------------------------- client: input

func turn(delta_yaw: float) -> void:
	input_yaw = wrapf(input_yaw + delta_yaw, -PI, PI)


func _read_input() -> void:
	var turn_axis := Input.get_axis("turn_left", "turn_right")
	if turn_axis != 0.0:
		turn(-turn_axis * TURN_SPEED * get_physics_process_delta_time())
	var forward := Input.get_axis("move_forward", "move_back")
	if camera_rig.both_held():
		forward = -1.0
	input_dir = Vector2(Input.get_axis("strafe_left", "strafe_right"), forward)
	if Input.is_action_just_pressed("jump"):
		input_jump = true


func _unhandled_input(event: InputEvent) -> void:
	if not is_local or bot_mode:
		return
	if event.is_action_pressed("target_next"):
		targeting.cycle(event.shift_pressed if event is InputEventWithModifiers else false)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("escape"):
		# Esc: cancel the cast, else clear the target, else open the game menu (the HUD handles
		# open windows before this runs).
		if casting:
			request("cancel_cast")
		elif local_target != null:
			targeting.set_target(null)
		else:
			get_tree().get_first_node_in_group("hud").toggle_menu()
	elif event.is_action_pressed("interact"):
		if near_corpse():
			request("resurrect")
		else:
			var bag := nearest_loot(LootBag.PICKUP_RANGE)
			if bag:
				request("loot", [bag.get_path()])
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		if not camera_rig.was_dragging():
			targeting.click(event.position)
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and not event.pressed:
		# Right click (not a drag): like a left click, but an enemy is also attacked.
		if not camera_rig.was_dragging() and targeting.click(camera_rig.press_position()) and not auto_attack:
			use_ability(GameData.EXTRA_ABILITY[class_id] if GameData.EXTRA_ABILITY.get(class_id, "") != "" else "auto_attack")
	else:
		var bar := GameData.class_bar(class_id)
		for i in range(mini(5, bar.size())):
			if event.is_action_pressed("ability_%d" % (i + 1)):
				use_ability(bar[i])


func _send_input() -> void:
	if is_server():
		_apply_input(input_dir, input_yaw, input_jump)
	else:
		_rpc_input.rpc_id(1, input_dir, input_yaw, input_jump)
	input_jump = false


@rpc("any_peer", "call_remote", "unreliable_ordered")
func _rpc_input(dir: Vector2, yaw: float, jump: bool) -> void:
	if is_server() and multiplayer.get_remote_sender_id() == peer_id:
		_apply_input(dir, yaw, jump)


func _apply_input(dir: Vector2, yaw: float, jump: bool) -> void:
	input_dir = dir.limit_length(1.0)
	input_yaw = yaw
	if jump:
		_jump_requested_at = now()


# ---------------------------------------------------------------- loop

func _physics_process(delta: float) -> void:
	if is_local:
		if bot:
			bot.think()
		else:
			_read_input()
		_send_input()
	if is_server():
		_server_tick(delta)
		publish_transform()


func _process(delta: float) -> void:
	super._process(delta)
	if equipment != _applied_equipment:
		_apply_equipment_visuals()
	_update_corpse_marker()
	if not is_local:
		return
	if moving and not is_dead and not is_ghost and is_on_floor():
		_footstep_t += delta
		if _footstep_t > 0.36:
			_footstep_t = 0.0
			Audio.play("footstep", -8.0, 0.15)
	if quests != _seen_quests:
		_seen_quests = quests.duplicate(true)
		quests_changed.emit()
	targeting.process(delta)


func _server_tick(delta: float) -> void:
	if is_dead:
		if _release_requested or now() >= _release_at:
			_release_spirit()
		return
	if now() >= _next_collect_refresh:
		_next_collect_refresh = now() + 0.5
		questlog.refresh_collect_progress()
	velocity.y -= GRAVITY * delta
	if combat.charging:
		combat.tick_charge()
	else:
		var speed: float = cls().speed * speed_multiplier() * (GameData.GHOST_SPEED_MULT if is_ghost else 1.0)
		var dir := Basis(Vector3.UP, input_yaw) * Vector3(input_dir.x, 0, input_dir.y)
		velocity.x = dir.x * speed
		velocity.z = dir.z * speed
		rotation.y = input_yaw
		# Forgiving jumps: walking uphill the step-up briefly lifts the body off the slope, and a
		# press landing on exactly that tick used to be dropped.
		if is_on_floor():
			_last_floor_at = now()
		var grounded := now() - _last_floor_at <= JUMP_GRACE and velocity.y <= 1.0
		if now() - _jump_requested_at <= JUMP_GRACE and grounded:
			velocity.y = JUMP_VELOCITY
			_jump_requested_at = -100.0
			_last_floor_at = -100.0
	move_with_step()
	moving = Vector2(velocity.x, velocity.z).length() > 0.5
	# Airborne the instant a jump starts, but only after a few ticks of free fall otherwise,
	# so stepping down a slope doesn't flicker the jump animation.
	_off_floor_ticks = 0 if is_on_floor() else _off_floor_ticks + 1
	# ...and once airborne, stay so until the feet are down: near the apex the vertical speed passes
	# zero, which used to drop the flag for a tick and restart the jump clip mid-air.
	if is_on_floor():
		airborne = false
	elif velocity.y > 2.0 or _off_floor_ticks > 6:
		airborne = true
	move_dir = input_dir if moving else Vector2.ZERO
	update_effects()
	_tick_vitals(delta)
	combat.tick()


# ---------------------------------------------------------------- server: vitals (regen, eating)

func _tick_vitals(delta: float) -> void:
	# Resource: mana trickles back (five-second rule after spending); rage decays out of combat.
	if uses_mana():
		var recently_spent := now() - _mana_spent_at < 5.0
		var rate: float = cls().mana_regen_combat if (in_combat() or recently_spent) else cls().mana_regen_ooc
		resource = mini(max_resource, resource + _drain_resource(delta * rate))
	elif not in_combat():
		resource = maxi(0, resource - _drain_resource(delta * cls().rage_decay_per_sec))
	# Health: slow regen out of combat.
	if not in_combat() and health < max_health and not is_ghost:
		_hp_regen_accum += delta * GameData.HEALTH_REGEN_OOC * max_health
		var whole := int(_hp_regen_accum)
		_hp_regen_accum -= whole
		health = mini(max_health, health + whole)
	_tick_consuming()


## Fractional resource changes accumulate until a whole point is ready; returns the whole points.
func _drain_resource(amount: float) -> int:
	_resource_accum += amount
	var whole := int(_resource_accum)
	_resource_accum -= whole
	return whole


func spend_resource(amount: int) -> void:
	resource = maxi(0, resource - amount)
	if uses_mana():
		_mana_spent_at = now()
	last_combat_time = now()


## Warriors build rage from swings and from taking damage.
func gain_rage(amount: float) -> void:
	if uses_mana():
		return
	resource = mini(max_resource, resource + _drain_resource(amount))
	last_combat_time = now()


## Food and drink are two channels that can run together: sit down and each lands its effect
## over EAT_SECONDS. Moving, combat, damage or using anything else stands you up and forfeits
## whatever is left of both; otherwise you stay sat until the last one finishes.
func start_consuming(item: Dictionary) -> void:
	var ticks := int(GameData.EAT_SECONDS)
	var kind := "food" if item.has("heal") else "drink"
	consuming[kind] = {"heal": float(item.get("heal", 0)) / ticks, "resource": float(item.get(cls().resource, 0)) / ticks,
		"ticks": ticks, "next": now() + 1.0, "name": item.name}
	sitting = true
	say("You sit down to %s the %s." % ["eat" if kind == "food" else "drink", item.name])


func stop_consuming(reason := "") -> void:
	if consuming.is_empty():
		return
	consuming = {}
	sitting = false
	if reason != "":
		say(reason)


func _tick_consuming() -> void:
	if consuming.is_empty():
		return
	if moving or in_combat() or now() < stun_until or airborne:
		stop_consuming("You stand up.")
		return
	for kind in consuming.keys():
		var c: Dictionary = consuming[kind]
		if now() < c.next:
			continue
		c.next += 1.0
		c.ticks -= 1
		health = mini(max_health, health + int(round(c.heal)))
		resource = mini(max_resource, resource + int(round(c.resource)))
		if c.ticks <= 0:
			consuming.erase(kind)
			say("You finish the %s." % c.name)
	if consuming.is_empty():
		sitting = false
		say("You feel refreshed.")


# ---------------------------------------------------------------- server: damage, death, xp

func _mitigate(amount: int) -> int:
	return int(round(amount * GameData.armor_multiplier(armor)))


func _on_damaged(amount: int, source: Node) -> void:
	stop_consuming("You stand up.")
	if amount > 0:
		combat.pushback()
	gain_rage(amount * cls().get("rage_per_damage_taken", 0.0))
	# No target yet (or it died)? Whatever just hit us becomes the target, like WoW.
	if combat.target() == null and source is Unit and not source.is_dead and source.faction != faction:
		combat.target_path = source.get_path()
		notify("set_target", [combat.target_path])


func _die(killer: Node) -> void:
	super._die(killer)
	combat.on_death()
	consuming = {}
	sitting = false
	resource = 0
	corpse_position = global_position
	has_corpse = true
	_release_requested = false
	_release_at = now() + GameData.RELEASE_AUTO_SECONDS
	say("You have died. Release your spirit to return to the graveyard.")


func _release_spirit() -> void:
	is_dead = false
	is_ghost = true
	health = max_health
	var g := GameData.GRAVEYARD
	position = Vector3(g.x, world.height_at(g.x, g.y) + 1.0, g.y)
	velocity = Vector3.ZERO
	say("You are a ghost. Return to your corpse to resurrect.")


func _resurrect() -> void:
	if not is_ghost or not has_corpse:
		return
	if not near_corpse():
		say("You are too far from your corpse.")
		return
	is_ghost = false
	has_corpse = false
	health = maxi(1, max_health / 2)
	resource = 0
	velocity = Vector3.ZERO
	say("You feel the warmth return to your body.")


func near_corpse() -> bool:
	return is_ghost and has_corpse and global_position.distance_to(corpse_position) <= GameData.CORPSE_RES_RANGE


func seconds_until_release() -> float:
	return maxf(0.0, _release_at - now())


func gain_xp(amount: int) -> void:
	xp += amount
	say("You gain %d experience." % amount)
	while xp >= GameData.xp_for_level(level):
		xp -= GameData.xp_for_level(level)
		level += 1
		gear.recalc_stats()
		heal_full()
		world.vfx_event.rpc("level_up", get_path(), get_path())
		save()
		say("You have reached level %d!" % level)


## Server only; called by Monster._die.
func on_kill(monster_kind: String) -> void:
	questlog.on_kill(monster_kind)


# ---------------------------------------------------------------- server: npcs

func _npc_action(npc_id: String, action: String, arg: Variant) -> void:
	if is_dead or is_ghost:
		return
	var npc: Node = world.get_npc(npc_id)
	if npc == null:
		return
	if global_position.distance_to(npc.global_position) > npc.INTERACT_RANGE + 1.5:
		say("You are too far away.")
		return
	match action:
		"accept": questlog.accept(npc_id)
		"complete": questlog.complete(npc_id)
		"buy": gear.buy(npc.data, str(arg))
		"sell": gear.sell(int(arg))


func nearest_loot(max_dist: float) -> Node:
	var best: Node = null
	var best_d := max_dist
	for bag in get_tree().get_nodes_in_group("loot"):
		var d: float = global_position.distance_to(bag.global_position)
		if d < best_d:
			best_d = d
			best = bag
	return best


# ---------------------------------------------------------------- server: persistence

func save_data() -> Dictionary:
	return {
		"name": char_name, "class": class_id, "level": level, "xp": xp,
		"health": health, "resource": resource, "copper": copper,
		"equipment": equipment.duplicate(), "inventory": inventory.duplicate(true), "quests": quests.duplicate(true),
		"pos": [global_position.x, global_position.y, global_position.z], "yaw": input_yaw,
		"saved": Time.get_datetime_string_from_system(),
	}


## Restore a character from its save (fresh characters just keep the starter kit).
func apply_save(data: Dictionary) -> void:
	class_id = data.get("class", class_id)
	char_name = data.get("name", char_name)
	display_name = char_name
	level = int(data.get("level", 1))
	xp = int(data.get("xp", 0))
	if data.get("fresh", false) or not data.has("inventory"):
		gear.give_starter_kit()
		save()
		return
	copper = int(data.get("copper", 0))
	var eq := {}
	# items renamed or removed since the save was written are dropped rather than kept as ghosts
	for slot in data.get("equipment", {}):
		if GameData.ITEMS.has(str(data.equipment[slot])):
			eq[slot] = str(data.equipment[slot])
	equipment = eq
	var inv := []
	for slot in data.get("inventory", []):
		var id := str(slot.get("id", ""))
		inv.append({"id": id, "n": int(slot.get("n", 0))} if GameData.ITEMS.has(id) else GameData.empty_slot())
	while inv.size() < GameData.INVENTORY_SIZE:
		inv.append(GameData.empty_slot())
	inventory = inv
	var qs := {}
	for qid in data.get("quests", {}):
		var q: Dictionary = data.quests[qid]
		var prog := []
		for v in q.get("progress", []):
			prog.append(int(v))
		qs[qid] = {"state": str(q.get("state", "active")), "progress": prog}
	quests = qs
	gear.recalc_stats()
	health = clampi(int(data.get("health", max_health)), 1, max_health)
	resource = clampi(int(data.get("resource", 0)), 0, max_resource)
	if data.has("pos") and data.pos.size() == 3:
		var pos := Vector3(float(data.pos[0]), float(data.pos[1]), float(data.pos[2]))
		pos.y = maxf(pos.y, world.height_at(pos.x, pos.z) + 0.6)
		global_position = pos
		input_yaw = float(data.get("yaw", 0.0))


func save() -> void:
	if is_server():
		Net.save_player(self)


# ---------------------------------------------------------------- visuals (all peers)

func _apply_equipment_visuals() -> void:
	_applied_equipment = equipment.duplicate()
	for a in _attachments:
		a.queue_free()
	var profile := model_profile()
	var skins := {}
	for slot in profile.skins.slots:
		skins[slot] = GameData.item_stat(equipment.get(slot, ""), "skin", "")
	var pieces := {} # modelled armour: an item's "mesh" names its armour set
	for slot in Outfit.ARMOR_SLOTS:
		var armor_set: String = GameData.item_stat(equipment.get(slot, ""), "mesh", "")
		if armor_set != "":
			pieces[slot] = armor_set
	_attachments = Outfit.dress(model, profile, {"skins": skins, "armor": pieces,
		"weapon": GameData.item_stat(equipment.get("weapon", ""), "model", ""),
		"shoulders": GameData.item_stat(equipment.get("shoulders", ""), "model", "")})


func _update_corpse_marker() -> void:
	if has_corpse and _corpse_marker == null:
		_corpse_marker = Node3D.new()
		_corpse_marker.top_level = true
		add_child(_corpse_marker)
		_corpse_marker.add_child(load("res://assets/prop_gravestone.glb").instantiate())
		var l := WorldLabel.make("Corpse of %s" % display_name, 1.6, Color(0.8, 0.8, 0.9), 36, 8)
		_corpse_marker.add_child(l)
		_corpse_marker.global_position = corpse_position
	elif not has_corpse and _corpse_marker != null:
		_corpse_marker.queue_free()
		_corpse_marker = null
