## Headless test driver for the local player (--bot): takes the first quest, buys food, then runs
## at the nearest monster (boars first while on Boar Trouble) and uses its class kit on it.
## Exercised by tests/smoke_test.sh against a dedicated server.
class_name Bot
extends RefCounted

var p: Player
var _next_think := 0.0
var _started := false
var _last_pos := Vector3.ZERO
var _stuck := 0
var _reported_interest := 0
var _started_at := 0.0
var _next_errand := 0.0


func _init(player: Player) -> void:
	p = player


func think() -> void:
	if Unit.now() < _next_think:
		return
	_next_think = Unit.now() + 0.25
	if not _started:
		_started = true
		_started_at = Unit.now()
	# Camp errands, retried until they show up in the (synced) quest log and bag: a request sent
	# while the server is still settling the new character is just refused.
	if Unit.now() >= _next_errand and Unit.now() - _started_at < 10.0:
		_next_errand = Unit.now() + 1.0
		if not p.quests.has("boar_trouble"):
			p.request("npc", ["brannoc", "accept", null])
		if not p.inventory.any(func(s): return s.id == "tough_jerky"):
			p.request("npc", ["hollis", "buy", "tough_jerky"])
	if _reported_interest == 0 and Unit.now() - _started_at > 4.0:
		# Interest management: the client should hold the monsters near the camp, not all of them.
		_reported_interest = p.get_tree().get_nodes_in_group("monsters").size()
		print("[Bot] interest: %d monsters replicated to this client" % _reported_interest)
	var target: Node = p.local_target
	if not is_instance_valid(target) or target.is_dead:
		target = _pick_target()
		p.targeting.set_target(target)
	var bag := p.nearest_loot(3.5)
	if bag:
		p.request("loot", [bag.get_path()])
	if target == null:
		p.input_dir = Vector2.ZERO
		return
	var to_target: Vector3 = target.global_position - p.global_position
	var dist := to_target.length()
	p.input_yaw = atan2(-to_target.x, -to_target.z)
	var ranged: bool = p.cls().ranged
	var want_range: float = 14.0 if ranged else p.cls().attack_range - 0.5
	p.input_dir = Vector2(0, -1) if dist > want_range else Vector2.ZERO
	# Unstuck: if we wanted to move but didn't, sidestep for a moment (tents, rocks...).
	if p.input_dir != Vector2.ZERO:
		_stuck = _stuck + 1 if p.global_position.distance_to(_last_pos) < 0.3 else 0
		if _stuck >= 2:
			p.input_dir = Vector2(1.0 if (_stuck / 4) % 2 == 0 else -1.0, -0.4)
	_last_pos = p.global_position
	if ranged:
		if dist <= 20.0:
			if not p.auto_attack:
				p.use_ability("shoot")
			p.use_ability("frostbolt")
			if dist < 5.0:
				p.use_ability("frost_nova")
		return
	if dist > 8.0 and dist < 25.0:
		p.use_ability("charge")
	if dist <= GameData.MELEE_RANGE:
		if not p.auto_attack:
			p.use_ability("auto_attack")
		p.use_ability("heroic_strike")
		p.use_ability("thunder_clap")


func _pick_target() -> Node:
	var best: Node = null
	var best_score := INF
	for m in p.get_tree().get_nodes_in_group("monsters"):
		if m.is_dead:
			continue
		var d: float = p.global_position.distance_to(m.global_position)
		if d > 60.0:
			continue
		if m.kind != "boar":
			d += 1000.0 # work on the quest: boars first
		if d < best_score:
			best_score = d
			best = m
	return best
