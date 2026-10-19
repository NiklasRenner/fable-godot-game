## Entry scene: login (account name + host/join), then character select / create, then the world.
## Also parses command-line args so the game runs headless for the tests:
##   godot --headless -- --server --autoquit=10
##   godot --headless -- --join=127.0.0.1 --bot --autoquit=10
##   godot --headless -- --host --selftest --autoquit=60
extends Control

const WORLD_SCENE := preload("res://scenes/world.tscn")
const HUD_SCENE := preload("res://scenes/hud.tscn")

var world: Node3D
var hud: CanvasLayer
var account := ""
var characters: Array = []
var _bot := false
var _pending_delete := ""

# character screens (built in code)
var select_panel: PanelContainer
var _select_list: VBoxContainer
var _select_status: Label
var _create: PanelContainer
var _create_name: LineEdit
var _create_class := "warrior"
var _class_buttons := {}
var _dim: ColorRect

@onready var menu: PanelContainer = $Menu
@onready var ip_edit: LineEdit = $Menu/Box/IpEdit
@onready var status_label: Label = $Menu/Box/Status
@onready var account_edit: LineEdit = $Menu/Box/AccountEdit


func _ready() -> void:
	theme = UITheme.make()
	$Menu/Box/Title.add_theme_color_override("font_color", UITheme.GOLD_TEXT)
	$Menu/Box/Subtitle.add_theme_color_override("font_color", UITheme.TEXT_DIM)
	$Menu/Box/HostButton.pressed.connect(_on_login.bind(true))
	$Menu/Box/JoinButton.pressed.connect(_on_login.bind(false))
	Net.connection_failed.connect(func() -> void: _fail("Connection failed"))
	Net.server_disconnected.connect(func() -> void:
		_fail("Disconnected from server")
		Net.reset())
	Net.character_list.connect(_on_character_list)
	Net.lobby_error.connect(func(message: String) -> void:
		_create.visible = false
		select_panel.visible = true
		_select_status.text = message)
	Net.entered_world.connect(_on_entered_world)
	multiplayer.connected_to_server.connect(func() -> void:
		menu.visible = false
		Net.request("login", [account]))
	_dim = ColorRect.new()
	_dim.color = Color(0.03, 0.03, 0.04, 1.0)
	_dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_dim)
	move_child(_dim, 0)
	_build_character_screens()
	account_edit.text = str(Settings.get_value("login", "account", ""))
	ip_edit.text = str(Settings.get_value("login", "ip", "127.0.0.1"))
	_handle_cmdline()


func _handle_cmdline() -> void:
	var join_ip := ""
	var mode := ""
	var selftest := false
	var autoquit := 0.0
	for a in OS.get_cmdline_user_args():
		if a == "--server" or a == "--host":
			mode = a
		elif a == "--bot":
			_bot = true
			Net.bot_mode = true
		elif a == "--selftest":
			selftest = true
		elif a.begins_with("--join="):
			join_ip = a.get_slice("=", 1)
		elif a.begins_with("--autoquit="):
			autoquit = float(a.get_slice("=", 1))
	if OS.get_environment("THORNHILL_PERF") != "":
		add_child(load("res://tests/perf_probe.gd").new())
	if FileAccess.file_exists(SCREENSHOT_REQUEST) and DisplayServer.get_name() != "headless":
		_screenshot_run()
		return
	if autoquit > 0.0:
		get_tree().create_timer(autoquit).timeout.connect(func() -> void:
			print("[Main] autoquit after %.1fs" % autoquit)
			get_tree().quit())
	if mode == "--server":
		start_dedicated()
	elif mode == "--host":
		account = "selftest" if selftest else "host"
		start_host()
		if selftest:
			var test: Node = load("res://tests/selftest.gd").new()
			add_child(test)
			test.run(self)
	elif join_ip != "":
		account = "bot%d" % (randi() % 100000) if _bot else "guest"
		start_join(join_ip)


## Dev helper: with a `screenshot.request` file in the project root the game hosts, enters a fresh
## character, frames a view, saves a screenshot and quits (how the README picture is taken).
## Several shots in one run: separate blocks with a line "---". Per block:
##     line 1: output path (default res://docs/screenshot.png)
##     line 2: optional framing "x z yaw pitch zoom [orbit]" (default: the warren's hill)
##     line 3: optional "class [item ...]" to dress the character: each item goes in its slot
##             (first block only; default: warrior, starter kit)
##     line 4: optional actions, e.g. "goto troll 6" (stand 6 m from the nearest troll,
##             facing it, and target it), "npc edric" (talk to an NPC), "bag", "char",
##             "fx fireball wait 0.3" (play an effect after the settle, capture 0.3 s into it),
##             "top 60" (a straight-down orthographic map of 60 m around x z, no HUD),
##             "loot" (drop a loot bag 2.5 m in front of the character)
const SCREENSHOT_REQUEST := "res://screenshot.request"

func _screenshot_run() -> void:
	var blocks := FileAccess.get_file_as_string(SCREENSHOT_REQUEST).split("\n---")
	var first := blocks[0].strip_edges(true, false).split("\n")
	var g := PackedStringArray(first[2].split(" ", false)) if first.size() > 2 else PackedStringArray()
	account = "screenshot"
	start_host()
	Persistence.delete_character("screenshot", "Hero") # always a fresh character: the current starter kit
	Net.request("create", ["Hero", g[0] if g.size() > 0 else "warrior"])
	Net.request("enter", [characters[0].name])
	await get_tree().create_timer(1.5).timeout
	var p: Node = get_tree().get_first_node_in_group("local_player")
	if g.size() > 1:
		var gear: Dictionary = p.equipment.duplicate()
		for id in g.slice(1): # items to wear, each in its own slot (a weapon id still works)
			var slot: String = GameData.item_stat(id, "slot", "")
			if slot != "":
				gear[slot] = id
		p.equipment = gear
	for block in blocks:
		await _screenshot_shot(p, block.strip_edges(true, false).split("\n"))
	get_tree().quit()


func _screenshot_shot(p: Node, lines: PackedStringArray) -> void:
	var out := lines[0].strip_edges()
	if out == "":
		out = "res://docs/screenshot.png"
	var f := PackedStringArray(lines[1].split(" ", false)) if lines.size() > 1 else PackedStringArray()
	var acts := PackedStringArray(lines[3].split(" ", false)) if lines.size() > 3 else PackedStringArray()
	var hud := get_tree().get_first_node_in_group("hud")
	hud.bag.visible = false
	hud.character.visible = false
	hud.dialog.close()
	var x := float(f[0]) if f.size() > 0 else -24.0
	var z := float(f[1]) if f.size() > 1 else -26.0
	p.global_position = Vector3(x, world.height_at(x, z) + 0.6, z)
	p.input_yaw = float(f[2]) if f.size() > 2 else PI / 2 + 0.15 # default: looking west, at the warren's hill
	p.camera_rig.pitch = float(f[3]) if f.size() > 3 else -0.2
	p.camera_rig.arm.spring_length = float(f[4]) if f.size() > 4 else 9.0
	p.camera_rig.orbit_yaw = float(f[5]) if f.size() > 5 else 0.0
	var top_cam: Camera3D = null
	var fx: Array[String] = []
	var wait := -1.0
	var k := 0
	while k < acts.size():
		match acts[k]:
			"goto":
				var kind := acts[k + 1]
				var dist := 6.0
				k += 1
				if k + 1 < acts.size() and acts[k + 1].is_valid_float():
					dist = float(acts[k + 1])
					k += 1
				var best: Node3D = null
				for m in get_tree().get_nodes_in_group("monsters"):
					if m.kind == kind and not m.is_dead and (best == null or m.global_position.distance_to(p.global_position) < best.global_position.distance_to(p.global_position)):
						best = m
				if best:
					best.set_physics_process(false) # hold still for the picture
					# stand `dist` away on walkable ground (in a cave the open side may be rock)
					var nav := get_viewport().world_3d.navigation_map
					var at := best.global_position
					for i in range(8):
						var dir := Vector3(1, 0, 0.4).normalized().rotated(Vector3.UP, i * TAU / 8.0)
						var spot := NavigationServer3D.map_get_closest_point(nav, best.global_position + dir * dist)
						if absf(spot.distance_to(best.global_position) - dist) < 1.5:
							at = spot
							break
					p.global_position = at + Vector3(0, 0.3, 0)
					var d: Vector3 = best.global_position - p.global_position
					p.input_yaw = atan2(-d.x, -d.z)
					p.targeting.set_target(best)
			"npc":
				k += 1
				var npc: Node3D = world.get_npc(acts[k])
				p.global_position = npc.global_position + npc.global_transform.basis.z * 3.0 + Vector3(0, 0.3, 0)
				var d: Vector3 = npc.global_position - p.global_position
				p.input_yaw = atan2(-d.x, -d.z)
				p.npc_opened.emit(acts[k])
			"fx":
				k += 1
				fx.append(acts[k])
			"wait":
				k += 1
				wait = float(acts[k])
			"top":
				# straight down, orthographic, `size` metres across, centred on the framing's x z
				k += 1
				var cam := Camera3D.new()
				cam.projection = Camera3D.PROJECTION_ORTHOGONAL
				cam.size = float(acts[k])
				cam.far = 500.0
				cam.rotation = Vector3(-PI / 2, 0, 0)
				var env: Environment = world.get_node("WorldEnvironment").environment.duplicate()
				env.fog_enabled = false # 150 m of haze would wash the map out
				env.volumetric_fog_enabled = false
				cam.environment = env
				world.add_child(cam)
				cam.global_position = Vector3(x, 150.0, z)
				cam.make_current()
				hud.visible = false
				top_cam = cam
			"loot":
				var ahead: Vector3 = p.global_position - Vector3(sin(p.input_yaw), 0, cos(p.input_yaw)) * 2.5
				world.spawn_loot(Vector3(ahead.x, world.height_at(ahead.x, ahead.z), ahead.z), ["rusty_club"], multiplayer.get_unique_id())
			"bag":
				hud.bag.visible = true
			"char":
				hud.character.visible = true
		k += 1
	await get_tree().create_timer(2.5).timeout # let the models and grass settle in
	if not fx.is_empty():
		_screenshot_fx(p, fx)
		await get_tree().create_timer(maxf(0.02, wait)).timeout
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out.get_base_dir()))
	img.save_png(ProjectSettings.globalize_path(out))
	print("[Main] screenshot saved to %s" % out)
	if top_cam:
		top_cam.queue_free()
		hud.visible = true
		p.camera_rig.camera.make_current()


## Plays effects for a picture ("fx <name>" in the request, names as Vfx.preview).
func _screenshot_fx(p: Node3D, names: Array[String]) -> void:
	var t: Node3D = p.targeting.target if p.targeting.target else p
	for n in names:
		if not world.vfx.preview(n, p, t):
			push_warning("screenshot: no effect %s" % n)


# ---------------------------------------------------------------- login

func _on_login(host: bool) -> void:
	account = account_edit.text.strip_edges()
	if Persistence.sanitize(account).length() < 2:
		status_label.text = "Enter an account name first."
		return
	Settings.set_value("login", "account", account)
	Settings.set_value("login", "ip", ip_edit.text.strip_edges())
	if host:
		start_host()
	else:
		start_join(ip_edit.text.strip_edges())


## The world must exist on this peer BEFORE connecting so MultiplayerSpawner can receive the
## spawn list the server sends on connect.
func _spawn_world() -> void:
	world = WORLD_SCENE.instantiate()
	add_child(world)
	move_child(world, 0)
	menu.visible = false


func start_dedicated() -> void:
	_spawn_world()
	if Net.host() != OK:
		_fail("Could not start server")
		return
	world.start_server()
	_dim.visible = false
	print("[Main] Dedicated server running")


func start_host() -> void:
	_spawn_world()
	if Net.host() != OK:
		_fail("Could not host (port in use?)")
		return
	world.start_server()
	Net.request("login", [account])


func start_join(ip: String) -> void:
	_spawn_world()
	if Net.join(ip if ip != "" else "127.0.0.1") != OK:
		_fail("Bad address")
		return
	status_label.text = "Connecting to %s..." % ip
	menu.visible = true


func _fail(msg: String) -> void:
	push_error(msg)
	if hud:
		hud.queue_free()
		hud = null
	if world:
		world.queue_free()
		world = null
	select_panel.visible = false
	_create.visible = false
	_dim.visible = true
	menu.visible = true
	status_label.text = msg


## Esc menu -> Log out: drop the connection (a host also stops serving) and start over.
func logout() -> void:
	Net.reset()
	get_tree().reload_current_scene()


# ---------------------------------------------------------------- character select / create

## A CenterContainer stretched over the window keeps a panel centred whatever its size.
func _centered(panel: PanelContainer) -> void:
	var cc := CenterContainer.new()
	cc.set_anchors_preset(Control.PRESET_FULL_RECT)
	cc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(cc)
	cc.add_child(panel)


func _build_character_screens() -> void:
	select_panel = PanelContainer.new()
	_centered(select_panel)
	select_panel.custom_minimum_size = Vector2(420, 0)
	select_panel.visible = false
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	select_panel.add_child(v)
	v.add_child(UITheme.header("Characters", 20))
	v.add_child(HSeparator.new())
	_select_list = VBoxContainer.new()
	_select_list.add_theme_constant_override("separation", 6)
	v.add_child(_select_list)
	_select_status = UITheme.small("", 13, UITheme.TEXT_DIM)
	_select_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_select_status.custom_minimum_size.x = 400
	v.add_child(_select_status)
	v.add_child(UITheme.button("Create new character", _show_create))

	_create = PanelContainer.new()
	_centered(_create)
	_create.custom_minimum_size = Vector2(520, 0)
	_create.visible = false
	var cv := VBoxContainer.new()
	cv.add_theme_constant_override("separation", 8)
	_create.add_child(cv)
	cv.add_child(UITheme.header("New character", 20))
	cv.add_child(HSeparator.new())
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	cv.add_child(row)
	for cid in GameData.CLASSES:
		var c: Dictionary = GameData.CLASSES[cid]
		var b := UITheme.button("%s\n\n%s" % [c.name, c.blurb], _set_create_class.bind(cid))
		b.custom_minimum_size = Vector2(240, 120)
		b.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		row.add_child(b)
		_class_buttons[cid] = b
	cv.add_child(UITheme.small("Name", 13))
	_create_name = LineEdit.new()
	_create_name.max_length = Persistence.MAX_NAME
	_create_name.placeholder_text = "Letters, digits and _"
	cv.add_child(_create_name)
	var br := HBoxContainer.new()
	br.add_theme_constant_override("separation", 8)
	cv.add_child(br)
	br.add_child(UITheme.button("Create", func() -> void: Net.request("create", [_create_name.text, _create_class])))
	br.add_child(UITheme.button("Back", func() -> void:
		_create.visible = false
		select_panel.visible = true))
	_set_create_class("warrior")


func _set_create_class(cid: String) -> void:
	_create_class = cid
	for k in _class_buttons:
		var b: Button = _class_buttons[k]
		b.add_theme_stylebox_override("normal", UITheme.button_box(Color(0.24, 0.2, 0.15) if k == cid else UITheme.BG_LIGHT, UITheme.BRASS if k == cid else UITheme.BRASS_DIM))


func _show_create() -> void:
	select_panel.visible = false
	_create.visible = true
	_create_name.text = ""
	_create_name.grab_focus()


func _on_character_list(list: Array) -> void:
	characters = list
	if hud: # came back from the world (Esc menu -> Character screen)
		hud.queue_free()
		hud = null
		_dim.visible = true
	menu.visible = false
	_create.visible = false
	select_panel.visible = true
	_select_status.text = "" if not list.is_empty() else "No characters yet. Create one."
	for c in _select_list.get_children():
		c.queue_free()
	for ch in list:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		_select_list.add_child(row)
		var cname: String = ch.name
		var enter := UITheme.button("%s  —  level %d %s" % [cname, ch.level, GameData.cls(ch["class"]).name], func() -> void:
			_select_status.text = "Entering the world..."
			Net.request("enter", [cname]))
		enter.alignment = HORIZONTAL_ALIGNMENT_LEFT
		enter.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(enter)
		row.add_child(UITheme.button("Delete", func() -> void:
			if _pending_delete == cname:
				Net.request("delete", [cname])
				_pending_delete = ""
			else:
				_pending_delete = cname
				_select_status.text = "Click Delete again to delete %s for good." % cname))
	if _bot:
		# Headless bot: create "Bot" (BOT_CLASS env var picks the class) and go.
		if characters.is_empty():
			Net.request("create", ["Bot", OS.get_environment("BOT_CLASS") if OS.get_environment("BOT_CLASS") != "" else "warrior"])
		else:
			Net.request("enter", [characters[0].name])


func _on_entered_world() -> void:
	select_panel.visible = false
	_create.visible = false
	_dim.visible = false
	menu.visible = false
	hud = HUD_SCENE.instantiate()
	hud.bot_mode = _bot
	add_child(hud)
