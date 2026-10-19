## Spell-effect test bench: a caster and a target dummy on a patch of ground under the game's
## sky and sun, the real Vfx node, and a list of shots. Each shot plays one effect and saves a
## frame `wait` seconds into it, so an effect can be judged (and compared before/after) without
## monsters wandering in. Works on the Compatibility renderer too (no decals there).
##
## Run this scene (editor: F6; or the Godot MCP's run_project with scene =
## res://tools/preview/fx_preview.tscn). It reads `res://fx_preview.request`, one shot per line:
##     <output png> <effect> <wait seconds> [camera: orbit_degrees distance height]
## effects: fireball frostbolt wand fireball_hit frostbolt_hit cast_fire cast_frost cast_arcane
##          frost_nova blink_out blink_in heroic_strike melee thunder_clap charge charge_start
##          level_up death
extends Node3D

var vfx: Node3D
var caster: Node3D
var target: Node3D
var cam: Camera3D


func _ready() -> void:
	var world: Node = load("res://scenes/world.tscn").instantiate()
	for n in ["WorldEnvironment", "Sun"]:
		var node: Node = world.get_node(n)
		world.remove_child(node)
		add_child(node)
	world.free()
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(80, 80)
	ground.mesh = plane
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.32, 0.45, 0.2)
	gm.roughness = 1.0
	ground.material_override = gm
	ground.layers = 1 | FxKit.GROUND_LAYER
	add_child(ground)
	caster = _figure("res://assets/hero.glb", Vector3.ZERO, 0.0)
	target = _figure("res://assets/boar.glb", Vector3(0, 0, -10), PI)
	caster.look_at(target.global_position, Vector3.UP)
	vfx = load("res://scripts/world/vfx.gd").new()
	add_child(vfx)
	cam = Camera3D.new()
	cam.fov = 60.0
	add_child(cam)
	cam.make_current()
	_run.call_deferred()


func _figure(path: String, pos: Vector3, yaw: float) -> Node3D:
	var root := Node3D.new()
	add_child(root)
	root.global_position = pos
	var m: Node3D = load(path).instantiate()
	m.rotation.y = yaw
	root.add_child(m)
	var ap := m.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if ap:
		for a in ap.get_animation_list():
			if a.to_lower().contains("idle"):
				ap.play(a)
				break
	return root


func _run() -> void:
	var path := "res://fx_preview.request"
	var lines := FileAccess.get_file_as_string(path).split("\n") if FileAccess.file_exists(path) else PackedStringArray()
	for line in lines:
		var f := line.strip_edges().split(" ", false)
		if f.size() < 3 or f[0].begins_with("#"):
			continue
		var orbit := deg_to_rad(float(f[3])) if f.size() > 3 else deg_to_rad(60.0)
		var dist := float(f[4]) if f.size() > 4 else 9.0
		var height := float(f[5]) if f.size() > 5 else 3.0
		var close: bool = f[1] in ["heroic_strike", "melee", "charge"]
		target.global_position = Vector3(0, 0, -2.4 if close else -10.0)
		caster.look_at(target.global_position, Vector3.UP)
		var mid := Vector3(0, 1.0, 0)
		if f[1] in ["fireball", "frostbolt", "wand"]:
			mid = Vector3(0, 1.0, -5.0)
		elif f[1].ends_with("_hit"):
			mid = Vector3(0, 1.0, -9.0)
		elif close:
			mid = Vector3(0, 1.0, -1.2)
		cam.global_position = mid + Vector3(sin(orbit) * dist, height, cos(orbit) * dist)
		cam.look_at(mid, Vector3.UP)
		await get_tree().create_timer(2.5).timeout # let the previous shot's effect finish
		_play(f[1])
		await get_tree().create_timer(maxf(0.02, float(f[2]))).timeout
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		img.save_png(ProjectSettings.globalize_path(f[0]))
		print("[FxPreview] saved %s" % f[0])
	get_tree().quit()


func _play(name: String) -> void:
	match name:
		"fireball_hit", "frostbolt_hit":
			# the bolt fired from just in front of the target, so the picture catches the impact
			var near := _figure("res://assets/hero.glb", target.global_position + Vector3(0, 0, 3), 0.0)
			near.visible = false
			near.look_at(target.global_position, Vector3.UP)
			var school := name.trim_suffix("_hit")
			vfx.projectile(near, target, vfx.SCHOOL_COLORS[school], 200.0, school)
			near.queue_free.call_deferred()
		_:
			if not vfx.preview(name, caster, target):
				push_warning("fx_preview: no effect %s" % name)
