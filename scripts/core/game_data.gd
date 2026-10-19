## Static game data: classes, abilities, monsters, items, NPCs, quests and the tuning constants.
## Everything is data-driven so a new class, monster or quest is a dictionary entry; later this can
## move to JSON served by the game server. Pure data + static helpers, no state.
extends Node

# ---------------------------------------------------------------- combat tuning

const MELEE_RANGE := 3.0
const GCD := 1.5                   # global cooldown; starts when a cast starts
const OUT_OF_COMBAT_AFTER := 6.0   # seconds without combat before regen/eating are allowed
const HEALTH_REGEN_OOC := 0.004    # fraction of max health per second out of combat (100 hp: 1 hp / 2.5 s)
const EAT_SECONDS := 8.0           # food/drink is channelled while sitting; effect spread over this
const SPELL_QUEUE_WINDOW := 0.5    # press within this many seconds of a cast/GCD ending to queue
const SOCIAL_AGGRO_RADIUS := 9.0   # idle monsters of the same kind this close join a fight
const FACING_COS := 0.34           # cos(70°): targets must be within the 140° arc in front to be hit
const WAND_WINDUP := 0.6           # wand shot wind-up (a mini cast bar); moving cancels it
const CAVES := ["warren"]       # assets/caves/<name>.out.json, baked from <name>.json by tools/build_cave.py
const GRAVEYARD := Vector2(6.0, 36.0)
const GHOST_SPEED_MULT := 1.25
const CORPSE_RES_RANGE := 8.0
const RELEASE_AUTO_SECONDS := 20.0

# ---------------------------------------------------------------- classes & abilities

## cost: {"rage": n} or {"mana": n}. cast: seconds (0 = instant). kinds:
##   melee, charge, aoe (around caster), toggle (auto-attack), bolt (projectile, needs target),
##   nova (aoe + root), blink (teleport forward).
const ABILITIES := {
	# --- warrior
	"heroic_strike": {"name": "Heroic Strike", "cost": {"rage": 15}, "cooldown": 0.0,
		"max_range": MELEE_RANGE, "kind": "melee", "dmg_min": 14, "dmg_max": 20, "triggers_gcd": true,
		"desc": "A strong attack that adds half your weapon damage."},
	"charge": {"name": "Charge", "cost": {}, "cooldown": 15.0, "min_range": 8.0, "max_range": 25.0,
		"kind": "charge", "rage_gain": 15, "stun": 1.0, "speed": 28.0, "triggers_gcd": false,
		"desc": "Rush a distant enemy, stunning it for 1 s and generating 15 rage."},
	"thunder_clap": {"name": "Thunder Clap", "cost": {"rage": 20}, "cooldown": 6.0, "kind": "aoe",
		"radius": 8.0, "dmg_min": 7, "dmg_max": 11, "slow": 0.5, "slow_duration": 6.0, "triggers_gcd": true,
		"desc": "Damages all enemies within 8 m and slows them by 50% for 6 s."},
	"auto_attack": {"name": "Attack", "cost": {}, "cooldown": 0.0, "kind": "toggle", "triggers_gcd": false,
		"desc": "Toggle auto-attack."},
	# --- mage
	"frostbolt": {"name": "Frostbolt", "cost": {"mana": 20}, "cooldown": 0.0, "cast": 2.0,
		"max_range": 30.0, "kind": "bolt", "dmg_min": 16, "dmg_max": 22, "slow": 0.5, "slow_duration": 5.0, "speed": 22.0,
		"triggers_gcd": true, "vfx": "frostbolt",
		"desc": "Hurls a bolt of frost, dealing damage and slowing the target by 50% for 5 s."},
	"fireball": {"name": "Fireball", "cost": {"mana": 30}, "cooldown": 0.0, "cast": 2.5,
		"max_range": 30.0, "kind": "bolt", "dmg_min": 26, "dmg_max": 34, "dot": 5, "dot_duration": 4.0, "speed": 20.0,
		"triggers_gcd": true, "vfx": "fireball",
		"desc": "Hurls a fireball that burns the target for 5 damage per second for 4 s."},
	"frost_nova": {"name": "Frost Nova", "cost": {"mana": 25}, "cooldown": 20.0, "kind": "nova",
		"radius": 8.0, "dmg_min": 6, "dmg_max": 9, "root": 5.0, "triggers_gcd": true,
		"desc": "Blasts enemies within 8 m with frost, rooting them in place for 5 s."},
	"blink": {"name": "Blink", "cost": {"mana": 15}, "cooldown": 12.0, "kind": "blink",
		"distance": 15.0, "triggers_gcd": false,
		"desc": "Teleports you 15 m forward."},
	"shoot": {"name": "Shoot", "cost": {}, "cooldown": 0.0, "kind": "toggle", "triggers_gcd": false,
		"desc": "Toggle shooting your wand at the target."},
}

## Character models and how the game drives them. `fist` (tools/import_meshy.py fist prints it) is
## the weapon hand: its bone, the blend shape that closes it, and the grip frame in bind-pose mesh
## space. The hero's `point` is centred by eye in the closed fist (the importer's value moved 9 mm
## towards the wrist and 10 mm out from the fingers, so a handle runs through the middle of the
## curl rather than through the knuckles).
## `skins`: the body is one texture and armour is painted onto it per slot (WoW Classic's way):
## `regions` is the texel->body-region map (tools/import_meshy.py regions) and an item's `skin`
## names assets/<model>_skin_<skin>.png, whose texels for that slot's regions replace the base
## body's. `shoulders` places shoulder pieces (`model` = shoulder_<model>.glb) on those bones, at
## the upper-arm joints. `run_speed` is the move speed at which the walk clip plays at 1x. `yaw`
## turns a model authored facing +Z (Meshy's convention) round to Godot's -Z forward. `jump_clip`
## [from, to] (seconds) is the in-air part of the jump clip, the rest is crouch/landing.
const MODELS := {
	"hero": {"path": "res://assets/hero.glb", "run_speed": 7.0, "yaw": PI,
		"fist": {"bone": "RightHand", "shape": "fist_R", "point": Vector3(-0.5642, 0.9595, -0.0032), "axis": Vector3(-0.0235, 0.1590, 0.9870), "edge": Vector3(-0.4557, -0.8805, 0.1309)},
		"skins": {"regions": "res://assets/hero_regions.png", "slots": {"head": [0], "chest": [1], "legs": [2], "feet": [3], "hands": [4]}},
		"shoulders": {"bones": ["RightShoulder", "LeftShoulder"], "at": ["RightArm", "LeftArm"], "lift": 0.07, "out": 0.03},
		"jump_clip": [0.45, 1.0]},
	# Monsters on Meshy's humanoid rig (their walk clips are slow orc walks: run_speed is the ground
	# speed they match at 1x, before the monster's scale). Mitten hands: a grip frame, no fist shape.
	"troll": {"path": "res://assets/troll.glb", "run_speed": 2.6, "yaw": PI,
		"fist": {"bone": "RightHand", "shape": "fist_R", "point": Vector3(-0.8406, 0.7050, 0.0937), "axis": Vector3(0.0625, 0.2253, 0.9723), "edge": Vector3(-0.2600, -0.9369, 0.2338)}},
	"troll_boss": {"path": "res://assets/troll_boss.glb", "run_speed": 2.4, "yaw": PI,
		"fist": {"bone": "RightHand", "shape": "fist_R", "point": Vector3(-0.8034, 0.5953, 0.0463), "axis": Vector3(0.0033, 0.1709, 0.9853), "edge": Vector3(-0.0190, -0.9851, 0.1709)}},
}

const CLASSES := {
	"warrior": {
		"name": "Warrior", "model": "hero", "resource": "rage", "max_resource": 100, "resource_per_level": 0,
		"max_health": 120, "health_per_level": 12, "speed": 7.0,
		"abilities": ["heroic_strike", "charge", "thunder_clap", "auto_attack"],
		"attack_range": MELEE_RANGE, "attack_speed": 2.0, "ranged": false,
		"rage_per_swing": 10, "rage_per_damage_taken": 0.3, "rage_decay_per_sec": 3.0,
		"starter_gear": {"weapon": "worn_shortsword", "shoulders": "squires_pauldrons", "chest": "recruits_tunic", "legs": "recruits_pants", "feet": "recruits_boots"},
		"starter_bag": ["boar_meat", "boar_meat"],
		"blurb": "Heavy armor, rage built in combat, charges and shouts. Simple and sturdy.",
	},
	"mage": {
		"name": "Mage", "model": "hero", "resource": "mana", "max_resource": 100, "resource_per_level": 12,
		"max_health": 80, "health_per_level": 8, "speed": 7.0,
		"abilities": ["frostbolt", "fireball", "frost_nova", "blink"],
		"attack_range": 25.0, "attack_speed": 1.6, "ranged": true,
		"mana_regen_ooc": 3.5, "mana_regen_combat": 1.0,
		"starter_gear": {"weapon": "apprentice_wand", "chest": "apprentice_robe", "legs": "apprentice_pants", "feet": "cloth_slippers"},
		"starter_bag": ["boar_meat", "boar_meat", "spring_water", "spring_water"],
		"blurb": "Cloth armor, mana, slow hard-hitting spells from range. Keep enemies away from you.",
	},
}

## Key 5: the warrior's four abilities include auto-attack; the mage's four are spells, so its wand
## toggle sits on a fifth key.
const EXTRA_ABILITY := {"warrior": "", "mage": "shoot"}

# ---------------------------------------------------------------- monsters

const MONSTERS := {
	"boar": {
		"name": "Thornhill Boar",
		"level": 1,
		"max_health": 45,
		"dmg_min": 3,
		"dmg_max": 5,
		"attack_speed": 1.8,
		"speed": 5.5,
		"aggro_radius": 9.0,
		"leash_radius": 35.0,
		"respawn_time": 75.0,
		"xp": 25,
		"family": "Beast",
		"shape": "quadruped",
		"scale": 1.0,
	},
	"wolf": {
		"name": "Timber Wolf",
		"level": 2,
		"max_health": 55,
		"dmg_min": 4,
		"dmg_max": 6,
		"attack_speed": 1.6,
		"speed": 6.0,
		"aggro_radius": 11.0,
		"leash_radius": 35.0,
		"respawn_time": 80.0,
		"xp": 35,
		"family": "Beast",
		"shape": "quadruped",
		"scale": 1.0,
	},
	"troll": {
		"name": "Mossback Troll",
		"level": 2,
		"max_health": 65,
		"dmg_min": 4,
		"dmg_max": 7,
		"attack_speed": 2.0,
		"speed": 4.5,
		"aggro_radius": 11.0,
		"leash_radius": 35.0,
		"respawn_time": 90.0,
		"xp": 40,
		"family": "Humanoid",
		"shape": "biped",
		"scale": 1.0,
	},
	"troll_brute": {
		"name": "Gorrak the Swollen",
		"level": 4,
		"max_health": 320,
		"dmg_min": 9,
		"dmg_max": 14,
		"attack_speed": 2.2,
		"speed": 5.0,
		"aggro_radius": 12.0,
		"leash_radius": 30.0,
		"respawn_time": 180.0,
		"xp": 220,
		"family": "Humanoid",
		"rank": "boss",
		"shape": "biped",
		"scale": 1.5,
		"model": "troll_boss",
		"weapon": "troll_club",
	},
}


# ---------------------------------------------------------------- items

const INVENTORY_SIZE := 16
const EQUIP_SLOTS := ["head", "shoulders", "chest", "hands", "legs", "feet", "weapon"]
const UNARMED := {"dmg_min": 2, "dmg_max": 4}
const HEALTH_PER_STAMINA := 10
const ARMOR_K := 100.0 # damage taken *= 1 - armor / (armor + ARMOR_K)

const QUALITY_COLORS := {
	"poor": Color(0.62, 0.62, 0.62),
	"common": Color(1, 1, 1),
	"uncommon": Color(0.12, 1.0, 0.0),
	"rare": Color(0.0, 0.44, 0.87),
	"epic": Color(0.64, 0.21, 0.93),
}

## slot "" = not equippable. "heal"/"mana"/"rage" = usable consumable (food or drink). "model" = a
## rigid mesh: weapon_<model>.glb in the hand, or shoulder_<model>.glb on both shoulders.
## "skin" names the body texture it paints on (MODELS.*.skins); "mesh" names a modelled armour set
## (assets/armor_<mesh>.glb, tools/import_armor.py) whose piece for the item's slot is worn (helm,
## pauldrons, gauntlets, boots; a set's chest and legs are its skin, hero_skin_<set>.png, which its
## boots carry too). An item with neither (the Patched Hide Cap) shows nothing on the body.
const ITEMS := {
	"worn_shortsword": {"name": "Worn Shortsword", "slot": "weapon", "quality": "common",
		"dmg_min": 6, "dmg_max": 10, "model": "longsword", "sell": 25},
	"rusty_club": {"name": "Rusty Club", "slot": "weapon", "quality": "poor",
		"dmg_min": 5, "dmg_max": 12, "model": "club", "sell": 12},
	"hunters_axe": {"name": "Thornhill Hunter's Axe", "slot": "weapon", "quality": "uncommon",
		"dmg_min": 9, "dmg_max": 14, "strength": 2, "model": "axe", "sell": 120},
	"recruits_tunic": {"name": "Recruit's Tunic", "slot": "chest", "quality": "common",
		"armor": 12, "skin": "chain", "sell": 15},
	"recruits_pants": {"name": "Recruit's Pants", "slot": "legs", "quality": "common",
		"armor": 8, "skin": "chain", "sell": 10},
	"recruits_boots": {"name": "Recruit's Boots", "slot": "feet", "quality": "common",
		"armor": 5, "skin": "chain", "sell": 8},
	"squires_pauldrons": {"name": "Squire's Pauldrons", "slot": "shoulders", "quality": "common",
		"armor": 6, "model": "pauldron", "buy": 120, "sell": 30},
	"boar_hide_vest": {"name": "Boar Hide Vest", "slot": "chest", "quality": "uncommon",
		"armor": 20, "stamina": 2, "skin": "leather", "sell": 90},
	"hide_cap": {"name": "Patched Hide Cap", "slot": "head", "quality": "common",
		"armor": 7, "sell": 20},
	"tattered_leggings": {"name": "Tattered Leggings", "slot": "legs", "quality": "poor",
		"armor": 4, "skin": "leather", "sell": 6},
	"wolfhide_boots": {"name": "Wolfhide Boots", "slot": "feet", "quality": "uncommon",
		"armor": 9, "stamina": 1, "skin": "leather", "sell": 40},
	# Thornwarden plate: modelled armour (meshy/armor, set "plate_a"). Corwin sells it at a test
	# price (buy 5, sell 2 copper): raise it, or move the set to a drop, once it's been tried on
	"thornwarden_greathelm": {"name": "Thornwarden Greathelm", "slot": "head", "quality": "rare",
		"armor": 18, "stamina": 2, "mesh": "plate_a", "buy": 5, "sell": 2},
	"thornwarden_pauldrons": {"name": "Thornwarden Pauldrons", "slot": "shoulders", "quality": "rare",
		"armor": 16, "strength": 2, "mesh": "plate_a", "buy": 5, "sell": 2},
	"thornwarden_breastplate": {"name": "Thornwarden Breastplate", "slot": "chest", "quality": "rare",
		"armor": 30, "stamina": 3, "strength": 2, "skin": "plate_a", "buy": 5, "sell": 2},
	"thornwarden_gauntlets": {"name": "Thornwarden Gauntlets", "slot": "hands", "quality": "rare",
		"armor": 12, "strength": 2, "mesh": "plate_a", "buy": 5, "sell": 2},
	"thornwarden_legplates": {"name": "Thornwarden Legplates", "slot": "legs", "quality": "rare",
		"armor": 24, "stamina": 2, "skin": "plate_a", "buy": 5, "sell": 2},
	"thornwarden_sabatons": {"name": "Thornwarden Sabatons", "slot": "feet", "quality": "rare",
		"armor": 15, "stamina": 1, "mesh": "plate_a", "skin": "plate_a", "buy": 5, "sell": 2},
	# Sellsword's mail: modelled armour, set "merc_d" (mail with plate pieces, open cap and coif)
	"sellsword_coif": {"name": "Sellsword's Coif", "slot": "head", "quality": "uncommon",
		"armor": 12, "stamina": 1, "mesh": "merc_d", "buy": 5, "sell": 2},
	"sellsword_spaulders": {"name": "Sellsword's Spaulders", "slot": "shoulders", "quality": "uncommon",
		"armor": 11, "strength": 1, "mesh": "merc_d", "buy": 5, "sell": 2},
	"sellsword_hauberk": {"name": "Sellsword's Hauberk", "slot": "chest", "quality": "uncommon",
		"armor": 22, "stamina": 2, "skin": "merc_d", "buy": 5, "sell": 2},
	"sellsword_gloves": {"name": "Sellsword's Gloves", "slot": "hands", "quality": "uncommon",
		"armor": 8, "strength": 1, "mesh": "merc_d", "buy": 5, "sell": 2},
	"sellsword_chausses": {"name": "Sellsword's Chausses", "slot": "legs", "quality": "uncommon",
		"armor": 17, "stamina": 1, "skin": "merc_d", "buy": 5, "sell": 2},
	"sellsword_greaves": {"name": "Sellsword's Greaves", "slot": "feet", "quality": "uncommon",
		"armor": 10, "mesh": "merc_d", "skin": "merc_d", "buy": 5, "sell": 2},
	# Blackscar plate: modelled armour, set "black_k" (battle-scarred black plate, crimson accents)
	"blackscar_greathelm": {"name": "Blackscar Greathelm", "slot": "head", "quality": "epic",
		"armor": 24, "stamina": 3, "strength": 2, "mesh": "black_k", "buy": 5, "sell": 2},
	"blackscar_pauldrons": {"name": "Blackscar Pauldrons", "slot": "shoulders", "quality": "epic",
		"armor": 21, "strength": 3, "mesh": "black_k", "buy": 5, "sell": 2},
	"blackscar_cuirass": {"name": "Blackscar Cuirass", "slot": "chest", "quality": "epic",
		"armor": 38, "stamina": 4, "strength": 3, "skin": "black_k", "buy": 5, "sell": 2},
	"blackscar_gauntlets": {"name": "Blackscar Gauntlets", "slot": "hands", "quality": "epic",
		"armor": 16, "strength": 3, "mesh": "black_k", "buy": 5, "sell": 2},
	"blackscar_legguards": {"name": "Blackscar Legguards", "slot": "legs", "quality": "epic",
		"armor": 31, "stamina": 3, "strength": 1, "skin": "black_k", "buy": 5, "sell": 2},
	"blackscar_sabatons": {"name": "Blackscar Sabatons", "slot": "feet", "quality": "epic",
		"armor": 19, "stamina": 2, "mesh": "black_k", "skin": "black_k", "buy": 5, "sell": 2},
	"boar_tusk": {"stack": 20, "name": "Boar Tusk", "slot": "", "quality": "poor", "desc": "Brannoc wants these.", "sell": 4},
	"boar_meat": {"stack": 10, "name": "Chunk of Boar Meat", "slot": "", "quality": "common", "heal": 30,
		"desc": "Use: Restores 30 health.", "sell": 3},
	"bone_charm": {"stack": 20, "name": "Crude Bone Charm", "slot": "", "quality": "poor", "desc": "Trolls wear these for luck. Not much luck, it seems.", "sell": 5},
	"wolf_pelt": {"stack": 20, "name": "Wolf Pelt", "slot": "", "quality": "poor", "desc": "Edric wants these.", "sell": 5},
	"lean_wolf_meat": {"stack": 10, "name": "Lean Wolf Meat", "slot": "", "quality": "common", "heal": 30,
		"desc": "Use: Restores 30 health.", "sell": 3},
	# mage starter kit
	"apprentice_wand": {"name": "Apprentice's Wand", "slot": "weapon", "quality": "common",
		"dmg_min": 4, "dmg_max": 7, "model": "wand", "sell": 20},
	"apprentice_robe": {"name": "Apprentice's Robe", "slot": "chest", "quality": "common",
		"armor": 5, "intellect": 2, "skin": "cloth", "sell": 12},
	"apprentice_pants": {"name": "Apprentice's Pants", "slot": "legs", "quality": "common",
		"armor": 3, "skin": "cloth", "sell": 8},
	"cloth_slippers": {"name": "Cloth Slippers", "slot": "feet", "quality": "common",
		"armor": 2, "skin": "cloth", "sell": 6},
	"spring_water": {"stack": 10, "name": "Spring Water", "slot": "", "quality": "common", "mana": 40,
		"desc": "Use: Restores 40 mana.", "sell": 2, "buy": 8},
	# Gorrak's hoard (one of the two drops every kill)
	"gorraks_bonebreaker": {"name": "Gorrak's Bonebreaker", "slot": "weapon", "quality": "rare",
		"dmg_min": 13, "dmg_max": 19, "strength": 4, "stamina": 2, "model": "troll_club", "sell": 400,
		"desc": "Too heavy for a man to swing. You swing it anyway."},
	"mossback_staff": {"name": "Mossback Shaman's Staff", "slot": "weapon", "quality": "rare",
		"dmg_min": 7, "dmg_max": 12, "intellect": 6, "stamina": 1, "model": "staff", "sell": 400,
		"desc": "Still damp. Something in the moss hums when you hold it."},
	# vendor food
	"tough_jerky": {"stack": 10, "name": "Tough Jerky", "slot": "", "quality": "common", "heal": 40,
		"desc": "Use: Restores 40 health.", "sell": 2, "buy": 10},
	"roasted_boar": {"stack": 10, "name": "Roasted Boar Haunch", "slot": "", "quality": "common", "heal": 90,
		"desc": "Use: Restores 90 health.", "sell": 6, "buy": 30},
	"honey_bread": {"stack": 10, "name": "Honey Bread", "slot": "", "quality": "common", "heal": 60, "rage": 20,
		"desc": "Use: Restores 60 health and 20 rage.", "sell": 4, "buy": 22},
}

const STARTER_COPPER := 40


# ---------------------------------------------------------------- npcs & quests

## Where each NPC stands is on the map: its NpcSpot in scenes/map/thornhill.tscn (move it in the editor).
const NPCS := {
	"brannoc": {"name": "Marshal Brannoc", "title": "Camp Marshal", "kind": "quest",
		"outfit": {"skin": "marshal", "armor": "plate_a", "weapon": "longsword"},
		"greeting": "Thornhill's not what it was, friend. Boars in the fields, trolls in the hills. We could use a sword like yours."},
	"hollis": {"name": "Hollis Tamsin", "title": "Provisioner", "kind": "vendor",
		"outfit": {"skin": "provisioner"},
		"greeting": "Food, water and a kind word. Two of the three are for sale.",
		"stock": ["tough_jerky", "honey_bread", "roasted_boar", "spring_water", "squires_pauldrons"]},
	"ottar": {"name": "Ottar Greyfell", "title": "Old Prospector", "kind": "quest", "sit": true,
		"outfit": {"skin": "prospector"},
		"greeting": "Dug that warren myself, forty years back. Never thought I'd see trolls squatting in it."},
	"corwin": {"name": "Corwin Hale", "title": "Armorer", "kind": "vendor",
		"outfit": {"skin": "chain", "weapon": "longsword", "shoulders": "pauldron"},
		"greeting": "Plate off a dead knight's back, cleaned and fitted. He won't miss it. Try it on.",
		"stock": ["thornwarden_greathelm", "thornwarden_pauldrons", "thornwarden_breastplate",
			"thornwarden_gauntlets", "thornwarden_legplates", "thornwarden_sabatons",
			"sellsword_coif", "sellsword_spaulders", "sellsword_hauberk",
			"sellsword_gloves", "sellsword_chausses", "sellsword_greaves",
			"blackscar_greathelm", "blackscar_pauldrons", "blackscar_cuirass",
			"blackscar_gauntlets", "blackscar_legguards", "blackscar_sabatons"]},
	"edric": {"name": "Edric Vane", "title": "Huntsman", "kind": "quest",
		"outfit": {"skin": "leather", "weapon": "axe"},
		"greeting": "Pines up north are thick with wolves this year. Keep your back to a tree."},
}

## Objective kinds: kill {monster, count}, collect {item, count} (items are taken on turn-in).
## `next` chains a giver's quests; `requires` makes a quest wait for any other one (by id).
const QUESTS := {
	"boar_trouble": {
		"name": "Boar Trouble", "giver": "brannoc",
		"text": "The boars have gone mad this season, trampling what little we planted. Thin the herd east of camp, and bring me tusks as proof.",
		"objectives": [{"kind": "kill", "monster": "boar", "count": 6}, {"kind": "collect", "item": "boar_tusk", "count": 4}],
		"complete_text": "Fine work. That's a few less mouths at our crops. Here, you've earned this.",
		"reward": {"xp": 120, "copper": 60, "items": ["honey_bread", "honey_bread"]},
		"next": "troll_raiders"},
	"troll_raiders": {
		"name": "Troll Raiders", "giver": "brannoc",
		"text": "Trolls have been creeping out of the western hills at night, raiding our stores. Teach them a lesson, and bring back those bone charms they wear as proof.",
		"objectives": [{"kind": "kill", "monster": "troll", "count": 5}, {"kind": "collect", "item": "bone_charm", "count": 3}],
		"complete_text": "Ha! Maybe they'll think twice now. The camp owes you.",
		"reward": {"xp": 200, "copper": 110, "items": ["boar_hide_vest"]},
		"next": ""},
	"the_chief_below": {
		"name": "The Thing Below", "giver": "ottar", "requires": "boar_trouble",
		"text": "There's something down in my old warren, west along the road: Gorrak, the trolls call him. Whatever's in that deep water swelled him to twice a troll's size, and he's the reason they've got bold. Go down past the mouth and the hall, all the way to the deep chamber, and put him in the ground. Mind the drop.",
		"objectives": [{"kind": "kill", "monster": "troll_brute", "count": 1}],
		"complete_text": "Gorrak's dead? Ha! Then the warren's mine again, in name at least. Take this, and take a drink with me.",
		"reward": {"xp": 400, "copper": 250, "items": ["spring_water", "spring_water", "roasted_boar"]},
		"next": ""},
	"wolves_at_the_treeline": {
		"name": "Wolves at the Treeline", "giver": "edric",
		"text": "The pines north of camp have gone quiet, and quiet means wolves. They've taken two of our goats and they'll take a sentry next. Thin the pack, and bring me their pelts: we'll want them come winter.",
		"objectives": [{"kind": "kill", "monster": "wolf", "count": 6}, {"kind": "collect", "item": "wolf_pelt", "count": 4}],
		"complete_text": "That'll keep them off the goats. Here, Hollis stitched these from last winter's hides.",
		"reward": {"xp": 140, "copper": 70, "items": ["wolfhide_boots"]},
		"next": ""},
}


# ---------------------------------------------------------------- helpers

static func ability_cost(ab: Dictionary) -> int:
	return int(ab.cost.values().front()) if not ab.cost.is_empty() else 0


## Damage range of the equipped weapon (or fists) plus the strength bonus: [min, max].
static func weapon_damage_range(weapon_id: String, strength: int) -> Array:
	var w := item(weapon_id)
	return [w.get("dmg_min", UNARMED.dmg_min) + strength / 2, w.get("dmg_max", UNARMED.dmg_max) + strength / 2]


## "Boar Tusk x4" for a bag slot.
static func slot_label(slot: Dictionary) -> String:
	var name: String = item_stat(slot.id, "name", slot.id)
	return "%s x%d" % [name, slot.n] if slot.n > 1 else name


## Build particles, flames and floating text? Not on a dedicated server — unless the tests ask
## for it (THORNHILL_VFX_TEST=1) to exercise that code headless.
static func visuals_enabled() -> bool:
	return DisplayServer.get_name() != "headless" or OS.get_environment("THORNHILL_VFX_TEST") != ""

static func cls(id: String) -> Dictionary:
	return CLASSES.get(id, CLASSES.warrior)


## Ability ids on the action bar for a class (4 + optional extra).
static func class_bar(id: String) -> Array:
	var bar: Array = cls(id).abilities.duplicate()
	var extra: String = EXTRA_ABILITY.get(id, "")
	if extra != "":
		bar.append(extra)
	return bar


static func ability_tooltip(id: String) -> String:
	var ab: Dictionary = ABILITIES.get(id, {})
	if ab.is_empty():
		return id
	var lines := [ab.name]
	for k in ab.get("cost", {}):
		lines.append("%d %s" % [ab.cost[k], k.capitalize()])
	if ab.get("cast", 0.0) > 0.0:
		lines.append("%.1f s cast" % ab.cast)
	else:
		lines.append("Instant")
	if ab.get("cooldown", 0.0) > 0.0:
		lines.append("%d s cooldown" % int(ab.cooldown))
	if ab.has("max_range"):
		lines.append("%d m range" % int(ab.max_range))
	lines.append(ab.get("desc", ""))
	return "\n".join(lines)


static func npc(id: String) -> Dictionary:
	return NPCS.get(id, {})


static func quest(id: String) -> Dictionary:
	return QUESTS.get(id, {})


## First quest in the giver's chain that the player can take, given their quest log.
static func available_quest(npc_id: String, log: Dictionary) -> String:
	for qid in QUESTS:
		var q: Dictionary = QUESTS[qid]
		if q.giver != npc_id or log.has(qid):
			continue
		# A quest with a predecessor (its giver's `next`, or an explicit `requires`) needs it completed.
		var req: String = q.get("requires", "")
		var prereq_ok: bool = req == "" or log.get(req, {}).get("state", "") == "done"
		for other in QUESTS:
			if QUESTS[other].next == qid and log.get(other, {}).get("state", "") != "done":
				prereq_ok = false
		if prereq_ok:
			return qid
	return ""


static func objective_text(q: Dictionary, i: int, progress: Array) -> String:
	var o: Dictionary = q.objectives[i]
	var n: int = progress[i] if i < progress.size() else 0
	if o.kind == "kill":
		return "%s slain: %d/%d" % [MONSTERS[o.monster].name, mini(n, o.count), o.count]
	return "%s: %d/%d" % [ITEMS[o.item].name, mini(n, o.count), o.count]


static func quest_complete(q: Dictionary, progress: Array) -> bool:
	for i in range(q.objectives.size()):
		if (progress[i] if i < progress.size() else 0) < q.objectives[i].count:
			return false
	return true


static func format_copper(c: int) -> String:
	if c >= 100:
		return "%ds %dc" % [c / 100, c % 100]
	return "%dc" % c

## [item_id, drop_chance] — every entry rolls independently. An entry whose first element is an
## array of ids drops exactly one of them, chosen evenly (the 50/50 boss weapon).
const LOOT_TABLES := {
	"boar": [["boar_meat", 0.6], ["boar_tusk", 0.4], ["boar_hide_vest", 0.12]],
	"wolf": [["wolf_pelt", 0.55], ["lean_wolf_meat", 0.4], ["tattered_leggings", 0.06]],
	"troll": [["bone_charm", 0.7], ["rusty_club", 0.25], ["tattered_leggings", 0.2],
		["hide_cap", 0.15], ["hunters_axe", 0.06]],
	"troll_brute": [[["gorraks_bonebreaker", "mossback_staff"], 1.0], ["bone_charm", 1.0], ["bone_charm", 0.8]],
}


static func item(id: String) -> Dictionary:
	return ITEMS.get(id, {})


static func max_stack(id: String) -> int:
	return int(ITEMS.get(id, {}).get("stack", 1))


## Inventory slots are {"id": String, "n": int}; an empty slot has id "".
static func empty_slot() -> Dictionary:
	return {"id": "", "n": 0}


static func count_in(inventory: Array, id: String) -> int:
	var n := 0
	for slot in inventory:
		if slot.id == id:
			n += int(slot.n)
	return n


static func item_stat(id: String, key: String, default: Variant = 0) -> Variant:
	return ITEMS.get(id, {}).get(key, default)


## Sum of a stat over an equipment dictionary {slot: item_id}.
static func equipment_stat(equipment: Dictionary, key: String) -> int:
	var total := 0
	for slot in equipment:
		total += int(item_stat(equipment[slot], key, 0))
	return total


static func armor_multiplier(armor: int) -> float:
	return 1.0 - float(armor) / (float(armor) + ARMOR_K)


static func roll_loot(kind: String, rng: RandomNumberGenerator) -> Array:
	var out := []
	for entry in LOOT_TABLES.get(kind, []):
		if rng.randf() < entry[1]:
			out.append(entry[0][rng.randi() % entry[0].size()] if entry[0] is Array else entry[0])
	return out


## Human-readable tooltip for an item.
static func item_tooltip(id: String) -> String:
	var it: Dictionary = ITEMS.get(id, {})
	if it.is_empty():
		return id
	var lines := [it.name]
	if it.get("slot", "") != "":
		lines.append(it.slot.capitalize())
	if it.has("dmg_min"):
		lines.append("%d - %d damage" % [it.dmg_min, it.dmg_max])
	if it.has("armor"):
		lines.append("%d armor" % it.armor)
	for stat in ["strength", "stamina", "intellect"]:
		if it.has(stat):
			lines.append("+%d %s" % [it[stat], stat.capitalize()])
	if it.has("desc"):
		lines.append(it.desc)
	return "\n".join(lines)


static func xp_for_level(level: int) -> int:
	return 100 * level


## Damage scales mildly with the level difference between attacker and target, WoW-style.
static func level_modifier(attacker_level: int, target_level: int) -> float:
	var diff := attacker_level - target_level
	return clampf(1.0 + diff * 0.1, 0.5, 1.5)


## A damage roll: lo..hi (plus a flat bonus), scaled by the level difference.
static func roll_damage(rng: RandomNumberGenerator, lo: int, hi: int, attacker_level: int, target_level: int, bonus := 0) -> int:
	return int(round((rng.randi_range(lo, hi) + bonus) * level_modifier(attacker_level, target_level)))
