## User settings autoload: owns user://settings.cfg (UI scale, music, v-sync, last login) and applies the
## UI scale. The default scale follows the OS display scaling (Windows 300% -> 3.0); Ctrl+= / Ctrl+-
## adjust it and Ctrl+0 resets it.
extends Node

const PATH := "user://settings.cfg"
const MIN_SCALE := 0.5
const MAX_SCALE := 5.0
const STEP := 0.25

signal ui_scale_changed(scale: float)

var ui_scale := 1.0
var _cfg := ConfigFile.new()


func _ready() -> void:
	_cfg.load(PATH)
	ui_scale = clampf(float(get_value("ui", "scale", _detect_os_scale())), MIN_SCALE, MAX_SCALE)
	get_tree().root.size_changed.connect(_apply)
	_apply()
	set_vsync(bool(get_value("video", "vsync", false)))


## V-Sync is off by default (with a 144 fps cap): several game windows on one desktop stall each
## other when they all wait for the display, which shows as stutter in the focused one.
func vsync_enabled() -> bool:
	return DisplayServer.window_get_vsync_mode() != DisplayServer.VSYNC_DISABLED


func set_vsync(on: bool) -> void:
	if DisplayServer.get_name() != "headless":
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED if on else DisplayServer.VSYNC_DISABLED)
	set_value("video", "vsync", on)


func get_value(section: String, key: String, default: Variant) -> Variant:
	return _cfg.get_value(section, key, default)


func set_value(section: String, key: String, value: Variant) -> void:
	_cfg.set_value(section, key, value)
	_cfg.save(PATH)


func set_ui_scale(value: float) -> void:
	ui_scale = snappedf(clampf(value, MIN_SCALE, MAX_SCALE), 0.05)
	_apply()
	set_value("ui", "scale", ui_scale)


func _detect_os_scale() -> float:
	if DisplayServer.get_name() == "headless":
		return 1.0
	var s := DisplayServer.screen_get_scale()
	if s <= 0.0 or is_equal_approx(s, 1.0):
		# Windows/Linux: derive from DPI (96 = 100%).
		var dpi := DisplayServer.screen_get_dpi()
		if dpi > 0:
			s = dpi / 96.0
	return snappedf(clampf(s, MIN_SCALE, MAX_SCALE), STEP)


func _apply() -> void:
	var root := get_tree().root
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	root.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_EXPAND
	# Base size = window / scale, so everything renders exactly ui_scale times larger.
	var sz := root.size
	root.content_scale_size = Vector2i(maxi(1, int(sz.x / ui_scale)), maxi(1, int(sz.y / ui_scale)))
	ui_scale_changed.emit(ui_scale)


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and event.ctrl_pressed and not event.echo):
		return
	match event.keycode:
		KEY_EQUAL, KEY_PLUS, KEY_KP_ADD:
			set_ui_scale(ui_scale + STEP)
		KEY_MINUS, KEY_KP_SUBTRACT:
			set_ui_scale(ui_scale - STEP)
		KEY_0:
			set_ui_scale(_detect_os_scale())
		_:
			return
	get_viewport().set_input_as_handled()
