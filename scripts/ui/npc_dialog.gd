## Talking to an NPC: quest offer / progress / turn-in for quest givers, buy and sell lists for
## vendors. Rebuilt from the player's synced state whenever it changes; closes when you walk away.
class_name NpcDialog
extends PanelContainer

var player: Player
var npc_id := ""
var _body: VBoxContainer


func _init() -> void:
	visible = false
	add_theme_stylebox_override("panel", UITheme.parchment_style()) # Classic quest log: ink on paper
	_body = VBoxContainer.new()
	_body.add_theme_constant_override("separation", 8)
	_body.custom_minimum_size.x = 400
	add_child(_body)


func open(id: String) -> void:
	if not visible or npc_id != id:
		Audio.play("open")
	npc_id = id
	visible = true
	refresh()


func close() -> void:
	visible = false
	npc_id = ""


## Closes when the player walks out of range or dies.
func check_range() -> void:
	var npc: Node = get_tree().get_first_node_in_group("world").get_npc(npc_id)
	if npc == null or player.global_position.distance_to(npc.global_position) > npc.INTERACT_RANGE + 1.5 or player.is_dead or player.is_ghost:
		close()


func refresh() -> void:
	for c in _body.get_children():
		c.queue_free()
	var data := GameData.npc(npc_id)
	var title := UITheme.header("%s  <%s>" % [data.name, data.title], 17, UITheme.INK_TITLE)
	title.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0))
	_body.add_child(title)
	_body.add_child(HSeparator.new())
	if data.kind == "quest":
		_quest_section(data)
	elif data.kind == "vendor":
		_vendor_section(data)
	_button("Close", close)


func _quest_section(data: Dictionary) -> void:
	for qid in player.quests:
		var q := GameData.quest(qid)
		if q.get("giver", "") != npc_id or player.quests[qid].state != "active":
			continue
		var prog: Array = player.quests[qid].progress
		if GameData.quest_complete(q, prog):
			_text(q.name, 15, UITheme.INK_TITLE)
			_text(q.complete_text)
			var r: Dictionary = q.reward
			var rew := "Rewards: %d XP" % r.get("xp", 0)
			if r.get("copper", 0) > 0:
				rew += ", " + GameData.format_copper(r.copper)
			for it in r.get("items", []):
				rew += ", " + GameData.item_stat(it, "name", it)
			_text(rew, 12, Color(0.1, 0.32, 0.08))
			_button("Complete Quest", func() -> void: player.request("npc", [npc_id, "complete", null]))
		else:
			_text(q.name + " (in progress)", 15, UITheme.INK_TITLE)
			for i in range(q.objectives.size()):
				_text("  - " + GameData.objective_text(q, i, prog), 12)
		return
	var qid := GameData.available_quest(npc_id, player.quests)
	if qid == "":
		_text(data.greeting)
		return
	var q := GameData.quest(qid)
	_text(q.name, 15, UITheme.INK_TITLE)
	_text(q.text)
	for i in range(q.objectives.size()):
		_text("  - " + GameData.objective_text(q, i, []), 12)
	_button("Accept", func() -> void: player.request("npc", [npc_id, "accept", null]))


func _vendor_section(data: Dictionary) -> void:
	_text(data.greeting)
	_text("For sale", 14, UITheme.INK_TITLE)
	for item_id in data.get("stock", []):
		var it := GameData.item(item_id)
		var b := _button("%s — %s" % [it.name, GameData.format_copper(it.buy)],
			func() -> void: player.request("npc", [npc_id, "buy", item_id]))
		b.tooltip_text = GameData.item_tooltip(item_id)
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_text("Sell from your bag", 14, UITheme.INK_TITLE)
	var any := false
	for i in range(player.inventory.size()):
		var slot: Dictionary = player.inventory[i]
		if slot.id == "":
			continue
		any = true
		var label := GameData.slot_label(slot)
		var price: int = GameData.item_stat(slot.id, "sell", 0) * int(slot.n)
		var b := _button("%s — %s" % [label, GameData.format_copper(price)],
			func() -> void: player.request("npc", [npc_id, "sell", i]))
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.add_theme_color_override("font_color", GameData.QUALITY_COLORS.get(GameData.item_stat(slot.id, "quality", "common"), Color.WHITE))
	if not any:
		_text("  (nothing to sell)", 12, Color(0.4, 0.33, 0.25))


func _text(text: String, size := 13, color := UITheme.INK) -> void:
	var l := UITheme.small(text, size, color)
	if size >= 14:
		l.add_theme_font_override("font", UITheme.serif(700))
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size.x = 390
	_body.add_child(l)


func _button(text: String, cb: Callable) -> Button:
	var b := UITheme.button(text, cb)
	_body.add_child(b)
	return b
