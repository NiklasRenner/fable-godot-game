## Animation contact sheet rendered by the real engine: loads a character model (a key of
## GameData.MODELS, so the same facing/yaw the game uses), and for every clip renders six evenly
## spaced frames from the front three-quarter view and one from the side, into one PNG.
##
## Run this scene (editor: F6 on it; or the Godot MCP's run_project with scene =
## res://tools/preview/model_preview.tscn). It reads `res://preview.request`:
##     line 1: model key, e.g. hero          (default: hero); "hero@res://x.glb" uses that file
##             with the hero's profile (candidate clips)
##     line 2: output path                   (default: res://meshy/preview_<key>.png)
##     line 3: optional "<clip> <frames> [side]": only that clip ("*": every clip), at that many
##             frames (timing studies; each cell's time is printed); "side" renders every frame
##             from the side (leans and strides)
##     line 4: optional "armor <set> [weapon] [-slot ...] [slot=set ...]": dress the model in that
##             armour set (Outfit), holding the weapon model, leaving off the "-slot" pieces and
##             taking "slot=set" pieces from another set (mixing)
##     line 5: optional "<camera height> <view size>" (metres): a close-up, e.g. "1.5 0.8" for
##             the head and shoulders
## then saves the sheet and quits.
extends Node3D

const FRAMES := 6
const CELL := Vector2i(256, 320)

var _vp: SubViewport
var _pivot: Node3D
var _cam: Camera3D


func _ready() -> void:
	var req := FileAccess.get_file_as_string("res://preview.request").split("\n") if FileAccess.file_exists("res://preview.request") else PackedStringArray()
	var key := req[0].strip_edges() if req.size() > 0 and req[0].strip_edges() != "" else "hero"
	var out := req[1].strip_edges() if req.size() > 1 and req[1].strip_edges() != "" else "res://meshy/preview_%s.png" % key
	var only := ""
	var frames := FRAMES
	var all_side := false
	if req.size() > 2 and req[2].strip_edges() != "":
		var f := req[2].strip_edges().split(" ")
		only = f[0]
		frames = int(f[1]) if f.size() > 1 else FRAMES
		all_side = f.size() > 2 and f[2] == "side"
	# "hero@res://path/to.glb": the hero's profile with another file (e.g. candidate clips)
	var override := ""
	if key.contains("@"):
		override = key.get_slice("@", 1)
		key = key.get_slice("@", 0)
	var profile: Dictionary = GameData.MODELS[key].duplicate()
	if override != "":
		profile.path = override
	_build_stage()
	if req.size() > 4 and req[4].strip_edges() != "":
		var z := req[4].strip_edges().split(" ")
		_cam.position.y = float(z[0])
		_cam.size = float(z[1]) if z.size() > 1 else _cam.size
	var inst: Node3D = load(profile.path).instantiate()
	Unit.prepare_model(inst, profile)
	_pivot.add_child(inst)
	if req.size() > 3 and req[3].strip_edges().begins_with("armor "):
		await get_tree().process_frame
		# "armor <set> [weapon] [-slot ...] [slot=set ...]"
		var a := req[3].strip_edges().split(" ")
		var armor := Outfit.whole_armor(a[1])
		var weapon := ""
		for w in a.slice(2):
			if w.begins_with("-"):
				armor.erase(w.substr(1)) # "-head": that piece left off
			elif w.contains("="):
				armor[w.get_slice("=", 0)] = w.get_slice("=", 1) # "legs=merc_d": a piece of another set
			else:
				weapon = w
		var skins := Outfit.armor_skins(armor)
		Outfit.dress(_pivot, profile, {"armor": armor, "skins": skins, "weapon": weapon})
	var anim: AnimationPlayer = inst.find_child("AnimationPlayer", true, false)
	var clips: PackedStringArray = anim.get_animation_list() if anim else PackedStringArray()
	if only != "" and only != "*":
		clips = PackedStringArray([only])
	var sheet := Image.create((frames + 1) * CELL.x, maxi(1, clips.size()) * CELL.y, false, Image.FORMAT_RGBA8)
	sheet.fill(Color(0.85, 0.85, 0.88))
	if clips.is_empty():
		clips = PackedStringArray(["(static)"]) # an unanimated model: turntable of its rest pose
	for row in range(clips.size()):
		var clip := clips[row]
		var length := anim.get_animation(clip).length if anim and anim.has_animation(clip) else 1.0
		if anim and anim.has_animation(clip):
			anim.play(clip)
			anim.speed_scale = 0.0
		for col in range(frames + 1):
			var side := col == frames or all_side
			var t := length * (0.5 if col == frames else float(col) / frames)
			if anim and anim.has_animation(clip):
				anim.seek(t, true)
				_pivot.rotation.y = deg_to_rad(90.0 if side else 30.0) # model turned, camera fixed in front
			else:
				_pivot.rotation.y = TAU * col / (frames + 1) # turntable
			await RenderingServer.frame_post_draw
			await RenderingServer.frame_post_draw
			var img := _vp.get_texture().get_image()
			img.convert(Image.FORMAT_RGBA8)
			sheet.blit_rect(img, Rect2i(Vector2i.ZERO, CELL), Vector2i(col * CELL.x, row * CELL.y))
			if only != "" and only != "*":
				print("[preview]   col %d = %.2f s" % [col, t])
		print("[preview] %s (%.2f s)" % [clip, length])
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out.get_base_dir()))
	sheet.save_png(ProjectSettings.globalize_path(out))
	print("[preview] %d clips -> %s (rows in this order: %s)" % [clips.size(), out, ", ".join(clips)])
	get_tree().quit()


func _build_stage() -> void:
	_vp = SubViewport.new()
	_vp.size = CELL
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_vp.own_world_3d = true
	add_child(_vp)
	var root := Node3D.new()
	_vp.add_child(root)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.78, 0.8, 0.84)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.8, 0.8, 0.85)
	env.environment.ambient_light_energy = 0.8
	root.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-40, 30, 0)
	root.add_child(sun)
	var floor_mi := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(3, 3)
	floor_mi.mesh = plane
	root.add_child(floor_mi)
	_pivot = Node3D.new()
	root.add_child(_pivot)
	_cam = Camera3D.new()
	_cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	_cam.size = 2.4
	# The model faces Godot's forward (-Z), so the camera stands at -Z looking back at its face.
	_cam.position = Vector3(0, 1.0, -4.0)
	_cam.rotation.y = PI
	root.add_child(_cam)
	_cam.current = true
