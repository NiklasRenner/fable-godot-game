## The bag (I / B): a 4-wide grid of the 16 inventory slots.
## Left click equips or uses, right click destroys.
class_name BagWindow
extends PanelContainer

var player: Player
var _buttons: Array[Button] = []


func _init() -> void:
	visible = false
	var v := VBoxContainer.new()
	add_child(v)
	v.add_child(UITheme.header("Bag"))
	v.add_child(UITheme.small("click: equip / use · right-click: destroy", 11, UITheme.TEXT_DIM))
	var grid := GridContainer.new()
	grid.columns = 4
	grid.add_theme_constant_override("h_separation", 4)
	grid.add_theme_constant_override("v_separation", 4)
	v.add_child(grid)
	for i in range(GameData.INVENTORY_SIZE):
		var b := Button.new()
		b.custom_minimum_size = Vector2(72, 56)
		b.focus_mode = Control.FOCUS_NONE
		b.add_theme_font_size_override("font_size", 11)
		b.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		b.clip_text = true
		_slot_look(b)
		b.gui_input.connect(func(ev: InputEvent) -> void:
			if ev is InputEventMouseButton and ev.pressed and player:
				if ev.button_index == MOUSE_BUTTON_LEFT:
					player.request("equip", [i])
				elif ev.button_index == MOUSE_BUTTON_RIGHT:
					player.request("destroy", [i]))
		grid.add_child(b)
		_buttons.append(b)


func refresh() -> void:
	for i in range(_buttons.size()):
		var slot: Dictionary = player.inventory[i] if i < player.inventory.size() else GameData.empty_slot()
		UITheme.item_button(_buttons[i], slot.id, "")
		if slot.id != "" and slot.n > 1:
			_buttons[i].text += "  x%d" % slot.n


## Bag and paper-doll slots are bevelled icon slots, not red buttons; names in plain type.
static func _slot_look(b: Button) -> void:
	b.add_theme_stylebox_override("normal", UITheme.slot_style(Color(0.5, 0.45, 0.38), 6))
	b.add_theme_stylebox_override("hover", UITheme.slot_style(Color(0.9, 0.82, 0.55), 6))
	b.add_theme_stylebox_override("pressed", UITheme.slot_style(Color(0.9, 0.82, 0.55), 6))
	b.add_theme_font_override("font", ThemeDB.fallback_font)
	b.add_theme_constant_override("outline_size", 0)
