## The character sheet (C): equipped gear (click to unequip) and derived stats.
class_name CharacterWindow
extends PanelContainer

var player: Player
var _slots := {} # slot -> Button
var _stats: Label


func _init() -> void:
	visible = false
	var v := VBoxContainer.new()
	add_child(v)
	v.add_child(UITheme.header("Character"))
	v.add_child(HSeparator.new())
	for slot in GameData.EQUIP_SLOTS:
		var b := UITheme.button("", func() -> void: player.request("unequip", [slot]))
		b.custom_minimum_size = Vector2(190, 40)
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		BagWindow._slot_look(b)
		v.add_child(b)
		_slots[slot] = b
	v.add_child(UITheme.small("click: unequip to bag", 11, UITheme.TEXT_DIM))
	v.add_child(HSeparator.new())
	_stats = UITheme.small("")
	v.add_child(_stats)


func refresh() -> void:
	for slot in GameData.EQUIP_SLOTS:
		UITheme.item_button(_slots[slot], player.equipment.get(slot, ""), slot.capitalize() + ": —")
	var dmg := GameData.weapon_damage_range(player.equipment.get("weapon", ""), player.strength)
	_stats.text = "%s\nArmor %d\nStrength %d\nStamina %d\nIntellect %d\nDamage %d - %d\nMoney %s" % [
		player.cls().name, player.armor, player.strength, player.stamina, player.intellect, dmg[0], dmg[1],
		GameData.format_copper(player.copper)]
