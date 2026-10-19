## Server-side combat for one player: abilities, the global cooldown, casting with the WoW-style
## spell queue, projectiles and damage-over-time, auto-attack (melee swings or wand shots with a
## wind-up) and Charge.
##
## WoW rules implemented here: the GCD starts when a cast starts; a running cast is never cancelled
## by pressing another spell (within the last SPELL_QUEUE_WINDOW it is queued, earlier it is
## refused); moving, jumping, stuns and the target dying interrupt; targets must be in the front
## arc to be hit, and a cast that finishes while facing away fizzles.
class_name PlayerCombat
extends RefCounted

const CHARGE_TIMEOUT := 2.5
const QUEUE_LIFETIME := 1.5
const PUSHBACK := 0.5       # seconds a hit adds to a running cast...
const MAX_PUSHBACKS := 2    # ...for the first two hits of that cast, like WoW

var p: Player
var target_path := NodePath("") # what the client has targeted (validated on use)
var charging := false

var _gcd_ready := 0.0
var _cooldowns := {}        # ability_id -> ready time
var _next_swing := 0.0
var _cast := {}             # {id, target_path, end}
var _queued := {}           # {id, target_path, until}
var _shot := {}             # wand wind-up {end}
var _projectiles: Array = [] # [{target, arrive, ability, dmg}]
var _dots: Array = []        # [{target, dmg, next_tick, until, name}]
var _charge_target: Node = null
var _charge_until := 0.0
var _charge_last_pos := Vector3.ZERO
var _charge_blocked_ticks := 0
var _facing_warned_at := -100.0


func _init(player: Player) -> void:
	p = player


static func now() -> float:
	return Unit.now()


func target() -> Unit:
	if target_path.is_empty():
		return null
	var t := p.get_node_or_null(target_path)
	if t is Unit and not t.is_dead and t.faction != p.faction:
		return t
	return null


func is_casting() -> bool:
	return not _cast.is_empty()


## Debug/test view of the running cast and the queued press.
func cast_state() -> Dictionary:
	return _cast


func queued() -> Dictionary:
	return _queued


func winding_up() -> bool:
	return not _shot.is_empty()


func on_death() -> void:
	p.auto_attack = false
	charging = false
	_cast = {}
	_queued = {}
	_shot = {}
	_projectiles = []
	p.casting = false


func tick() -> void:
	_tick_cast()
	_tick_queue()
	_tick_projectiles()
	_tick_dots()
	_tick_auto_attack()


# ---------------------------------------------------------------- abilities

func use(ability_id: String, path: NodePath) -> void:
	if p.is_dead or not GameData.ABILITIES.has(ability_id) or not GameData.class_bar(p.class_id).has(ability_id):
		return
	if p.is_ghost:
		p.say("You can't do that while dead.")
		return
	var ab: Dictionary = GameData.ABILITIES[ability_id]
	target_path = path
	var t := target()

	if ab.kind == "toggle":
		if t == null:
			p.say("You have no target.")
			return
		p.stop_consuming()
		_set_auto_attack(not p.auto_attack)
		if not p.auto_attack:
			_cancel_shot()
		return

	if now() < p.stun_until:
		p.say("You are stunned.")
		return
	p.stop_consuming()
	if is_casting():
		if _cast.end - now() <= GameData.SPELL_QUEUE_WINDOW:
			_queued = {"id": ability_id, "target_path": path, "until": now() + QUEUE_LIFETIME}
		else:
			p.say("Another action is in progress.")
		return
	if ab.triggers_gcd and now() < _gcd_ready:
		if _gcd_ready - now() <= GameData.SPELL_QUEUE_WINDOW:
			_queued = {"id": ability_id, "target_path": path, "until": now() + QUEUE_LIFETIME}
		return
	if _cooldowns.get(ability_id, 0.0) > now():
		p.say("%s is not ready yet." % ab.name)
		return
	if p.resource < GameData.ability_cost(ab):
		p.say("Not enough %s." % p.cls().resource)
		return

	var ok := false
	match ab.kind:
		"bolt": ok = _start_cast(ab, ability_id, t)
		"nova": ok = _aoe(ab, true)
		"aoe": ok = _aoe(ab, false)
		"blink": ok = _blink(ab)
		"melee": ok = _melee(ab, t)
		"charge": ok = _charge(ab, t)
	if not ok:
		return
	if ab.kind != "bolt":
		p.spend_resource(GameData.ability_cost(ab)) # casts pay when they land
	if ab.cooldown > 0.0:
		_cooldowns[ability_id] = now() + ab.cooldown
		p.notify("cooldown", [ability_id, ab.cooldown])
	if ab.triggers_gcd:
		_gcd_ready = now() + GameData.GCD
		p.notify("gcd", [GameData.GCD])


func _set_auto_attack(on: bool) -> void:
	p.auto_attack = on
	p.notify("auto_attack", [on])


func _needs_target(t: Unit) -> bool:
	if t == null:
		p.say("You have no target.")
	return t != null


func _in_range(t: Unit, max_range: float) -> bool:
	if p.global_position.distance_to(t.global_position) > max_range:
		p.say("Target is out of range.")
		return false
	return true


## WoW-style facing: the target has to be inside the ~140° arc in front of the character.
func facing(t: Node3D) -> bool:
	var d := t.global_position - p.global_position
	d.y = 0.0
	if d.length_squared() < 0.25:
		return true
	var fwd := Basis(Vector3.UP, p.rotation.y) * Vector3(0, 0, -1)
	return fwd.dot(d.normalized()) >= GameData.FACING_COS


func _check_facing(t: Node3D) -> bool:
	if facing(t):
		return true
	if now() - _facing_warned_at > 1.0:
		_facing_warned_at = now()
		p.say("Target needs to be in front of you.")
	return false


func _spell_damage(ab: Dictionary, t: Unit) -> int:
	return GameData.roll_damage(p.rng, ab.dmg_min, ab.dmg_max, p.level, t.level, p.intellect / 2)


func _weapon_damage(t: Unit) -> int:
	var r := GameData.weapon_damage_range(p.equipment.get("weapon", ""), p.strength)
	return GameData.roll_damage(p.rng, r[0], r[1], p.level, t.level)


func _hit(t: Unit, dmg: int, label: String) -> void:
	t.take_damage(dmg, p)
	p.world.combat_event.rpc(p.display_name, p.get_path(), t.get_path(), dmg, label)


func _melee(ab: Dictionary, t: Unit) -> bool:
	if not _needs_target(t) or not _in_range(t, ab.max_range + 0.5) or not _check_facing(t):
		return false
	p.attack_tick += 1
	var own := GameData.roll_damage(p.rng, ab.dmg_min, ab.dmg_max, p.level, t.level)
	_hit(t, own + _weapon_damage(t) / 2, ab.name) # _weapon_damage is level-scaled already
	if not p.auto_attack:
		_set_auto_attack(true)
	return true


## Thunder Clap (slow) and Frost Nova (root): everything within ab.radius.
func _aoe(ab: Dictionary, root: bool) -> bool:
	p.attack_tick += 1
	var hits := 0
	for m in p.get_tree().get_nodes_in_group("monsters"):
		if m.is_dead or p.global_position.distance_to(m.global_position) > ab.radius:
			continue
		var dmg := _spell_damage(ab, m) if root else GameData.roll_damage(p.rng, ab.dmg_min, ab.dmg_max, p.level, m.level)
		_hit(m, dmg, ab.name)
		if root:
			m.apply_root(ab.root)
		else:
			m.apply_slow(ab.slow, ab.slow_duration)
		hits += 1
	if hits == 0:
		p.say("No enemies in range.")
		return false
	if not root and not p.auto_attack and target() != null:
		_set_auto_attack(true)
	return true


func _blink(ab: Dictionary) -> bool:
	var fwd := Basis(Vector3.UP, p.input_yaw) * Vector3(0, 0, -1)
	var dest: Vector3 = p.global_position + fwd * float(ab.distance)
	dest.y = p.world.height_at(dest.x, dest.z) + 0.6
	p.world.vfx_event.rpc("blink", p.get_path(), p.get_path())
	p.global_position = dest
	p.velocity = Vector3.ZERO
	p.world.vfx_event.rpc("blink_arrive", p.get_path(), p.get_path())
	return true


func _charge(ab: Dictionary, t: Unit) -> bool:
	if not _needs_target(t):
		return false
	var dist := p.global_position.distance_to(t.global_position)
	if dist < ab.min_range:
		p.say("Target is too close.")
		return false
	if not _in_range(t, ab.max_range):
		return false
	charging = true
	_charge_target = t
	_charge_until = now() + CHARGE_TIMEOUT
	_charge_blocked_ticks = 0
	_charge_last_pos = p.global_position
	p.world.vfx_event.rpc("charge_start", p.get_path(), t.get_path())
	return true


func tick_charge() -> void:
	var ab: Dictionary = GameData.ABILITIES.charge
	if not is_instance_valid(_charge_target) or _charge_target.is_dead or now() > _charge_until:
		_stop_charge()
		return
	var to_t: Vector3 = _charge_target.global_position - p.global_position
	to_t.y = 0
	var dist := to_t.length()
	if dist <= GameData.MELEE_RANGE:
		_stop_charge()
		p.attack_tick += 1
		_charge_target.apply_stun(ab.stun)
		_hit(_charge_target, 0, "Charge") # pulls aggro without damage
		p.gain_rage(ab.rage_gain)
		return
	var dir := to_t / dist
	p.velocity.x = dir.x * ab.speed
	p.velocity.z = dir.z * ab.speed
	p.rotation.y = atan2(-dir.x, -dir.z)
	if p.is_on_floor() and p.velocity.y < 0:
		p.velocity.y = -0.1
	# Blocked by a tree or rock? Don't stand there pushing for 2.5 s; drop the charge.
	if p.global_position.distance_to(_charge_last_pos) < 0.05:
		_charge_blocked_ticks += 1
		if _charge_blocked_ticks > 12:
			_stop_charge()
			_cooldowns["charge"] = now() + 2.0
			p.notify("cooldown", ["charge", 2.0])
			p.say("Your path is blocked.")
	else:
		_charge_blocked_ticks = 0
	_charge_last_pos = p.global_position


func _stop_charge() -> void:
	charging = false
	p.velocity.x = 0
	p.velocity.z = 0


# ---------------------------------------------------------------- casting

func _start_cast(ab: Dictionary, ability_id: String, t: Unit) -> bool:
	if not _needs_target(t) or not _in_range(t, ab.max_range):
		return false
	if p.moving or p.airborne:
		p.say("You can't cast while moving.")
		return false
	if not _check_facing(t):
		return false
	_cancel_shot()
	_cast = {"id": ability_id, "target_path": t.get_path(), "end": now() + ab.cast, "pushbacks": 0}
	p.casting = true
	p.last_combat_time = now()
	p.notify("cast", [ability_id, ab.cast])
	p.world.vfx_event.rpc("cast_start:" + ability_id, p.get_path(), t.get_path())
	return true


## Spell pushback: a hit while casting delays the cast a little (wand shots are not affected).
func pushback() -> void:
	if is_casting() and _cast.pushbacks < MAX_PUSHBACKS:
		_cast.pushbacks += 1
		_cast.end += PUSHBACK
		p.notify("cast_pushback", [PUSHBACK])


func cancel_cast(reason := "") -> void:
	if _cast.is_empty():
		return
	_end_cast()
	_queued = {}
	p.world.vfx_event.rpc("cast_stop", p.get_path(), p.get_path())
	if reason != "":
		p.say(reason)


func _end_cast() -> void:
	_cast = {}
	p.casting = false
	p.notify("cast", ["", 0.0])


func _tick_cast() -> void:
	if _cast.is_empty():
		return
	if p.moving or p.airborne or now() < p.stun_until:
		cancel_cast("Interrupted.")
		return
	var t := p.get_node_or_null(_cast.target_path) as Unit
	if t == null or t.is_dead or t.faction == p.faction:
		cancel_cast("Your target is dead.")
		return
	if now() < _cast.end:
		return
	var ab: Dictionary = GameData.ABILITIES[_cast.id]
	_end_cast()
	if not facing(t):
		# The cast ran its course but fizzles: nothing happens and no mana is spent.
		_queued = {}
		p.world.vfx_event.rpc("cast_stop", p.get_path(), p.get_path())
		p.say("Target needs to be in front of you.")
		return
	if not _in_range(t, ab.max_range + 2.0):
		return
	p.spend_resource(GameData.ability_cost(ab))
	p.attack_tick += 1
	_launch(ab, t, _spell_damage(ab, t), p.global_position.distance_to(t.global_position) / float(ab.speed), ab.vfx)


func _tick_queue() -> void:
	if _queued.is_empty():
		return
	if now() > _queued.until:
		_queued = {}
	elif not is_casting() and now() >= _gcd_ready:
		var q := _queued
		_queued = {}
		use(q.id, q.target_path)


# ---------------------------------------------------------------- projectiles & dots

func _launch(ab: Dictionary, t: Unit, dmg: int, travel: float, vfx: String) -> void:
	_projectiles.append({"target": t, "arrive": now() + travel, "ability": ab, "dmg": dmg})
	p.world.vfx_event.rpc(vfx, p.get_path(), t.get_path())
	p.last_combat_time = now()


func _tick_projectiles() -> void:
	if _projectiles.is_empty():
		return
	var keep := []
	for pr in _projectiles:
		if now() < pr.arrive:
			keep.append(pr)
			continue
		var t: Unit = pr.target
		if not is_instance_valid(t) or t.is_dead:
			continue
		var ab: Dictionary = pr.ability
		_hit(t, pr.dmg, ab.name)
		if ab.has("slow"):
			t.apply_slow(ab.slow, ab.slow_duration)
		if ab.has("dot"):
			_dots = _dots.filter(func(d): return not (d.target == t and d.name == ab.name))
			_dots.append({"target": t, "dmg": int(ab.dot), "next_tick": now() + 1.0, "until": now() + ab.dot_duration, "name": ab.name})
			t.burn_until = now() + ab.dot_duration
	_projectiles = keep


func _tick_dots() -> void:
	if _dots.is_empty():
		return
	var keep := []
	for d in _dots:
		var t: Unit = d.target
		if not is_instance_valid(t) or t.is_dead or now() > d.until:
			continue
		if now() >= d.next_tick:
			d.next_tick += 1.0
			_hit(t, d.dmg, d.name + " (burn)")
		keep.append(d)
	_dots = keep


# ---------------------------------------------------------------- auto-attack

func _tick_auto_attack() -> void:
	var t := target() if p.auto_attack else null
	if t == null:
		_cancel_shot() # a wind-up must never outlive the attack it belongs to (stuck cast pose)
		if p.auto_attack:
			_set_auto_attack(false)
		return
	if now() < _next_swing or now() < p.stun_until or is_casting():
		_cancel_shot()
		return
	var c := p.cls()
	if p.global_position.distance_to(t.global_position) > c.attack_range + 0.5:
		_cancel_shot()
		return
	if c.ranged:
		_tick_wand_shot(t)
		return
	if not _check_facing(t):
		return
	_next_swing = now() + c.attack_speed
	p.attack_tick += 1
	_hit(t, _weapon_damage(t), "melee")
	p.gain_rage(c.rage_per_swing)


## Wand shots are a short wind-up (shown as a cast bar) that moving cancels, so a mage can't
## kite forever while plinking: you have to stop and stand still to get the shot off.
func _tick_wand_shot(t: Unit) -> void:
	if _shot.is_empty():
		if p.moving or p.airborne or not _check_facing(t):
			return
		_shot = {"end": now() + GameData.WAND_WINDUP}
		p.casting = true
		p.notify("cast", ["shoot", GameData.WAND_WINDUP])
		return
	if p.moving or p.airborne or now() < p.stun_until:
		_cancel_shot()
		return
	if now() < _shot.end:
		return
	_cancel_shot()
	if not _check_facing(t):
		return
	_next_swing = now() + p.cls().attack_speed
	p.attack_tick += 1
	_launch({"name": "melee"}, t, _weapon_damage(t), 0.25, "wand_shot")


func _cancel_shot() -> void:
	if _shot.is_empty():
		return
	_shot = {}
	p.casting = false
	p.notify("cast", ["", 0.0])
