## A friendly NPC in the camp, built identically on every peer from GameData.NPCS (no sync).
## Click within range to talk; a quest marker floats above the head for the local player.
extends StaticBody3D

const INTERACT_RANGE := 5.0

var npc_id := ""
var data: Dictionary = {}
var _marker: Label3D
var _name_label: Label3D
var _anim: AnimationPlayer
var _next_fidget := 0.0 # standing NPCs: when to next play the restless idle once
var _fidget_until := 0.0


func setup(id: String) -> void:
	npc_id = id
	data = GameData.npc(id)


func _ready() -> void:
	add_to_group("npcs")
	collision_layer = 16
	collision_mask = 0
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.45
	cap.height = 1.9
	cs.shape = cap
	cs.position.y = 1.0
	add_child(cs)
	# The same body as the players (GameData.MODELS.hero), dressed by Outfit from the NPC's outfit:
	# one skin for every body slot (its own face and hair included), plus weapon and shoulders.
	var profile: Dictionary = GameData.MODELS.hero
	var holder := Node3D.new()
	holder.name = "Model"
	add_child(holder)
	var inst: Node3D = load(profile.path).instantiate()
	Unit.prepare_model(inst, profile)
	holder.add_child(inst)
	# Standing NPCs mostly rest (idle_calm), and now and then look about (the restless idle)
	# once, see _fidget(). Clips are shared by every instance of the model, so both stay looping
	# and the fidget is ended by a timer instead.
	_anim = inst.find_child("AnimationPlayer", true, false)
	var clip := "sit" if data.get("sit", false) else _calm_clip()
	if _anim and _anim.has_animation(clip):
		_anim.get_animation(clip).loop_mode = Animation.LOOP_LINEAR
		_anim.play(clip)
		_anim.seek(randf() * _anim.current_animation_length, true) # not all in step
	_next_fidget = Unit.now() + randf_range(4.0, 20.0)
	var outfit: Dictionary = data.get("outfit", {})
	var skins := Outfit.whole(profile, outfit.get("skin", ""))
	var armor := Outfit.whole_armor(outfit.get("armor", ""))
	skins.merge(Outfit.armor_skins(armor), true)
	Outfit.dress(holder, profile, {"skins": skins, "armor": armor,
		"weapon": outfit.get("weapon", ""), "shoulders": outfit.get("shoulders", "")})
	var top := 1.5 if data.get("sit", false) else 2.25
	_name_label = WorldLabel.make("%s\n<%s>" % [data.get("name", npc_id), data.get("title", "")], top, Color(1.0, 0.9, 0.3))
	add_child(_name_label)
	_marker = WorldLabel.make("", top + 0.75, Color.WHITE, 96, 14, 0.008)
	_marker.visible = false
	add_child(_marker)




func _calm_clip() -> String:
	return "idle_calm" if _anim and _anim.has_animation("idle_calm") else "idle"


func _fidget() -> void:
	if _anim == null or data.get("sit", false) or _calm_clip() == "idle":
		return
	var t := Unit.now()
	if _fidget_until > 0.0 and t >= _fidget_until:
		_fidget_until = 0.0
		_anim.play("idle_calm", 0.6)
		_next_fidget = t + randf_range(12.0, 30.0)
	elif _fidget_until == 0.0 and t >= _next_fidget and _anim.has_animation("idle"):
		_anim.play("idle", 0.6)
		_fidget_until = t + _anim.get_animation("idle").length


func _process(_delta: float) -> void:
	_fidget()
	_name_label.visible = WorldLabel.near_local_player(get_tree(), global_position)
	# Marker reflects the LOCAL player's quest log (and shows from any distance, like WoW's).
	var p := get_tree().get_first_node_in_group("local_player")
	if p == null or data.get("kind", "") != "quest":
		return
	var state := quest_marker_state(p.quests)
	_marker.visible = state != ""
	_marker.text = marker_glyph(state)
	_marker.modulate = marker_color(state)


## The quest marker for a marker state, over the NPC's head and on the minimap: "!" a new quest,
## "?" one to turn in (yellow) or still under way (grey).
static func marker_glyph(state: String) -> String:
	return "!" if state == "available" else "?"


static func marker_color(state: String) -> Color:
	return Color(0.6, 0.6, 0.6) if state == "active" else Color(1.0, 0.85, 0.1)


## "available" (new quest), "turn_in" (an active quest is complete), "active", or "".
func quest_marker_state(log: Dictionary) -> String:
	for qid in log:
		var q := GameData.quest(qid)
		if q.get("giver", "") == npc_id and log[qid].state == "active":
			return "turn_in" if GameData.quest_complete(q, log[qid].progress) else "active"
	if GameData.available_quest(npc_id, log) != "":
		return "available"
	return ""
