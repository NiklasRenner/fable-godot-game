## In-game HUD: player and target frames, action bar with cooldown sweeps, cast bar, XP bar,
## combat log, quest tracker, death panel, and the windows (bag, character, NPC dialog, Esc menu).
## Everything reads the local player's synced state each frame; server events arrive as signals.
extends CanvasLayer

var bot_mode := false
var player: Player = null

var _root: Control
var _player_name: Label
var _hp_bar: ProgressBar
var _resource_bar: ProgressBar
var _copper_label: Label
var _player_badge: PanelContainer
var _target_frame: PanelContainer
var _target_badge: PanelContainer
var _target_name: Label
var _target_hp: ProgressBar
var _target_tag: Label
var _target_elite := false
var _action_tray: PanelContainer
var _action_bar: HBoxContainer
var _buttons := {} # ability_id -> {button, overlay, ready_time, duration}
var _bar_class := ""
var _gcd_ready := 0.0
var _gcd_duration := 1.0
var _cast_frame: PanelContainer
var _cast_bar: ProgressBar
var _cast_label: Label
var _cast_end := 0.0
var _cast_duration := 1.0
var _xp_bar: ProgressBar
var _log: RichTextLabel
var _loot_prompt: Label
var _tracker: VBoxContainer
var _death_panel: PanelContainer
var _death_label: Label
var _death_button: Button
var _ghost_overlay: ColorRect
var _zone_label: Label
var _map_viewport: SubViewport
var _map_camera: Camera3D
var _map_marks: Control
var _map_frame := 0
var _dialog_state := [] # [inventory, copper, quests] the dialog was last built from

var bag: BagWindow
var character: CharacterWindow
var dialog: NpcDialog
var menu: GameMenu


func _ready() -> void:
	add_to_group("hud")
	_build()
	get_tree().get_first_node_in_group("world").combat_event_received.connect(_on_combat_event)


func _process(_delta: float) -> void:
	if player == null or not is_instance_valid(player):
		player = get_tree().get_first_node_in_group("local_player")
		if player:
			_bind_player()
		return
	_refresh()


func _bind_player() -> void:
	bag.player = player
	character.player = player
	dialog.player = player
	player.cast_started.connect(_on_cast_started)
	player.cast_stopped.connect(func() -> void: _cast_frame.visible = false)
	player.cast_pushed_back.connect(func(seconds: float) -> void:
		_cast_end += seconds
		_cast_duration += seconds)
	player.target_changed.connect(func(t: Node) -> void:
		if t:
			_log_line("Target: %s" % t.display_name, Color(0.8, 0.8, 0.8)))
	player.cooldown_started.connect(func(id: String, duration: float) -> void:
		if _buttons.has(id):
			_buttons[id].ready_time = Unit.now() + duration
			_buttons[id].duration = duration)
	player.gcd_started.connect(func(duration: float) -> void:
		_gcd_ready = Unit.now() + duration
		_gcd_duration = duration)
	player.message.connect(_log_line.bind(Color(0.95, 0.9, 0.5)))
	player.message.connect(_message_sound)
	player.auto_attack_changed.connect(func(on: bool) -> void:
		_log_line("Auto-attack %s." % ("on" if on else "off"), Color(0.7, 0.7, 0.7)))
	player.loot_received.connect(_on_loot_received)
	player.npc_opened.connect(dialog.open)
	player.quests_changed.connect(_refresh_tracker)
	Settings.ui_scale_changed.connect(func(sc: float) -> void:
		_log_line("UI scale: %d%%" % int(round(sc * 100)), Color(0.7, 0.7, 0.7)))
	_log_line("I/B: bag · C: character · Esc: menu (settings, log out)", Color(0.7, 0.7, 0.7))
	_log_line("Welcome to Thornhill, %s. Boars, wolves and trolls await." % player.display_name, Color(0.6, 0.9, 1.0))


func toggle_menu() -> void:
	menu.toggle()


# ---------------------------------------------------------------- build

const SLOT := 52           # action bar button size (px)
const MAP_SIZE := 172      # minimap diameter (px)
const MAP_METRES := 90.0   # minimap span
const ICON_DIR := "res://assets/ui/icons/"


func _build() -> void:
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.theme = UITheme.make()
	add_child(_root)

	# Spirit-realm tint: a soft blue vignette over everything while you're a ghost.
	_ghost_overlay = ColorRect.new()
	_ghost_overlay.color = Color(0.35, 0.5, 0.85, 0.16)
	_ghost_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_ghost_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ghost_overlay.visible = false
	_root.add_child(_ghost_overlay)

	# Player frame (top-left) and target frame next to it: level badge, name, bars.
	var pf := _unit_frame(Vector2(16, 16), false)
	_player_badge = pf.badge
	_player_name = pf.name
	_hp_bar = pf.hp
	_resource_bar = UITheme.bar(Color(0.8, 0.15, 0.1), 14)
	pf.bars.add_child(_resource_bar)
	_copper_label = UITheme.small("", 11, UITheme.GOLD_TEXT)
	pf.bars.add_child(_copper_label)

	var tf := _unit_frame(Vector2(310, 16), true)
	_target_frame = tf.frame
	_target_badge = tf.badge
	_target_name = tf.name
	_target_hp = tf.hp
	_target_tag = UITheme.small("", 11, UITheme.ELITE)
	tf.bars.add_child(_target_tag)
	_target_frame.visible = false

	# Action bar (bottom centre) in its tray; cast bar and loot prompt above it; XP bar below.
	_action_tray = PanelContainer.new()
	_action_tray.add_theme_stylebox_override("panel", UITheme.frame_style())
	_root.add_child(_action_tray)
	_action_bar = HBoxContainer.new()
	_action_bar.add_theme_constant_override("separation", 6)
	_action_tray.add_child(_action_bar)

	var cast_frame := PanelContainer.new()
	cast_frame.add_theme_stylebox_override("panel", UITheme.slot_style(UITheme.BRASS, 3))
	_root.add_child(cast_frame)
	UITheme.anchor(cast_frame, Control.PRESET_CENTER_BOTTOM, Vector2(-130, -170), Vector2(260, 24))
	_cast_bar = ProgressBar.new()
	_cast_bar.show_percentage = false
	_cast_bar.custom_minimum_size = Vector2(0, 16)
	_cast_bar.add_theme_stylebox_override("fill", UITheme.fill_box(Color(1.0, 0.72, 0.1)))
	cast_frame.add_child(_cast_bar)
	_cast_label = UITheme.header("", 12, Color.WHITE)
	_cast_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	_cast_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_cast_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_cast_bar.add_child(_cast_label)
	_cast_frame = cast_frame
	_cast_frame.visible = false

	_loot_prompt = UITheme.header("Press F to loot", 16)
	_root.add_child(_loot_prompt)
	UITheme.anchor(_loot_prompt, Control.PRESET_CENTER_BOTTOM, Vector2(-120, -140), Vector2(240, 24))
	_loot_prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_loot_prompt.visible = false

	# XP bar along the bottom, split into 20 bubbles like Classic's.
	_xp_bar = UITheme.bar(Color(0.58, 0.22, 0.85), 12)
	_root.add_child(_xp_bar)
	_xp_bar.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_xp_bar.offset_left = 8
	_xp_bar.offset_right = -8
	_xp_bar.offset_top = -18
	_xp_bar.offset_bottom = -6
	_xp_bar.draw.connect(func() -> void:
		var w := _xp_bar.size.x
		for i in range(1, 20):
			var x := roundf(w * i / 20.0)
			_xp_bar.draw_line(Vector2(x, 1), Vector2(x, _xp_bar.size.y - 1), Color(0, 0, 0, 0.7), 1.0))

	# Combat log (bottom-left): text on a light smoke, no frame, like the chat frame.
	var lp := PanelContainer.new()
	var smoke := UITheme.panel_box(Color(0, 0, 0, 0.32), Color(0, 0, 0, 0), 3, 0, 8)
	lp.add_theme_stylebox_override("panel", smoke)
	_root.add_child(lp)
	UITheme.anchor(lp, Control.PRESET_BOTTOM_LEFT, Vector2(12, -222), Vector2(420, 190))
	lp.custom_minimum_size = Vector2(420, 190)
	_log = RichTextLabel.new()
	_log.scroll_following = true
	_log.bbcode_enabled = true
	_log.add_theme_font_size_override("normal_font_size", 13)
	_log.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	_log.add_theme_constant_override("shadow_offset_x", 1)
	_log.add_theme_constant_override("shadow_offset_y", 1)
	lp.add_child(_log)

	# Minimap and zone name (top-right), quest tracker under it.
	_build_minimap()
	_tracker = VBoxContainer.new()
	_root.add_child(_tracker)
	UITheme.anchor(_tracker, Control.PRESET_TOP_RIGHT, Vector2(-300, MAP_SIZE + 56), Vector2(284, 0))

	# Death / ghost panel (top centre).
	_death_panel = _panel(Control.PRESET_CENTER_TOP, Vector2(-200, 120), Vector2(400, 0))
	_death_panel.visible = false
	var dv := VBoxContainer.new()
	dv.custom_minimum_size.x = 380
	_death_panel.add_child(dv)
	_death_label = UITheme.header("", 16, Color(1.0, 0.45, 0.4))
	_death_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_death_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	dv.add_child(_death_label)
	_death_button = UITheme.button("", func() -> void:
		if player.is_dead:
			player.request("release")
		elif player.near_corpse():
			player.request("resurrect"))
	dv.add_child(_death_button)

	# Windows.
	character = CharacterWindow.new()
	_root.add_child(character)
	UITheme.anchor(character, Control.PRESET_CENTER_LEFT, Vector2(40, -220))
	bag = BagWindow.new()
	_root.add_child(bag)
	UITheme.anchor(bag, Control.PRESET_CENTER_RIGHT, Vector2(-360, -200))
	dialog = NpcDialog.new()
	_root.add_child(dialog)
	UITheme.anchor(dialog, Control.PRESET_CENTER_LEFT, Vector2(40, -200), Vector2(440, 0))
	menu = GameMenu.new()
	_root.add_child(menu)


func _panel(preset: int, offset: Vector2, size := Vector2.ZERO) -> PanelContainer:
	var p := PanelContainer.new()
	_root.add_child(p)
	UITheme.anchor(p, preset, offset, size)
	return p


## A unit frame: [badge] name over a health bar (badge on the right for the target, mirrored).
func _unit_frame(offset: Vector2, mirrored: bool) -> Dictionary:
	var frame := PanelContainer.new()
	frame.add_theme_stylebox_override("panel", UITheme.frame_style())
	_root.add_child(frame)
	UITheme.anchor(frame, Control.PRESET_TOP_LEFT, offset)
	frame.custom_minimum_size = Vector2(276, 0)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	frame.add_child(row)
	var badge := UITheme.level_badge()
	var bars := VBoxContainer.new()
	bars.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bars.add_theme_constant_override("separation", 3)
	if mirrored:
		row.add_child(bars)
		row.add_child(badge)
	else:
		row.add_child(badge)
		row.add_child(bars)
	var name := UITheme.header("", 14)
	name.clip_text = true
	bars.add_child(name)
	var hp := UITheme.bar(Color(0.1, 0.8, 0.1), 16)
	bars.add_child(hp)
	return {"frame": frame, "badge": badge, "name": name, "hp": hp, "bars": bars}


## The minimap: a top-down orthographic camera rendering the shared world into a small viewport,
## shown as a disc in a brass ring, north up, with the player's arrow, quest givers' marks and
## (as a ghost) your corpse. It redraws every other frame, without shadows.
func _build_minimap() -> void:
	var holder := Control.new()
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(holder)
	UITheme.anchor(holder, Control.PRESET_TOP_RIGHT, Vector2(-MAP_SIZE - 26, 10), Vector2(MAP_SIZE + 12, MAP_SIZE + 40))
	_zone_label = UITheme.header("Thornhill", 14)
	_zone_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_zone_label.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_zone_label.offset_bottom = 22
	holder.add_child(_zone_label)

	var disc := Control.new()
	disc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	disc.position = Vector2(6, 26)
	disc.size = Vector2(MAP_SIZE, MAP_SIZE)
	holder.add_child(disc)
	if DisplayServer.get_name() != "headless":
		_map_viewport = SubViewport.new()
		_map_viewport.size = Vector2i(MAP_SIZE, MAP_SIZE)
		_map_viewport.world_3d = get_viewport().world_3d
		_map_viewport.positional_shadow_atlas_size = 0
		_map_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
		add_child(_map_viewport)
		_map_camera = Camera3D.new()
		_map_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
		_map_camera.size = MAP_METRES
		_map_camera.far = 400.0
		_map_camera.rotation = Vector3(-PI / 2, 0, 0) # straight down, screen-up = north (-Z)
		var env := Environment.new()
		env.background_mode = Environment.BG_COLOR
		env.background_color = Color(0.08, 0.07, 0.06)
		env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		env.ambient_light_color = Color(0.75, 0.72, 0.65)
		env.ambient_light_energy = 0.9
		_map_camera.environment = env
		_map_viewport.add_child(_map_camera)
		var map := TextureRect.new()
		map.texture = _map_viewport.get_texture()
		map.set_anchors_preset(Control.PRESET_FULL_RECT)
		map.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var mat := ShaderMaterial.new()
		mat.shader = Shader.new()
		mat.shader.code = """
shader_type canvas_item;
void fragment() {
	float d = distance(UV, vec2(0.5));
	vec4 c = texture(TEXTURE, UV);
	c.rgb *= mix(1.08, 0.7, smoothstep(0.3, 0.5, d)); // a little vignette
	c.a *= 1.0 - smoothstep(0.495, 0.5, d);
	COLOR = c;
}"""
		map.material = mat
		disc.add_child(map)
	# marks and the arrow, drawn over the map
	_map_marks = Control.new()
	_map_marks.set_anchors_preset(Control.PRESET_FULL_RECT)
	_map_marks.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_map_marks.draw.connect(_draw_map_marks)
	disc.add_child(_map_marks)
	var ring := Panel.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0)
	sb.border_color = UITheme.BRASS
	sb.set_border_width_all(4)
	sb.set_corner_radius_all(MAP_SIZE / 2 + 4)
	sb.expand_margin_left = 4
	sb.expand_margin_right = 4
	sb.expand_margin_top = 4
	sb.expand_margin_bottom = 4
	sb.shadow_color = Color(0, 0, 0, 0.6)
	sb.shadow_size = 4
	sb.anti_aliasing = true
	ring.add_theme_stylebox_override("panel", sb)
	ring.set_anchors_preset(Control.PRESET_FULL_RECT)
	ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
	disc.add_child(ring)
	var north := UITheme.header("N", 12)
	north.position = Vector2(MAP_SIZE / 2.0 - 5.0, 2)
	disc.add_child(north)


func _draw_map_marks() -> void:
	if player == null or not is_instance_valid(player):
		return
	var c := Vector2(MAP_SIZE, MAP_SIZE) * 0.5
	var px_per_m := MAP_SIZE / MAP_METRES
	var r := MAP_SIZE * 0.5 - 6.0
	var to_map := func(w: Vector3) -> Vector2:
		var d := Vector2(w.x - player.global_position.x, w.z - player.global_position.z) * px_per_m
		return c + (d.limit_length(r))
	for npc in get_tree().get_nodes_in_group("npcs"):
		var state: String = npc.quest_marker_state(player.quests)
		if state == "":
			continue
		var at: Vector2 = to_map.call(npc.global_position)
		var col: Color = npc.marker_color(state)
		var glyph: String = npc.marker_glyph(state)
		_map_marks.draw_string_outline(UITheme.serif(700), at + Vector2(-4, 6), glyph, HORIZONTAL_ALIGNMENT_LEFT, -1, 17, 4, Color.BLACK)
		_map_marks.draw_string(UITheme.serif(700), at + Vector2(-4, 6), glyph, HORIZONTAL_ALIGNMENT_LEFT, -1, 17, col)
	if player.is_ghost:
		var at: Vector2 = to_map.call(player.corpse_position)
		_map_marks.draw_circle(at, 4.0, Color(0.9, 0.9, 0.95))
		_map_marks.draw_arc(at, 5.0, 0, TAU, 12, Color.BLACK, 1.5)
	# the player's arrow, pointing where they face (yaw 0 = north)
	var rot := -player.input_yaw
	var pts := PackedVector2Array([Vector2(0, -9), Vector2(6, 6), Vector2(0, 3), Vector2(-6, 6)])
	for i in range(pts.size()):
		pts[i] = c + pts[i].rotated(rot)
	_map_marks.draw_colored_polygon(pts, Color(1.0, 0.85, 0.2))
	pts.append(pts[0])
	_map_marks.draw_polyline(pts, Color.BLACK, 1.5)


func _refresh_minimap() -> void:
	var pos := player.global_position
	var world := get_tree().get_first_node_in_group("world")
	var underground: bool = world != null and pos.y < world.height_at(pos.x, pos.z) - 3.0
	_zone_label.text = "Mossback Warren" if underground else "Thornhill"
	_map_marks.queue_redraw()
	if _map_camera == null:
		return
	# Above ground the camera hangs high over the trees; in the warren just over your head, so
	# the rock above you is behind it.
	_map_camera.position = Vector3(pos.x, pos.y + (3.0 if underground else 120.0), pos.z)
	_map_frame += 1
	if _map_frame % 2 == 0:
		_map_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE


func _build_action_bar() -> void:
	for c in _action_bar.get_children():
		c.queue_free()
	_buttons.clear()
	var ids := GameData.class_bar(player.class_id)
	var normal := UITheme.slot_style()
	var hover := UITheme.slot_style(Color(0.9, 0.82, 0.55))
	var active := UITheme.slot_style(Color(1.0, 0.85, 0.2))
	for i in range(ids.size()):
		var id: String = ids[i]
		var ab: Dictionary = GameData.ABILITIES[id]
		var b := UITheme.button("", func() -> void: player.use_ability(id))
		b.custom_minimum_size = Vector2(SLOT, SLOT)
		b.tooltip_text = GameData.ability_tooltip(id)
		b.add_theme_stylebox_override("normal", normal)
		b.add_theme_stylebox_override("hover", hover)
		b.add_theme_stylebox_override("pressed", hover)
		var icon_path: String = ICON_DIR + id + ".png"
		if ResourceLoader.exists(icon_path):
			b.icon = load(icon_path)
			b.expand_icon = true
			b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
		else:
			b.text = ab.name.replace(" ", "\n")
			b.add_theme_font_size_override("font_size", 10)
		_action_bar.add_child(b)
		var overlay := ColorRect.new()
		overlay.color = Color(0, 0, 0, 0.62)
		overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
		overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
		overlay.offset_left = 4
		overlay.offset_top = 4
		overlay.offset_right = -4
		overlay.offset_bottom = -4
		overlay.visible = false
		b.add_child(overlay)
		var key := UITheme.small(str(i + 1), 11, Color(0.92, 0.92, 0.92))
		key.add_theme_color_override("font_outline_color", Color.BLACK)
		key.add_theme_constant_override("outline_size", 3)
		key.position = Vector2(SLOT - 13, 3)
		b.add_child(key)
		var cd := UITheme.header("", 17, Color(1, 0.95, 0.6))
		cd.set_anchors_preset(Control.PRESET_FULL_RECT)
		cd.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		cd.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		cd.add_theme_color_override("font_outline_color", Color.BLACK)
		cd.add_theme_constant_override("outline_size", 4)
		b.add_child(cd)
		_buttons[id] = {"button": b, "overlay": overlay, "cd": cd, "ready_time": 0.0, "duration": 1.0,
			"normal": normal, "active": active, "lit": false}
	# centre the tray over the bottom edge
	var w := ids.size() * (SLOT + 6) - 6 + 20
	UITheme.anchor(_action_tray, Control.PRESET_CENTER_BOTTOM, Vector2(-w / 2.0, -SLOT - 46))


# ---------------------------------------------------------------- input

func _any_window_open() -> bool:
	return dialog.visible or bag.visible or character.visible or menu.visible


func _input(event: InputEvent) -> void:
	if bot_mode:
		return
	if event.is_action_pressed("toggle_inventory"):
		bag.visible = not bag.visible
		Audio.play("open")
	elif event.is_action_pressed("toggle_character"):
		character.visible = not character.visible
		Audio.play("open")
	elif event.is_action_pressed("escape") and _any_window_open():
		# Esc closes windows first; with nothing open the player handles it.
		dialog.close()
		bag.visible = false
		character.visible = false
		menu.visible = false
	else:
		return
	get_viewport().set_input_as_handled()


# ---------------------------------------------------------------- refresh

func _refresh() -> void:
	if _bar_class != player.class_id:
		_bar_class = player.class_id
		_build_action_bar()
		_resource_bar.add_theme_stylebox_override("fill", UITheme.fill_box(Color(0.2, 0.4, 0.9) if player.uses_mana() else Color(0.8, 0.15, 0.1)))
	_player_name.text = player.display_name + ("  (Dead)" if player.is_dead else "  (Ghost)" if player.is_ghost else "")
	_player_badge.get_node("Level").text = str(player.level)
	UITheme.set_bar(_hp_bar, player.health, player.max_health)
	UITheme.set_bar(_resource_bar, player.resource, player.max_resource)
	_copper_label.text = "%s  ·  %s" % [player.cls().name, GameData.format_copper(player.copper)]
	UITheme.set_bar(_xp_bar, player.xp, GameData.xp_for_level(player.level))
	_xp_bar.get_node("Value").text = "XP %d / %d" % [player.xp, GameData.xp_for_level(player.level)]
	_refresh_cast_bar()
	_refresh_death()
	_refresh_minimap()
	_loot_prompt.visible = not player.is_dead and player.nearest_loot(LootBag.PICKUP_RANGE) != null

	var t: Node = player.local_target
	_target_frame.visible = t != null and is_instance_valid(t)
	if _target_frame.visible:
		_refresh_target(t)

	if bag.visible:
		bag.refresh()
	if character.visible:
		character.refresh()
	if menu.visible:
		menu.refresh()
	if dialog.visible:
		dialog.check_range()
		var state := [player.inventory, player.copper, player.quests]
		if state != _dialog_state:
			_dialog_state = state.duplicate(true)
			dialog.refresh()

	var now := Unit.now()
	for id in _buttons:
		var e: Dictionary = _buttons[id]
		var ab: Dictionary = GameData.ABILITIES[id]
		var remaining: float = e.ready_time - now
		var frac := 0.0
		if remaining > 0.0:
			frac = remaining / e.duration
		elif ab.triggers_gcd and _gcd_ready > now:
			frac = (_gcd_ready - now) / _gcd_duration
		e.overlay.visible = frac > 0.0
		e.overlay.anchor_top = 1.0 - frac
		e.overlay.offset_top = 4.0 * (1.0 - frac) # stay inside the slot's rim as it drains
		e.cd.text = str(int(ceil(remaining))) if remaining > 1.5 else ""
		var cost := GameData.ability_cost(ab)
		var lit: bool = ab.kind == "toggle" and player.auto_attack
		if lit != e.lit:
			e.lit = lit
			e.button.add_theme_stylebox_override("normal", e.active if lit else e.normal)
		if ab.kind == "toggle":
			e.button.modulate = Color(1, 1, 1) if not lit else Color(1.0, 0.92 + 0.08 * sin(now * 6.0), 0.8)
		else:
			e.button.modulate = Color.WHITE if player.resource >= cost else Color(0.45, 0.45, 0.9) # out of rage/mana: blue


## Target frame: name in the reaction colour (red hostile, green friendly), level in the
## difficulty colour, and the gold frame for a boss.
func _refresh_target(t: Node) -> void:
	_target_name.text = t.display_name
	_target_name.add_theme_color_override("font_color", Color(1.0, 0.82, 0.0) if t.get("faction") == "player" else Color(1.0, 0.3, 0.25))
	var badge: Label = _target_badge.get_node("Level")
	badge.text = str(t.level)
	badge.add_theme_color_override("font_color", UITheme.difficulty_color(t.level, player.level))
	UITheme.set_bar(_target_hp, t.health, t.max_health)
	var stats: Dictionary = t.get("stats") if t.get("stats") != null else {}
	var elite: bool = stats.get("rank", "") == "boss"
	_target_tag.text = "Boss" if elite else stats.get("family", "")
	_target_tag.add_theme_color_override("font_color", UITheme.ELITE if elite else UITheme.TEXT_DIM)
	if elite != _target_elite:
		_target_elite = elite
		_target_frame.add_theme_stylebox_override("panel", UITheme.frame_style(elite))


func _refresh_cast_bar() -> void:
	if not _cast_frame.visible:
		return
	var remaining := _cast_end - Unit.now()
	if remaining <= 0.0:
		_cast_frame.visible = false
		return
	_cast_bar.max_value = _cast_duration
	_cast_bar.value = _cast_duration - remaining


func _refresh_death() -> void:
	_ghost_overlay.visible = player.is_ghost
	_death_panel.visible = player.is_dead or player.is_ghost
	if player.is_dead:
		_death_label.text = "You have died.\nYour spirit will be released in %d s." % int(ceil(player.seconds_until_release()))
		_death_button.text = "Release Spirit"
		_death_button.disabled = false
	elif player.is_ghost:
		_death_label.text = "You are dead. Return to your corpse to resurrect.\nCorpse: %d m away" % int(player.global_position.distance_to(player.corpse_position))
		_death_button.text = "Resurrect (F)" if player.near_corpse() else "Resurrect (get closer)"
		_death_button.disabled = not player.near_corpse()


func _refresh_tracker() -> void:
	for c in _tracker.get_children():
		c.queue_free()
	var any := false
	for qid in player.quests:
		if player.quests[qid].state == "active":
			any = true
	if any:
		_tracker.add_child(UITheme.header("Quests", 15))
	for qid in player.quests:
		var entry: Dictionary = player.quests[qid]
		if entry.state != "active":
			continue
		var q := GameData.quest(qid)
		var done := GameData.quest_complete(q, entry.progress)
		_tracker.add_child(_shadowed(UITheme.small(q.name + (" (Complete)" if done else ""), 13, UITheme.GOLD_TEXT)))
		for i in range(q.objectives.size()):
			var n: int = entry.progress[i] if i < entry.progress.size() else 0
			var color := Color(0.6, 0.85, 0.55) if n >= q.objectives[i].count else UITheme.TEXT
			_tracker.add_child(_shadowed(UITheme.small("  - " + GameData.objective_text(q, i, entry.progress), 12, color)))


## Text straight on the 3D view needs a dark edge to read over bright grass.
func _shadowed(l: Label) -> Label:
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	l.add_theme_constant_override("outline_size", 3)
	return l


# ---------------------------------------------------------------- events

func _on_cast_started(ability_id: String, duration: float) -> void:
	_cast_end = Unit.now() + duration
	_cast_duration = duration
	_cast_label.text = GameData.ABILITIES[ability_id].name
	_cast_frame.visible = true
	if ability_id != "shoot":
		Audio.play("cast", -4.0)


## Server messages double as audio cues for the owning client.
func _message_sound(text: String) -> void:
	for prefix in SOUND_CUES:
		if text.begins_with(prefix):
			Audio.play(SOUND_CUES[prefix][0], SOUND_CUES[prefix][1])
			return


const SOUND_CUES := {
	"Quest accepted": ["quest", 0.0], "Quest completed": ["quest", 0.0],
	"You buy": ["coin", 0.0], "You sell": ["coin", 0.0], "You receive ": ["coin", 0.0],
	"You sit down": ["eat", 0.0],
	"Equipped": ["click", -2.0], "Destroyed": ["click", -2.0],
	"You have died": ["death", 0.0], "You feel the warmth": ["resurrect", 0.0],
	"You are a ghost": ["open", -4.0],
	"Interrupted": ["click", -6.0], "Your target is dead": ["click", -6.0],
}


func _on_loot_received(items: Array) -> void:
	Audio.play("loot")
	for id in items:
		var q: String = GameData.item_stat(id, "quality", "common")
		_log_line("You receive loot: [color=#%s]%s[/color]" % [GameData.QUALITY_COLORS[q].to_html(false), GameData.item_stat(id, "name", id)], Color.WHITE)


func _on_combat_event(source: String, target: Node, amount: int, kind: String) -> void:
	if target == null:
		return
	var tname: String = target.get("display_name")
	if kind == "dies":
		_log_line("%s dies." % source, Color(0.7, 0.7, 0.7))
	elif amount == 0:
		_log_line("%s uses %s on %s." % [source, kind, tname], Color(0.95, 0.85, 0.4))
	else:
		var col := Color(1, 0.35, 0.3) if target.get("faction") == "player" else Color(1, 0.95, 0.7)
		if kind == "melee":
			_log_line("%s hits %s for %d." % [source, tname, amount], col)
		else:
			_log_line("%s's %s hits %s for %d." % [source, kind, tname, amount], col)


func _log_line(text: String, color: Color) -> void:
	_log.append_text("[color=#%s]%s[/color]\n" % [color.to_html(false), text])
	if bot_mode:
		print("[HUD] " + text)
