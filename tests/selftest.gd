## In-process self-test, run on a single host instance by tests/smoke_test.sh:
##   godot --headless -- --host --selftest --autoquit=60
## Walks the whole game loop against the real server code: lobby, death and corpse run, quests,
## vendor, eating and regen, stacking, persistence round-trip, the mage's spells with the WoW
## casting rules, social aggro, the wand wind-up and leaving the world. Prints one
## "[selftest] ok/FAIL ..." line per check and "[selftest] done" at the end.
extends Node

var main: Node
var world: Node
var _checks := 0


func ok(cond: bool, what: String) -> void:
	_checks += 1
	print("[selftest] %s %s" % ["ok  " if cond else "FAIL", what])


func wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func frames(n: int) -> void:
	for i in range(n):
		await get_tree().physics_frame


## Physics-space height of whatever is walkable at (x, z): terrain or cave rock.
func _ground_y(at: Vector2) -> float:
	var q := PhysicsRayQueryParameters3D.create(Vector3(at.x, 40.0, at.y), Vector3(at.x, -40.0, at.y), 1)
	var hit: Dictionary = world.get_world_3d().direct_space_state.intersect_ray(q)
	return hit.position.y if hit else -999.0


func ground(x: float, z: float) -> Vector3:
	return Vector3(x, world.height_at(x, z) + 0.6, z)


func local_player() -> Player:
	return get_tree().get_first_node_in_group("local_player")


## A living monster of this kind on the surface (cave dwellers live below the terrain).
func find_monster(kind: String, exclude: Node = null) -> Monster:
	for m in get_tree().get_nodes_in_group("monsters"):
		if m.kind == kind and not m.is_dead and m != exclude and m.home.y > world.height_at(m.home.x, m.home.z) - 1.0:
			return m
	return null


func bag_index(p: Player, id: String) -> int:
	for i in range(p.inventory.size()):
		if p.inventory[i].id == id:
			return i
	return -1


func run(main_node: Node) -> void:
	main = main_node
	world = main.world
	await _lobby_and_warrior()
	await _mage()
	await _cave()
	await _leave()
	print("[selftest] done (%d checks)" % _checks)
	get_tree().quit()


func _lobby_and_warrior() -> void:
	# --- lobby: fresh account, create + enter a warrior
	Persistence.delete_character("selftest", "Tester")
	Persistence.delete_character("selftest", "Magi")
	Net.request("create", ["Tester", "warrior"])
	ok(main.characters.size() == 1 and main.characters[0].name == "Tester", "character created and listed")
	Net.request("enter", ["Tester"])
	await wait(1.0)
	var p := local_player()
	ok(p != null and p.char_name == "Tester" and p.class_id == "warrior", "entered the world as Tester (warrior)")
	var strays := get_tree().get_nodes_in_group("monsters").filter(func(m): return m.global_position.distance_to(m.home) > m.wander_radius + Monster.UNSTICK_MAX)
	ok(strays.is_empty(), "every monster starts near its spawn point (%d strays)" % strays.size())
	ok(p.equipment.get("weapon", "") == "worn_shortsword" and p.copper == GameData.STARTER_COPPER, "fresh character got the starter kit")
	await frames(2)
	var fist: Dictionary = GameData.MODELS.hero.fist
	var body: MeshInstance3D = p.model.find_children("*", "MeshInstance3D", true, false).front()
	var shape := body.find_blend_shape_by_name(fist.shape)
	var skel: Skeleton3D = body.get_parent() if body.get_parent() is Skeleton3D else p.model.find_children("*", "Skeleton3D", true, false).front()
	var hand := skel.global_transform * skel.get_bone_global_pose(skel.find_bone(fist.bone)).origin
	var grip_d := INF
	for a in p._attachments:
		if a.bone_name == fist.bone and a.get_child_count() > 0:
			grip_d = a.get_child(0).global_position.distance_to(hand)
	ok(shape >= 0 and body.get_blend_shape_value(shape) == 1.0 and grip_d < 0.2,
		"weapon hand is a closed fist with the sword's grip in it (grip %.2f m from the wrist)" % grip_d)

	# --- death, release, corpse run
	var boar := find_monster("boar")
	ok(boar != null, "found a boar")
	var death_pos: Vector3 = p.global_position
	p.take_damage(9999, boar)
	ok(p.is_dead and p.has_corpse, "player died and left a corpse")
	p.request("release")
	await frames(2)
	ok(p.is_ghost and not p.is_dead, "released: is a ghost")
	await get_tree().process_frame
	ok(world.spirit_realm, "spirit realm look enabled for the ghost")
	ok(p.anim != null and p.anim.has_animation("jump"), "model has a jump animation")
	ok(Vector2(p.global_position.x, p.global_position.z).distance_to(GameData.GRAVEYARD) < 3.0, "ghost stands at the graveyard")
	ok(p.take_damage(10, boar) == 0, "ghost takes no damage")
	p.request("resurrect")
	ok(p.is_ghost, "resurrect refused far from corpse")
	p.global_position = death_pos + Vector3(2, 0, 0)
	p.request("resurrect")
	ok(not p.is_ghost and not p.has_corpse and p.health > 0, "resurrected at the corpse")
	await get_tree().process_frame
	ok(not world.spirit_realm, "spirit realm look cleared after resurrecting")

	# --- quest turn-in
	p.global_position = world.player_spawn
	ok(GameData.available_quest("ottar", p.quests) == "", "Ottar has nothing for a newcomer yet")
	ok(GameData.available_quest("edric", p.quests) == "wolves_at_the_treeline", "Edric's wolf quest is open from the start, beside Boar Trouble")
	var edric: Node3D = world.get_npc("edric")
	p.global_position = edric.global_position + edric.global_transform.basis.z * 1.5 + Vector3(0, 0.1, 0) # beside Edric
	p.request("npc", ["edric", "accept", null])
	for i in range(6):
		p.on_kill("wolf")
	for i in range(4):
		p.gear.add_item("wolf_pelt")
	p.questlog.refresh_collect_progress()
	p.request("npc", ["edric", "complete", null])
	ok(p.quests.has("wolves_at_the_treeline") and p.quests.wolves_at_the_treeline.state == "done" and GameData.count_in(p.inventory, "wolfhide_boots") == 1, "wolf quest turned in for the boots")
	p.global_position = world.player_spawn
	p.request("npc", ["brannoc", "accept", null])
	ok(p.quests.has("boar_trouble"), "accepted Boar Trouble")
	for i in range(6):
		p.on_kill("boar")
	for i in range(4):
		p.gear.add_item("boar_tusk")
	p.questlog.refresh_collect_progress()
	ok(GameData.quest_complete(GameData.quest("boar_trouble"), p.quests.boar_trouble.progress), "objectives complete")
	var copper_before: int = p.copper
	p.request("npc", ["brannoc", "complete", null])
	ok(p.quests.boar_trouble.state == "done", "quest turned in")
	ok(p.copper == copper_before + 60, "copper reward paid")
	ok(GameData.count_in(p.inventory, "honey_bread") == 2 and GameData.count_in(p.inventory, "boar_tusk") == 0, "tusks taken, bread given (stacked)")
	ok(GameData.available_quest("brannoc", p.quests) == "troll_raiders", "follow-up quest unlocked")
	ok(GameData.available_quest("ottar", p.quests) == "the_chief_below", "Ottar's Gorrak quest unlocked at the same time")
	p.request("npc", ["ottar", "accept", null])
	p.on_kill("troll_brute")
	ok(p.quests.has("the_chief_below") and GameData.quest_complete(GameData.quest("the_chief_below"), p.quests.the_chief_below.progress), "killing Gorrak completes The Thing Below")

	# --- vendor
	var c: int = p.copper
	p.request("npc", ["hollis", "buy", "roasted_boar"])
	ok(p.copper == c - 30 and GameData.count_in(p.inventory, "roasted_boar") == 1, "bought roasted boar")
	p.request("npc", ["hollis", "sell", bag_index(p, "roasted_boar")])
	ok(p.copper == c - 30 + 6 and GameData.count_in(p.inventory, "roasted_boar") == 0, "sold it back")

	# --- eating: sits, heals over time, cancelled by damage; passive regen
	await wait(0.5) # land after the teleport above
	p.health = 10
	p.last_combat_time = -100.0
	p.gear.add_item("tough_jerky")
	p.request("equip", [bag_index(p, "tough_jerky")])
	ok(p.sitting, "eating makes you sit")
	var hp_start: int = p.health
	await wait(2.3)
	ok(p.sitting and p.health > hp_start and p.health < hp_start + 40, "food heals gradually while sitting (%d -> %d)" % [hp_start, p.health])
	p.gear.add_item("spring_water")
	p.request("equip", [bag_index(p, "spring_water")])
	ok(p.sitting and p.consuming.has("food") and p.consuming.has("drink"), "drinking on top of eating keeps both going")
	p.consuming.food.ticks = 1
	await wait(1.2)
	ok(p.sitting and not p.consuming.has("food") and p.consuming.has("drink"), "still sitting after the food is finished while the drink runs")
	p.take_damage(1, boar)
	ok(not p.sitting and p.consuming.is_empty(), "taking damage stops eating and drinking")
	p.health = 50
	p.last_combat_time = -100.0
	await wait(3.0)
	ok(p.health > 50 and p.health < 56, "health regenerates slowly out of combat (50 -> %d after 3 s)" % p.health)

	# --- stacking
	for i in range(12):
		p.gear.add_item("boar_tusk")
	var tusk_slots := p.inventory.filter(func(slot): return slot.id == "boar_tusk").size()
	ok(GameData.count_in(p.inventory, "boar_tusk") == 12 and tusk_slots == 1, "12 tusks occupy one stack")
	ok(p.gear.remove_items("boar_tusk", 5) == 5 and GameData.count_in(p.inventory, "boar_tusk") == 7, "removed 5 from the stack")

	# --- persistence: save, kick, re-enter, compare
	var before: Dictionary = p.save_data()
	Net.save_player(p)
	var loaded := Persistence.load_character("selftest", "Tester")
	ok(loaded.copper == before.copper and loaded.level == before.level and loaded.quests.has("boar_trouble"), "save file round-trips")
	world.server_remove_player(1)
	Net.entered.erase(1)
	await frames(2)
	Net.request("enter", ["Tester"])
	await frames(1)
	p = local_player()
	ok(p.copper == before.copper and p.level == before.level and p.quests.boar_trouble.state == "done"
		and GameData.count_in(p.inventory, "honey_bread") == 2, "re-entered with the same copper, level, quests and bag")
	ok(p.global_position.distance_to(Vector3(before.pos[0], before.pos[1], before.pos[2])) < 1.5, "position restored")


func _mage() -> void:
	world.server_remove_player(1)
	Net.entered.erase(1)
	await frames(1)
	Net.request("create", ["Magi", "mage"])
	Net.request("enter", ["Magi"])
	await frames(1)
	var p := local_player()
	ok(p.class_id == "mage" and p.uses_mana() and p.resource == p.max_resource and p.equipment.get("weapon", "") == "apprentice_wand", "mage spawned with full mana and a wand")
	p.max_health = 99999 # keep the test mage alive whatever the troll pack does to it
	p.health = 99999

	# 12 m east of a living troll, facing it; a second idle troll next to it for social aggro.
	# Two trolls moved to a known clear patch of hillside (south-west), so nothing else is near.
	var mob := find_monster("troll")
	mob.global_position = ground(-30, 30)
	mob.home = mob.global_position # keep it from leashing home mid-test
	for m in get_tree().get_nodes_in_group("monsters"):
		m.apply_stun(600.0) # nobody hits the mage: pushback would make the cast timings below unpredictable
	var mob2 := find_monster("troll", mob)
	mob2.global_position = ground(-30, 34)
	mob2.home = mob2.global_position
	mob2.state = "idle"
	var stand := func() -> void:
		p.global_position = ground(mob.global_position.x + 12, mob.global_position.z)
		p.input_yaw = atan2(-(mob.global_position.x - p.global_position.x), -(mob.global_position.z - p.global_position.z))
	stand.call()
	p.targeting.set_target(mob)
	await wait(0.5) # land after the teleport (jumping/falling interrupts casts)

	# --- frostbolt, fireball, nova, blink
	var hp0: int = mob.health
	p.use_ability("frostbolt")
	ok(p.combat.is_casting(), "frostbolt started casting")
	await wait(2.3)
	ok(not p.combat.is_casting() and p.resource <= p.max_resource - 16, "cast finished and cost mana (%d/%d)" % [p.resource, p.max_resource])
	await wait(1.0)
	ok(mob.health < hp0 and mob.speed_multiplier() < 1.0, "frostbolt hit and slowed the troll")
	ok(mob.effects & Unit.EFFECT_SLOW, "troll shows the slowed effect (effects=%d)" % mob.effects)
	ok(mob2.state == "chase", "social aggro: the troll next to it joined the fight (mob=%s mob2=%s)" % [mob.state, mob2.state])
	mob2.global_position = mob2.home + Vector3(0, 0, 60) # send it away for the rest of the test
	mob2.home = mob2.global_position
	mob2.state = "idle"
	mob2._target = null
	mob2._threat.clear()
	mob.heal_full()
	p.use_ability("fireball")
	await wait(3.8)
	var hit_fire: bool = mob.health < mob.max_health
	mob.heal_full()
	await wait(1.6)
	ok(hit_fire and mob.health < mob.max_health, "fireball landed and is burning")
	ok(mob.effects & Unit.EFFECT_BURN, "troll shows the burning effect (effects=%d)" % mob.effects)
	mob.heal_full()
	p.global_position = ground(mob.global_position.x + 2, mob.global_position.z)
	p.use_ability("frost_nova")
	ok(mob.speed_multiplier() == 0.0 and mob.health < mob.max_health, "frost nova rooted and damaged")
	await frames(2)
	ok(mob.effects & Unit.EFFECT_ROOT, "troll shows the rooted effect (effects=%d)" % mob.effects)
	var bx: Vector3 = p.global_position
	p.use_ability("blink")
	ok(bx.distance_to(p.global_position) > 10.0, "blink moved the mage %.1f m" % bx.distance_to(p.global_position))
	mob.heal_full()
	await wait(2.0) # global cooldown over, nothing queued

	# --- interrupts: stun
	stand.call()
	p.targeting.set_target(mob)
	p.resource = p.max_resource
	await wait(0.5) # land and settle
	p.use_ability("frostbolt")
	var casting_before: bool = p.combat.is_casting()
	p.apply_stun(0.5)
	await frames(2)
	ok(casting_before and not p.combat.is_casting(), "stun interrupted the cast (before=%s after=%s)" % [casting_before, p.combat.is_casting()])
	await wait(2.0)

	# --- facing: can't start a cast on a target behind you; turning away mid-cast fizzles it at the end
	p.resource = p.max_resource
	var facing_yaw: float = p.input_yaw
	p.input_yaw = facing_yaw + PI
	await frames(2)
	p.use_ability("frostbolt")
	ok(not p.combat.is_casting(), "cast refused with the target behind the mage")
	p.input_yaw = facing_yaw
	await frames(2)
	p.use_ability("frostbolt")
	var started: bool = p.combat.is_casting()
	await wait(0.5)
	p.input_yaw = facing_yaw + PI
	await frames(2)
	ok(started and p.combat.is_casting(), "turning away mid-cast does not interrupt it")
	var mana_at_turn: int = p.resource
	mob.heal_full()
	await wait(1.8) # cast ends while still facing away
	ok(not p.combat.is_casting() and p.resource == mana_at_turn and mob.health == mob.max_health, "cast fizzled at the end: no mana spent, no hit")
	p.input_yaw = facing_yaw
	await wait(2.0)

	# --- spell queue: a press near the end of a cast fires right after it instead of cancelling it
	mob.heal_full()
	p.resource = p.max_resource
	stand.call()
	await wait(0.4) # land
	p.use_ability("frostbolt")
	await wait(0.5)
	p.use_ability("fireball") # too early to queue: refused, the cast carries on
	ok(p.combat.is_casting() and p.combat.cast_state().id == "frostbolt" and p.combat.queued().is_empty(), "early press neither cancels nor queues (another action is in progress)")
	await wait(1.2) # 0.3 s before the 2 s cast ends
	p.use_ability("fireball")
	ok(p.combat.is_casting() and p.combat.cast_state().id == "frostbolt" and not p.combat.queued().is_empty(), "late press queued instead of cancelling")
	await wait(0.5)
	ok(p.combat.is_casting() and p.combat.cast_state().id == "fireball", "queued fireball started right after frostbolt")

	# --- wand: Shoot toggles a wind-up that moving cancels
	await wait(3.0) # let the queued fireball finish
	mob.heal_full()
	p.use_ability("shoot")
	await wait(0.3)
	ok(p.auto_attack and p.combat.winding_up() and p.casting, "wand shot winds up before firing")
	await wait(0.6)
	ok(not p.combat.winding_up(), "wand shot fired after the wind-up")
	await wait(0.8)
	ok(mob.health < mob.max_health, "wand shot hit the troll")
	p.use_ability("shoot")
	ok(not p.auto_attack, "shoot toggled off")

	# --- a wind-up whose target dies must not leave the mage stuck in the cast pose
	await wait(1.6) # swing timer
	p.use_ability("shoot")
	await wait(0.3)
	ok(p.casting and p.combat.winding_up(), "wind-up running")
	p.targeting.set_target(null)
	await frames(2)
	ok(not p.casting and not p.auto_attack, "losing the target during the wind-up clears the cast pose")
	p.targeting.set_target(mob)

	# --- spell pushback: a hit delays the cast
	p.resource = p.max_resource
	await wait(1.6)
	p.use_ability("frostbolt")
	var end_before: float = p.combat.cast_state().end
	p.take_damage(1, mob)
	ok(p.combat.is_casting() and p.combat.cast_state().end > end_before + 0.4, "taking damage pushed the cast back")
	p.request("cancel_cast")
	await wait(1.6)

	# --- the target dying mid-cast interrupts the cast
	p.resource = p.max_resource
	await wait(1.6)
	p.use_ability("frostbolt")
	ok(p.combat.is_casting(), "frostbolt cast started again for the death test")
	mob.take_damage(999999, p)
	await frames(2)
	ok(mob.is_dead and not p.combat.is_casting(), "cast interrupted when the target died")

	# --- vfx: run every effect once so script errors surface in the log
	var v: Node = world.vfx
	v.heroic_strike(p, mob)
	v.thunder_clap(p)
	v.charge_start(p)
	v.charge_impact(p, mob)
	v.melee_hit(mob, true)
	v.level_up(p)
	v.on_combat_event(mob, p, 3, "melee")
	v.on_combat_event(p, mob, 0, "dies")
	for k in ["frostbolt", "fireball", "wand_shot", "cast_start", "cast_stop", "blink", "blink_arrive"]:
		v.play(k, p, mob)
	v.on_combat_event(p, mob, 5, "Frost Nova")
	await wait(1.5)
	ok(true, "vfx effects ran without errors (see log)")


func _cave() -> void:
	# --- the troll cave: built from assets/caves/warren.out.json, cut into the terrain, populated
	var cave: Cave = world.caves[0]
	ok(cave.find_children("*", "MeshInstance3D", true, false).size() > 0 and cave.find_children("*", "CollisionShape3D", true, false).size() > 0, "cave mesh and collider loaded")
	var hole: Dictionary = cave.hole()
	ok(world.terrain.in_hole(hole.b.x, hole.b.y) and not world.terrain.in_hole(0.0, 0.0), "terrain has a hole at the cave entrance")
	var out_dir: Vector2 = (hole.b - hole.a).normalized()
	var floor_y := _ground_y(hole.b - out_dir * 0.5)       # cave rock, inside the trench's end
	var ground_y := _ground_y(hole.b + out_dir * 2.5)      # terrain, just past it
	ok(absf(ground_y - floor_y) < 0.3, "ground meets the cave floor at the end of the trench (%.2f m lip)" % (ground_y - floor_y))
	var tg: Dictionary = cave.data.get("terrain", {})
	ok(int(tg.get("grid", 0)) == Terrain.GRID and absf(float(tg.get("spacing", 0.0)) - Terrain.SPACING) < 0.001, "cave was baked for this terrain grid (%d x %.0f m)" % [Terrain.GRID, Terrain.SPACING])
	var drift := 0.0
	for pr in cave.data.get("probes", []):
		drift = maxf(drift, absf(world.height_at(pr[0], pr[1]) - pr[2]))
	ok(cave.data.get("probes", []).size() >= 12 and drift < 0.02, "terrain hill matches the bake's hill formula (max drift %.3f m over %d probes)" % [drift, int(cave.data.get("probes", []).size())])
	var chief: Monster = null
	var dwellers := 0
	for m in get_tree().get_nodes_in_group("monsters"):
		if m.home.y < world.height_at(m.home.x, m.home.z) - 2.0:
			dwellers += 1
		if m.kind == "troll_brute":
			chief = m
	ok(dwellers >= 9 and chief != null and chief.home.y < world.height_at(chief.home.x, chief.home.z) - 5.0, "%d trolls and Gorrak spawned underground" % dwellers)
	ok(chief != null and chief.model.scale.x > 1.3 and chief.max_health > 300, "Gorrak is big and tough")
	var p := local_player()
	var drops := 0
	for i in range(20):
		var got := GameData.roll_loot("troll_brute", p.rng)
		drops += int(got.has("gorraks_bonebreaker")) + int(got.has("mossback_staff"))
	ok(drops == 20, "Gorrak always drops exactly one of his two weapons")
	# Walk in: stand on the surface just outside the hole, face the shaft, hold forward.
	p.max_health = 99999
	p.health = 99999
	var mouth_dir: Vector2 = (hole.a - hole.b).normalized()
	var start: Vector2 = hole.b - mouth_dir * (hole.radius + 2.0)
	p.global_position = Vector3(start.x, world.height_at(start.x, start.y) + 0.6, start.y)
	p.input_yaw = atan2(-mouth_dir.x, -mouth_dir.y)
	await wait(0.5)
	var y_surface: float = p.global_position.y
	p.is_local = false # the host's keyboard polling would overwrite our simulated input
	p.input_dir = Vector2(0, -1)
	await wait(5.0)
	p.input_dir = Vector2.ZERO
	await wait(0.5)
	p.is_local = true
	var dropped: float = y_surface - p.global_position.y
	ok(p.is_on_floor() and dropped > 3.0 and dropped < 12.0, "walked down the entrance shaft onto the cave floor (%.1f m below the surface)" % dropped)
	# Pathfinding: the navmesh reaches from the camp down into the boss room (the cave floor is
	# part of it), and a monster stuck inside a tree snaps back onto walkable ground.
	var nav_map: RID = world.get_world_3d().navigation_map
	var boss_room: Array = cave.data.boss_room
	var path := NavigationServer3D.map_get_path(nav_map, world.player_spawn, Vector3(boss_room[0], boss_room[1], boss_room[2]), true)
	var reaches := path.size() > 4 and path[path.size() - 1].distance_to(Vector3(boss_room[0], boss_room[1], boss_room[2])) < 4.0
	ok(world.nav_region.navigation_mesh.get_polygon_count() > 1000 and reaches, "navmesh path from the camp into the boss room (%d waypoints)" % path.size())
	var tree: Node3D = null
	for n in world.get_node("Map/Forest").get_children():
		if n is StaticBody3D and n.collision_layer == 4 and n.global_position.length() > 40.0 and n.global_position.length() < 80.0:
			tree = n
			break
	var m := find_monster("boar")
	var tree_pos: Vector3 = tree.global_position
	m.global_position = tree_pos + Vector3(0, 0.5, 0)
	m._unstick()
	var off_tree: float = Vector2(m.global_position.x - tree_pos.x, m.global_position.z - tree_pos.z).length()
	ok(off_tree > 0.3 and off_tree < 4.0, "monster spawned inside a tree is nudged out onto the navmesh (%.1f m)" % off_tree)
	# Tagging and loot rights: the first player to engage a monster owns the kill and its loot.
	var tm := find_monster("boar")
	tm._aggro(p)
	ok(tm.tagged_peer == p.peer_id, "engaging a monster tags it for that player")
	tm.state = "idle"
	tm.tagged_peer = 0
	world.spawn_loot(p.global_position + Vector3(1, 0, 0), ["boar_tusk"], 999)
	await wait(0.2)
	var others_bag: Node = p.nearest_loot(3.5)
	var tusks_before := GameData.count_in(p.inventory, "boar_tusk")
	p.request("loot", [others_bag.get_path()])
	ok(not others_bag.can_loot(p.peer_id) and GameData.count_in(p.inventory, "boar_tusk") == tusks_before, "someone else's loot can't be taken")
	others_bag.queue_free()
	# Step-up: a knee-high ledge on flat ground must be walked over, not stopped by.
	var ledge := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(6.0, 1.0, 1.5)
	shape.shape = box
	ledge.add_child(shape)
	var gy: float = world.height_at(0.0, -20.0)
	ledge.position = Vector3(0, gy - 0.5 + Unit.STEP_HEIGHT - 0.1, -20.0) # its top STEP_HEIGHT - 0.1 above the grass
	world.add_child(ledge)
	p.global_position = ground(0.0, -17.0) + Vector3.UP * 0.3
	p.input_yaw = 0.0 # facing -z
	p.is_local = false
	p.input_dir = Vector2(0, -1)
	await wait(1.5)
	p.input_dir = Vector2.ZERO
	await wait(0.3)
	p.is_local = true
	ok(p.global_position.z < -22.0, "walked up and over a knee-high ledge (z = %.1f)" % p.global_position.z)
	ledge.queue_free()
	# Jumping while walking uphill (on a slope the step-up used to cancel the jump's upward speed).
	var ramp := StaticBody3D.new()
	var rshape := CollisionShape3D.new()
	var rbox := BoxShape3D.new()
	rbox.size = Vector3(4.0, 0.4, 10.0)
	rshape.shape = rbox
	ramp.add_child(rshape)
	var slope := deg_to_rad(25.0)
	var low := Vector3(8.0, world.height_at(8.0, -25.5) + 0.05, -25.5) # rises towards +z from here
	ramp.rotation.x = -slope
	ramp.position = low + Vector3(0, sin(slope), cos(slope)) * 5.0 - Vector3(0, cos(slope), -sin(slope)) * 0.2
	world.add_child(ramp)
	var jumps := 0
	p.is_local = false
	for attempt in range(3):
		p.global_position = ground(8.0, -27.0) + Vector3.UP * 0.2
		p.velocity = Vector3.ZERO
		p.input_yaw = PI # facing +z
		p.input_dir = Vector2(0, -1)
		await wait(0.9)
		p._apply_input(Vector2(0, -1), PI, true)
		var best_vy := 0.0
		var air := 0
		for f in range(20):
			await get_tree().physics_frame
			best_vy = maxf(best_vy, p.velocity.y)
			air += 0 if p.is_on_floor() else 1
		if best_vy > Player.JUMP_VELOCITY * 0.7 and air >= 8:
			jumps += 1
		p.input_dir = Vector2.ZERO
		await wait(0.8)
	p.is_local = true
	ok(jumps == 3, "can jump while walking up a 25° slope (%d of 3 presses jumped)" % jumps)
	ramp.queue_free()


func _leave() -> void:
	# --- Esc menu -> Character screen: leave the world, character saved, list shown again
	var p := local_player()
	var mana_before: int = p.resource
	Net.request("leave")
	await frames(2)
	ok(local_player() == null and main.hud == null and main.select_panel.visible, "left the world back to the character screen")
	ok(Persistence.load_character("selftest", "Magi").get("resource", -1) == mana_before, "character was saved on leaving")
