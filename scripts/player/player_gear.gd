## Server-side inventory, equipment, loot and vendor trade for one player. The data itself
## (p.inventory, p.equipment, p.copper, stats) lives on the player so it is synced; this just
## mutates it under the rules.
class_name PlayerGear
extends RefCounted

var p: Player


func _init(player: Player) -> void:
	p = player


func give_starter_kit() -> void:
	var inv := []
	for i in range(GameData.INVENTORY_SIZE):
		inv.append(GameData.empty_slot())
	p.inventory = inv
	for id in p.cls().starter_bag:
		add_item(id)
	p.equipment = p.cls().starter_gear.duplicate()
	p.copper = GameData.STARTER_COPPER
	p.quests = {}
	recalc_stats()
	if p.uses_mana():
		p.resource = p.max_resource


## Derived stats from gear and level. Max health/resource grow with level and stamina/intellect.
func recalc_stats() -> void:
	var c := p.cls()
	p.armor = GameData.equipment_stat(p.equipment, "armor")
	p.strength = GameData.equipment_stat(p.equipment, "strength")
	p.stamina = GameData.equipment_stat(p.equipment, "stamina")
	p.intellect = GameData.equipment_stat(p.equipment, "intellect")
	p.max_health = c.max_health + (p.level - 1) * c.health_per_level + p.stamina * GameData.HEALTH_PER_STAMINA
	p.health = mini(p.health, p.max_health)
	p.max_resource = c.max_resource + (p.level - 1) * c.resource_per_level + (p.intellect * 10 if p.uses_mana() else 0)
	p.resource = mini(p.resource, p.max_resource)


# ---------------------------------------------------------------- inventory

## The synchronizer only notices a new reference, so every mutation ends with this.
func _changed() -> void:
	p.inventory = p.inventory.duplicate(true)


func count(id: String) -> int:
	return GameData.count_in(p.inventory, id)


func free_slots() -> int:
	return p.inventory.filter(func(slot): return slot.id == "").size()


## Adds `n` of an item, stacking where allowed. Returns how many did NOT fit.
func add_items(id: String, n: int) -> int:
	var max_stack := GameData.max_stack(id)
	if max_stack > 1: # top up existing stacks first
		for slot in p.inventory:
			if n > 0 and slot.id == id and slot.n < max_stack:
				var take := mini(n, max_stack - slot.n)
				slot.n += take
				n -= take
	for slot in p.inventory:
		if n > 0 and slot.id == "":
			slot.id = id
			slot.n = mini(n, max_stack)
			n -= slot.n
	_changed()
	return n


## Returns false if it did not fit.
func add_item(id: String) -> bool:
	return add_items(id, 1) == 0


## Removes up to `n` of an item across stacks; returns how many were removed.
func remove_items(id: String, n: int) -> int:
	var removed := 0
	for slot in p.inventory:
		if n > 0 and slot.id == id:
			var take := mini(n, slot.n)
			slot.n -= take
			n -= take
			removed += take
			if slot.n <= 0:
				slot.id = ""
				slot.n = 0
	_changed()
	return removed


func _valid_index(index: int) -> bool:
	return index >= 0 and index < p.inventory.size() and p.inventory[index].id != ""


## Click in the bag: equip gear, or eat/drink a consumable.
func equip(index: int) -> void:
	if not _valid_index(index):
		return
	var id: String = p.inventory[index].id
	var it := GameData.item(id)
	if it.get("slot", "") == "":
		_consume(index, it)
		return
	var previous: String = p.equipment.get(it.slot, "")
	var eq := p.equipment.duplicate()
	eq[it.slot] = id
	p.equipment = eq
	p.inventory[index] = {"id": previous, "n": 1} if previous != "" else GameData.empty_slot()
	_changed()
	recalc_stats()
	p.say("Equipped %s." % it.name)


func _consume(index: int, it: Dictionary) -> void:
	if not (it.has("heal") or it.has("mana") or it.has("rage")) or p.is_dead or p.is_ghost:
		return
	if p.in_combat():
		p.say("You can't eat while in combat.")
		return
	if p.moving:
		p.say("Stand still to eat.")
		return
	p.inventory[index].n -= 1
	if p.inventory[index].n <= 0:
		p.inventory[index] = GameData.empty_slot()
	_changed()
	p.start_consuming(it)


func unequip(slot: String) -> void:
	var id: String = p.equipment.get(slot, "")
	if id == "":
		return
	if free_slots() == 0:
		p.say("Your bag is full.")
		return
	var eq := p.equipment.duplicate()
	eq.erase(slot)
	p.equipment = eq
	add_items(id, 1)
	recalc_stats()


func destroy(index: int) -> void:
	if not _valid_index(index):
		return
	p.say("Destroyed %s." % GameData.slot_label(p.inventory[index]))
	p.inventory[index] = GameData.empty_slot()
	_changed()


# ---------------------------------------------------------------- loot & vendor

func loot(bag_path: NodePath) -> void:
	if p.is_dead or p.is_ghost:
		return
	var bag := p.get_node_or_null(bag_path)
	if bag == null or not bag.is_in_group("loot"):
		return
	if p.global_position.distance_to(bag.global_position) > bag.PICKUP_RANGE + 1.0:
		p.say("You are too far away.")
		return
	if not bag.can_loot(p.peer_id):
		p.say("That loot belongs to someone else.")
		return
	var got: Array = bag.server_take_all(p)
	if got.is_empty():
		p.say("Your bag is full.")
	else:
		p.notify("loot", [got])


func buy(npc_data: Dictionary, item_id: String) -> void:
	if not npc_data.get("stock", []).has(item_id):
		return
	var price: int = GameData.item_stat(item_id, "buy", 0)
	if p.copper < price:
		p.say("You don't have enough money.")
		return
	if not add_item(item_id):
		p.say("Your bag is full.")
		return
	p.copper -= price
	p.say("You buy %s for %s." % [GameData.item_stat(item_id, "name", item_id), GameData.format_copper(price)])


## Sells the whole stack in a bag slot.
func sell(index: int) -> void:
	if not _valid_index(index):
		return
	var slot: Dictionary = p.inventory[index]
	var price: int = GameData.item_stat(slot.id, "sell", 0) * int(slot.n)
	p.say("You sell %s for %s." % [GameData.slot_label(slot), GameData.format_copper(price)])
	p.inventory[index] = GameData.empty_slot()
	_changed()
	p.copper += price
