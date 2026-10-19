## Unit tests for pure game-data logic. Run with:
##   godot --headless --path . --script tests/test_game_data.gd
extends SceneTree

var failures := 0


func _init() -> void:
	_test_level_modifier()
	_test_xp_curve()
	_test_abilities_well_formed()
	_test_monsters_well_formed()
	_test_items()
	if failures == 0:
		print("[tests] all passed")
		quit(0)
	else:
		print("[tests] %d failure(s)" % failures)
		quit(1)


func check(cond: bool, msg: String) -> void:
	if not cond:
		failures += 1
		push_error("FAIL: " + msg)


func _test_level_modifier() -> void:
	var gd := load("res://scripts/core/game_data.gd")
	check(is_equal_approx(gd.level_modifier(1, 1), 1.0), "equal levels -> 1.0")
	check(is_equal_approx(gd.level_modifier(3, 1), 1.2), "+2 levels -> 1.2")
	check(is_equal_approx(gd.level_modifier(1, 10), 0.5), "far lower level clamps at 0.5")
	check(is_equal_approx(gd.level_modifier(20, 1), 1.5), "far higher level clamps at 1.5")


func _test_xp_curve() -> void:
	var gd := load("res://scripts/core/game_data.gd")
	check(gd.xp_for_level(1) == 100, "level 1 needs 100 xp")
	check(gd.xp_for_level(2) > gd.xp_for_level(1), "xp requirement grows")


func _test_abilities_well_formed() -> void:
	var gd := load("res://scripts/core/game_data.gd")
	for cid in gd.CLASSES:
		for id in gd.class_bar(cid):
			check(gd.ABILITIES.has(id), "class %s ability exists: %s" % [cid, id])
		var c: Dictionary = gd.CLASSES[cid]
		for slot in c.starter_gear:
			check(gd.ITEMS.has(c.starter_gear[slot]) and gd.ITEMS[c.starter_gear[slot]].slot == slot, "%s starter %s fits" % [cid, slot])
		for it in c.starter_bag:
			check(gd.ITEMS.has(it), "%s starter bag item exists: %s" % [cid, it])
	for id in gd.ABILITIES:
		var ab: Dictionary = gd.ABILITIES[id]
		for key in ["name", "cost", "cooldown", "kind", "triggers_gcd", "desc"]:
			check(ab.has(key), "ability %s has %s" % [id, key])
		if ab.has("dmg_min"):
			check(ab.dmg_min <= ab.dmg_max, "ability %s damage range sane" % id)


func _test_monsters_well_formed() -> void:
	var gd := load("res://scripts/core/game_data.gd")
	for id in gd.MONSTERS:
		var m: Dictionary = gd.MONSTERS[id]
		for key in ["name", "level", "max_health", "dmg_min", "dmg_max", "attack_speed", "speed", "aggro_radius", "leash_radius", "respawn_time", "xp", "shape", "scale"]:
			check(m.has(key), "monster %s has %s" % [id, key])
		check(m.aggro_radius < m.leash_radius, "monster %s leash > aggro" % id)
		check(m.shape in ["biped", "quadruped"], "monster %s shape known" % id)
		var model: String = m.get("model", id)
		var path: String = gd.MODELS[model].path if gd.MODELS.has(model) else "res://assets/%s.glb" % model
		check(FileAccess.file_exists(path), "monster %s model exists: %s" % [id, path])
		if m.has("weapon"):
			check(FileAccess.file_exists("res://assets/weapon_%s.glb" % m.weapon), "monster %s weapon exists" % id)
		check(FileAccess.file_exists("res://assets/audio/%s.ogg" % id), "monster %s has a voice" % id)
	for id in gd.NPCS:
		var o: Dictionary = gd.NPCS[id].get("outfit", {})
		if o.get("skin", "") != "":
			check(FileAccess.file_exists("res://assets/hero_skin_%s.png" % o.skin), "npc %s skin exists" % id)
		for part in [["weapon", "weapon"], ["shoulders", "shoulder"]]:
			if o.get(part[0], "") != "":
				check(FileAccess.file_exists("res://assets/%s_%s.glb" % [part[1], o[part[0]]]), "npc %s %s exists" % [id, part[0]])
		if o.get("armor", "") != "":
			_check_armor_set(o.armor, "npc %s" % id)


## A modelled armour set: its pieces, the body texels they hide and its chest/legs skin.
func _check_armor_set(armor_set: String, who: String) -> void:
	for f in ["armor_%s.glb", "armor_%s_cover.png", "hero_skin_%s.png"]:
		var path: String = "res://assets/" + f % armor_set
		check(FileAccess.file_exists(path), "%s armour exists: %s" % [who, path])


func _test_items() -> void:
	var gd := load("res://scripts/core/game_data.gd")
	for id in gd.ITEMS:
		var it: Dictionary = gd.ITEMS[id]
		check(it.has("name") and it.has("slot") and it.has("quality"), "item %s has name/slot/quality" % id)
		check(it.slot == "" or it.slot in gd.EQUIP_SLOTS, "item %s slot valid" % id)
		check(gd.QUALITY_COLORS.has(it.quality), "item %s quality known" % id)
		if it.slot == "weapon":
			check(it.has("dmg_min") and it.has("model"), "weapon %s has damage and model" % id)
		# the art an item names must exist (the game would silently show nothing)
		if it.has("model") and it.slot in ["weapon", "shoulders"]:
			var mesh := "res://assets/%s_%s.glb" % ["weapon" if it.slot == "weapon" else "shoulder", it.model]
			check(FileAccess.file_exists(mesh), "item %s model exists: %s" % [id, mesh])
		if it.has("skin"):
			for key in gd.MODELS:
				if not gd.MODELS[key].has("skins"):
					continue # monster bodies don't wear gear
				var png: String = gd.MODELS[key].path.get_basename() + "_skin_%s.png" % it.skin
				check(FileAccess.file_exists(png), "item %s skin exists: %s" % [id, png])
		if it.has("mesh"):
			_check_armor_set(it.mesh, "item %s" % id)

	for kind in gd.LOOT_TABLES:
		check(gd.MONSTERS.has(kind), "loot table %s matches a monster" % kind)
		for e in gd.LOOT_TABLES[kind]:
			for id in (e[0] if e[0] is Array else [e[0]]):
				check(gd.ITEMS.has(id), "loot %s exists" % id)
			check(e[1] > 0.0 and e[1] <= 1.0, "loot chance sane for %s" % [e[0]])
	check(gd.equipment_stat(gd.CLASSES.warrior.starter_gear, "armor") == 31, "warrior starter armor sums to 31 (with the pauldrons)")
	for id in gd.ITEMS:
		if gd.ITEMS[id].slot != "":
			check(gd.max_stack(id) == 1, "gear %s does not stack" % id)
	check(gd.max_stack("boar_tusk") > 1 and gd.max_stack("tough_jerky") > 1, "quest items and food stack")
	check(is_equal_approx(gd.armor_multiplier(0), 1.0), "no armor -> full damage")
	check(is_equal_approx(gd.armor_multiplier(100), 0.5), "100 armor -> half damage")
	var rng := RandomNumberGenerator.new()
	rng.seed = 1
	var drops := 0
	for i in range(200):
		drops += gd.roll_loot("boar", rng).size()
	check(drops > 150 and drops < 300, "boar loot rate plausible (%d in 200 kills)" % drops)
	var clubs := 0
	var staves := 0
	for i in range(200):
		var got: Array = gd.roll_loot("troll_brute", rng)
		clubs += got.count("gorraks_bonebreaker")
		staves += got.count("mossback_staff")
	check(clubs + staves == 200 and clubs > 60 and staves > 60, "chief drops exactly one weapon per kill, roughly 50/50 (%d/%d)" % [clubs, staves])
