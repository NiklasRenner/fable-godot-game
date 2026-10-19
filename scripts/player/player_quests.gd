## Server-side quest log for one player: accepting, tracking kill/collect objectives and turning in.
## p.quests is {quest_id: {"state": "active"|"done", "progress": [int per objective]}} (synced).
class_name PlayerQuests
extends RefCounted

var p: Player


func _init(player: Player) -> void:
	p = player


func _changed() -> void:
	p.quests = p.quests.duplicate(true) # new reference so the synchronizer notices


## Collect objectives mirror the bag; polled by the player twice a second.
func refresh_collect_progress() -> void:
	var changed := false
	for qid in p.quests:
		if p.quests[qid].state != "active":
			continue
		var q := GameData.quest(qid)
		for i in range(q.objectives.size()):
			var o: Dictionary = q.objectives[i]
			if o.kind == "collect":
				var n := mini(p.gear.count(o.item), o.count)
				if p.quests[qid].progress[i] != n:
					p.quests[qid].progress[i] = n
					changed = true
	if changed:
		_changed()


func on_kill(monster_kind: String) -> void:
	var changed := false
	for qid in p.quests:
		if p.quests[qid].state != "active":
			continue
		var q := GameData.quest(qid)
		for i in range(q.objectives.size()):
			var o: Dictionary = q.objectives[i]
			if o.kind == "kill" and o.monster == monster_kind and p.quests[qid].progress[i] < o.count:
				p.quests[qid].progress[i] += 1
				changed = true
				p.say("%s: %s" % [q.name, GameData.objective_text(q, i, p.quests[qid].progress)])
				if GameData.quest_complete(q, p.quests[qid].progress):
					p.say("%s (Complete)" % q.name)
	if changed:
		_changed()


func accept(npc_id: String) -> void:
	var qid := GameData.available_quest(npc_id, p.quests)
	if qid == "":
		return
	var q := GameData.quest(qid)
	var progress := []
	progress.resize(q.objectives.size())
	progress.fill(0)
	p.quests[qid] = {"state": "active", "progress": progress}
	_changed()
	refresh_collect_progress()
	p.say("Quest accepted: %s" % q.name)


## Turns in the giver's active quest if its objectives are met: collected items are handed over,
## rewards paid, and the follow-up quest becomes available.
func complete(npc_id: String) -> void:
	for qid in p.quests:
		var q := GameData.quest(qid)
		if q.get("giver", "") != npc_id or p.quests[qid].state != "active":
			continue
		refresh_collect_progress()
		if not GameData.quest_complete(q, p.quests[qid].progress):
			p.say("You haven't finished that yet.")
			return
		var reward: Dictionary = q.reward
		# Hand over collected items first (frees slots), then check space for rewards.
		var backup := p.inventory.duplicate(true)
		for o in q.objectives:
			if o.kind == "collect":
				p.gear.remove_items(o.item, o.count)
		var leftover := 0
		for it in reward.get("items", []):
			leftover += p.gear.add_items(it, 1)
		if leftover > 0:
			p.inventory = backup
			p.say("Your bag is full.")
			return
		p.copper += int(reward.get("copper", 0))
		p.quests[qid].state = "done"
		_changed()
		p.say("Quest completed: %s" % q.name)
		p.save()
		if reward.get("copper", 0) > 0:
			p.say("You receive %s." % GameData.format_copper(reward.copper))
		p.gain_xp(int(reward.get("xp", 0)))
		return
