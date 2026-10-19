## The Esc menu: resume, settings (UI scale, music), back to the character screen, log out, quit.
class_name GameMenu
extends CenterContainer

var _settings: VBoxContainer
var _scale_label: Label
var _music_button: Button
var _vsync_button: Button


func _init() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(300, 0)
	add_child(panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	panel.add_child(v)
	v.add_child(UITheme.header("Thornhill", 20))
	v.add_child(HSeparator.new())
	v.add_child(UITheme.button("Resume", func() -> void: toggle()))
	v.add_child(UITheme.button("Settings", func() -> void: _settings.visible = not _settings.visible))
	_settings = VBoxContainer.new()
	_settings.visible = false
	_settings.add_theme_constant_override("separation", 6)
	v.add_child(_settings)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	_settings.add_child(row)
	_scale_label = UITheme.small("", 13)
	_scale_label.custom_minimum_size.x = 150
	row.add_child(_scale_label)
	row.add_child(UITheme.button("-", func() -> void: Settings.set_ui_scale(Settings.ui_scale - Settings.STEP)))
	row.add_child(UITheme.button("+", func() -> void: Settings.set_ui_scale(Settings.ui_scale + Settings.STEP)))
	_music_button = UITheme.button("", func() -> void:
		Audio.toggle_music()
		refresh())
	_settings.add_child(_music_button)
	_vsync_button = UITheme.button("", func() -> void:
		Settings.set_vsync(not Settings.vsync_enabled())
		refresh())
	_settings.add_child(_vsync_button)
	var hint := UITheme.small("Ctrl +/- also scales the UI, Ctrl 0 resets it, Ctrl M toggles music.", 11, UITheme.TEXT_DIM)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size.x = 280
	_settings.add_child(hint)
	v.add_child(HSeparator.new())
	v.add_child(UITheme.button("Character screen", func() -> void:
		toggle()
		Net.request("leave")))
	v.add_child(UITheme.button("Log out", func() -> void: get_tree().current_scene.logout()))
	v.add_child(UITheme.button("Quit game", func() -> void: get_tree().quit()))


func toggle() -> void:
	visible = not visible
	_settings.visible = false
	Audio.play("open" if visible else "click")
	if visible:
		refresh()


func refresh() -> void:
	_scale_label.text = "UI scale: %d%%" % int(round(Settings.ui_scale * 100))
	_music_button.text = "Music: %s" % ("on" if Audio.music_enabled() else "off")
	_vsync_button.text = "V-Sync: %s" % ("on" if Settings.vsync_enabled() else "off (144 fps cap)")
