## Spell and combat effects, stylised-MMO style. Every effect is a few layers built from FxKit:
## a bright core (glints, glow), a body that tears apart as it fades (textured, eroding fire /
## smoke / wisp particles), motion (ribbon trails, swing arcs, expanding rings and walls) and the
## aftermath (scorch and frost decals, embers, drifting smoke), plus a light flash and, for the
## big hits, a small camera shake. Runs on every peer, purely cosmetic.
## World feeds it combat events (`on_combat_event`) and VFX pings (`play`).
extends Node3D

const HS_COLOR := Color(1.0, 0.45, 0.12)
const CHARGE_COLOR := Color(0.95, 0.75, 0.3)
const TC_COLOR := Color(0.45, 0.72, 1.0)
const HIT_COLOR := Color(1.0, 0.85, 0.55)
const LEVEL_COLOR := Color(1.0, 0.8, 0.3)
const DUST := Color(0.55, 0.47, 0.36)

const FROST_COLOR := Color(0.5, 0.8, 1.0)
const FIRE_COLOR := Color(1.0, 0.48, 0.1)
const ARCANE_COLOR := Color(0.72, 0.45, 1.0)
const SCHOOL_COLORS := {"frostbolt": FROST_COLOR, "fireball": FIRE_COLOR}
const WAND_SPEED := 40.0
const HAND_OFFSET := Vector3(0, 1.3, 0)

# colour ramps (over a particle's life: colour, and alpha = presence, spent as erosion)
const FIRE_RAMP := [Color(1.0, 0.8, 0.4, 1.0), Color(1.0, 0.5, 0.12, 0.95), Color(0.85, 0.22, 0.04, 0.7), Color(0.4, 0.06, 0.02, 0.0)]
const SMOKE_RAMP := [Color(0.16, 0.13, 0.12, 0.0), Color(0.16, 0.14, 0.13, 0.6), Color(0.24, 0.23, 0.22, 0.35), Color(0.3, 0.3, 0.3, 0.0)]
const FROST_RAMP := [Color(1.0, 1.0, 1.0, 1.0), Color(0.6, 0.85, 1.0, 0.9), Color(0.3, 0.55, 1.0, 0.0)]
const ARCANE_RAMP := [Color(0.9, 0.7, 1.0, 1.0), Color(0.65, 0.38, 1.0, 0.9), Color(0.35, 0.1, 0.85, 0.0)]

var _once_at := {} # key -> msec: an AoE that hits 5 mobs sends 5 events but should draw once
var _charge_trails := {} # source path -> Node3D
var _cast_glows := {}    # source path -> Node3D
static var _arc: ArrayMesh
static var _slash_mat: ShaderMaterial


# ---------------------------------------------------------------- building blocks

func _burst(pos: Vector3, spec: Dictionary) -> void:
	FxKit.burst(self, pos, spec)


## Sparks: hot streaks thrown outwards and falling.
func sparks(pos: Vector3, color: Color, count := 12, speed := 6.0, life := 0.45, size := 0.1) -> void:
	_burst(pos, {"amount": count, "life": life, "size": size, "speed": [speed * 0.4, speed], "streak": 3.0, "tex": "spark",
		"gravity": Vector3(0, -9.0, 0), "damping": [1.0, 2.5], "life_rand": 0.5, "scale": "shrink",
		"look": {"hot": 0.8, "dark": 0.2, "soft": 0.3},
		"colors": [Color(1, 1, 0.9, 1.0), Color(color, 0.95), Color(color.darkened(0.3), 0.0)]})


## Star-shaped glints (the flash of a hit, sparkles of magic).
func glints(pos: Vector3, color: Color, count := 1, size := 1.0, life := 0.22, spread := 0.0, speed := 0.0) -> void:
	var spec := {"amount": count, "life": life, "size": size, "speed": [speed * 0.3, speed], "scale": "pop", "tex": "glint",
		"spin": 90.0, "life_rand": 0.3 if count > 1 else 0.0, "look": {"hot": 0.6, "dark": 0.1, "soft": 0.35},
		"colors": [Color(color.lerp(Color.WHITE, 0.5), 1.0), Color(color, 0.9), Color(color, 0.0)]}
	if spread > 0.0:
		spec.radius = spread
	_burst(pos, spec)


## Smoke or dust: billowing alpha puffs that swell and drift, tearing apart as they fade.
func smoke(pos: Vector3, color: Color, count := 8, size := 1.0, life := 1.2, speed := 1.5, rise := 0.6, flat := false, spread := 0.3) -> void:
	var spec := {"amount": count, "life": life, "size": size, "speed": [speed * 0.3, speed], "additive": false, "tex": "smoke",
		"scale": "swell", "damping": [1.5, 3.0], "gravity": Vector3(0, rise, 0), "radius": spread, "spin": 25.0,
		"life_rand": 0.35, "look": {"dark": 0.35, "soft": 0.35},
		"colors": [Color(color, 0.0), Color(color, 0.6), Color(color.lightened(0.12), 0.35), Color(color.lightened(0.18), 0.0)]}
	if flat:
		spec.spread = 90.0
		spec.flat = true
		spec.dir = Vector3.UP
	FxKit.burst(self, pos, spec)


## Frosty mist: smoke puffs drawn additively in a dim cold blue, so they glow faintly instead of
## reading as white cotton.
func cold_mist(pos: Vector3, count := 10, size := 1.2, life := 1.0, speed := 2.0, flat := false) -> void:
	var spec := {"amount": count, "life": life, "size": size, "speed": [speed * 0.3, speed], "tex": "smoke", "scale": "swell",
		"damping": [2.0, 3.5], "gravity": Vector3(0, 0.3, 0), "radius": 0.4, "spin": 25.0, "life_rand": 0.35, "additive": false,
		"look": {"dark": 0.15, "soft": 0.55},
		"colors": [Color(0.7, 0.85, 1.0, 0.0), Color(0.68, 0.84, 1.0, 0.45), Color(0.6, 0.78, 1.0, 0.25), Color(0.55, 0.75, 1.0, 0.0)]}
	if flat:
		spec.spread = 90.0
		spec.flat = true
		spec.dir = Vector3.UP
	FxKit.burst(self, pos, spec)


## A burst of flame: fire balls flung out and rising, embers, then smoke.
func fire_burst(pos: Vector3, size := 1.0, count := 16, speed := 3.0) -> void:
	_burst(pos, {"amount": count, "life": 0.6, "size": 0.9 * size, "speed": [speed * 0.3, speed], "tex": "fire", "additive": false, "radius": 0.25 * size,
		"damping": [3.0, 6.0], "gravity": Vector3(0, 2.5, 0), "scale": "swell", "life_rand": 0.4, "spin": 8.0,
		"look": {"hot": 0.5, "dark": 0.45, "soft": 0.2, "distort": 0.08, "intensity": 1.0}, "colors": FIRE_RAMP})
	sparks(pos, Color(1.0, 0.55, 0.15), int(count * 1.3), speed * 2.8, 0.7, 0.11 * size)
	get_tree().create_timer(0.12).timeout.connect(func() -> void:
		smoke(pos + Vector3(0, 0.3, 0), Color(0.2, 0.17, 0.15), int(count * 0.6), 1.3 * size, 1.6, speed * 0.4, 0.9))


## A ring expanding over the ground from `from` to `to` metres across in `time` seconds,
## tearing apart as it goes; with `height` > 0 a wall of light rising instead of a flat ring.
func ring_wave(pos: Vector3, color: Color, from: float, to: float, time := 0.35, height := 0.0, inner := 0.85, intensity := 1.2) -> void:
	var mi := FxKit.ribbon(FxKit.ring_mesh(inner, height), color, color.darkened(0.5),
		{"repeat": 3.0, "scroll": 0.0, "along_fade": 0.0, "head_hot": 0.0, "core_hot": 0.35 if height <= 0.0 else 0.1,
		"soft": 0.25, "intensity": intensity})
	add_child(mi)
	mi.global_position = pos + Vector3(0, 0.08, 0)
	mi.rotation.y = randf() * TAU
	mi.scale = Vector3(from * 0.5, 1.0, from * 0.5)
	var tw := create_tween()
	tw.tween_property(mi, "scale", Vector3(to * 0.5, 1.0 if height <= 0.0 else 0.5, to * 0.5), time).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	tw.parallel().tween_method(func(v: float) -> void: mi.set_instance_shader_parameter("progress", v), 0.0, 1.0, time).set_ease(Tween.EASE_IN)
	tw.tween_callback(mi.queue_free)


## A decal on the ground that grows from `from` to `to` metres over `grow` seconds, holds, and
## fades out over `fade` seconds.
func ground(kind: String, pos: Vector3, color: Color, from: float, to: float, grow := 0.3, fade := 0.6, hold := 0.0, glow := 0.0, spin := 0.0) -> Decal:
	var d := FxKit.decal(kind, from, color, glow)
	add_child(d)
	d.global_position = pos + Vector3(0, 0.5, 0)
	d.rotation.y = randf() * TAU
	var tw := create_tween()
	tw.tween_property(d, "size", Vector3(to, 3.0, to), grow).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	if spin != 0.0:
		tw.parallel().tween_property(d, "rotation:y", d.rotation.y + spin, grow + hold + fade)
	tw.tween_interval(hold)
	tw.tween_property(d, "modulate:a", 0.0, fade)
	tw.tween_callback(d.queue_free)
	return d


## Short light flash.
func flash(pos: Vector3, color: Color, energy := 6.0, range_m := 10.0, duration := 0.25) -> void:
	var l := OmniLight3D.new()
	l.light_color = color
	l.light_energy = energy
	l.omni_range = range_m
	l.light_specular = 0.2
	add_child(l)
	l.global_position = pos + Vector3(0, 1.5, 0)
	var tw := create_tween()
	tw.tween_property(l, "light_energy", 0.0, duration).set_ease(Tween.EASE_IN)
	tw.tween_callback(l.queue_free)


func shake(pos: Vector3, amount: float) -> void:
	get_tree().call_group("camera_rig", "shake", amount, pos)


## A curved band 140 degrees wide (UV.x along the swing, UV.y from inner to outer edge).
static func arc_mesh() -> ArrayMesh:
	if _arc:
		return _arc
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var n := 20
	var a0 := deg_to_rad(80.0)
	var a1 := deg_to_rad(-80.0)
	for i in n:
		var t0 := float(i) / n
		var t1 := float(i + 1) / n
		var q := []
		for t in [t0, t1]:
			var a := lerpf(a0, a1, t)
			var dir := Vector3(-sin(a), 0, -cos(a))
			q.append([dir * 0.45, Vector2(t, 0.0)])
			q.append([dir * 1.6 + Vector3(0, 0.15 * sin(t * PI), 0), Vector2(t, 1.0)])
		for idx in [0, 1, 2, 2, 1, 3]:
			st.set_uv(q[idx][1])
			st.add_vertex(q[idx][0])
	_arc = st.commit()
	return _arc


static func slash_material() -> ShaderMaterial:
	if _slash_mat == null:
		_slash_mat = ShaderMaterial.new()
		_slash_mat.shader = load("res://assets/fx/slash.gdshader")
		_slash_mat.set_shader_parameter("streaks", load("res://assets/fx/tex/streak.png"))
	return _slash_mat


## A weapon swing: a bright arc sweeping across in front of the unit, tearing as it fades.
func slash(unit: Node3D, color := HIT_COLOR, scale_by := 1.0, tilt := 0.35, time := 0.22) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = arc_mesh()
	mi.material_override = slash_material()
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.set_instance_shader_parameter("tint", color)
	mi.set_instance_shader_parameter("seed", randf())
	add_child(mi)
	mi.global_position = unit.global_position + Vector3(0, 1.15 * scale_by, 0)
	mi.rotation = Vector3(0, unit.rotation.y, tilt)
	mi.scale = Vector3.ONE * scale_by
	var tw := create_tween()
	tw.tween_method(func(v: float) -> void: mi.set_instance_shader_parameter("progress", v), 0.0, 1.6, time)
	tw.tween_callback(mi.queue_free)


## A jagged bolt of lightning between two points: a bright core inside a wider glow ribbon,
## flickering out.
func lightning(from: Vector3, to: Vector3, color: Color, width := 0.06) -> void:
	var cam := get_viewport().get_camera_3d()
	var view := (cam.global_position if cam else from + Vector3(0, 0, 10))
	var pts: Array[Vector3] = [from]
	var segs := 9
	for i in range(1, segs):
		var p := from.lerp(to, float(i) / segs)
		var jag := 0.45 * sin(PI * float(i) / segs)
		pts.append(p + Vector3(randf_range(-jag, jag), randf_range(-0.3, 0.3) * jag, randf_range(-jag, jag)))
	pts.append(to)
	for layer in [[width * 5.0, Color(color, 0.35)], [width, Color(color.lerp(Color.WHITE, 0.6), 1.0)]]:
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
		for i in pts.size():
			var along := (pts[mini(i + 1, pts.size() - 1)] - pts[maxi(i - 1, 0)]).normalized()
			var side := along.cross((view - pts[i]).normalized()).normalized() * float(layer[0])
			var u := float(i) / (pts.size() - 1)
			st.set_uv(Vector2(u, 0.0))
			st.add_vertex(pts[i] - side)
			st.set_uv(Vector2(u, 1.0))
			st.add_vertex(pts[i] + side)
		var mi := MeshInstance3D.new()
		mi.mesh = st.commit()
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
		m.albedo_texture = load("res://assets/fx/tex/trail.png")
		m.albedo_color = layer[1] * 1.4
		m.uv1_scale = Vector3(2, 1, 1)
		m.uv1_offset = Vector3(randf(), 0, 0)
		mi.material_override = m
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)
		var tw := create_tween()
		tw.tween_property(m, "albedo_color", Color(0, 0, 0, 0), 0.22).set_delay(randf_range(0.04, 0.12))
		tw.tween_callback(mi.queue_free)


## An ice spike out of the ground that stands a moment and melts.
func ice_spike(pos: Vector3, height: float, delay: float) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = FxKit.ice_cone(height, height * 0.17)
	mi.material_override = FxKit.shader_material("res://assets/fx/ice.gdshader")
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	mi.global_position = pos + Vector3(0, height * 0.35, 0)
	mi.rotation = Vector3(randf_range(-0.45, 0.45), randf() * TAU, randf_range(-0.45, 0.45))
	mi.scale = Vector3(1, 0.01, 1)
	var tw := create_tween()
	tw.tween_interval(delay)
	tw.tween_property(mi, "scale", Vector3.ONE, 0.1).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)
	tw.tween_callback(func() -> void: glints(mi.global_position + Vector3(0, height * 0.4, 0), FROST_COLOR, 1, 0.5, 0.25))
	tw.tween_interval(1.4)
	tw.tween_method(func(v: float) -> void: mi.set_instance_shader_parameter("melt", v), 0.0, 1.0, 0.7)
	tw.parallel().tween_property(mi, "scale:y", 0.3, 0.7)
	tw.tween_callback(mi.queue_free)


# ---------------------------------------------------------------- warrior

func melee_hit(target: Node3D, attacker_is_player: bool) -> void:
	if target == null:
		return
	var at := target.global_position + Vector3(0, 1.0, 0)
	if attacker_is_player:
		glints(at, HIT_COLOR, 1, 1.1, 0.16)
		sparks(at, HIT_COLOR, 10, 6.0, 0.35)
	else:
		glints(at, Color(1.0, 0.35, 0.25), 1, 0.8, 0.14)
		sparks(at, Color(1.0, 0.35, 0.25), 6, 4.0, 0.3, 0.08)


func heroic_strike(source: Node3D, target: Node3D) -> void:
	slash(source, HS_COLOR, 1.3, -0.25, 0.26)
	slash(source, Color(1.0, 0.75, 0.45, 0.7), 1.1, -0.3, 0.22)
	if target:
		var at := target.global_position + Vector3(0, 1.0, 0)
		glints(at, Color(1.0, 0.65, 0.3), 1, 2.4, 0.25)
		sparks(at, HS_COLOR, 24, 10.0, 0.55, 0.13)
		_burst(at, {"amount": 8, "life": 0.45, "size": 0.9, "speed": [1.0, 2.5], "tex": "fire", "additive": false, "radius": 0.2,
			"damping": [4.0, 6.0], "scale": "swell", "look": {"hot": 0.6, "intensity": 1.2}, "colors": FIRE_RAMP})
		ring_wave(target.global_position + Vector3(0, 0.9, 0), HS_COLOR, 0.5, 2.6, 0.22, 0.0, 0.8, 1.2)
		flash(target.global_position, HS_COLOR, 4.0, 6.0, 0.2)
		shake(at, 0.35)


func thunder_clap(unit: Node3D) -> void:
	var pos := unit.global_position
	var r: float = GameData.ABILITIES.thunder_clap.radius
	glints(pos + Vector3(0, 1.0, 0), Color(0.75, 0.88, 1.0), 1, 4.0, 0.22)
	ring_wave(pos, TC_COLOR, 1.0, r * 2.2, 0.35, 0.0, 0.9, 1.1)
	ring_wave(pos, Color(0.6, 0.8, 1.0), 1.0, r * 1.6, 0.45, 0.8, 0.0, 0.7)
	ground("scorch", pos, Color(0.3, 0.32, 0.4, 0.8), r * 0.8, r * 1.2, 0.2, 1.2, 0.6)
	smoke(pos + Vector3(0, 0.25, 0), DUST, 22, 1.6, 1.2, 10.0, 0.3, true, 1.0)
	flash(pos, TC_COLOR, 10.0, 14.0, 0.35)
	shake(pos, 0.6)
	for i in range(7):
		var a := randf() * TAU
		var d := randf_range(2.0, r)
		var end := pos + Vector3(cos(a) * d, 0.1, sin(a) * d)
		lightning(pos + Vector3(0, 1.6, 0), end, TC_COLOR)
		sparks(end + Vector3(0, 0.2, 0), TC_COLOR, 5, 4.0, 0.3, 0.08)
		glints(end + Vector3(0, 0.2, 0), TC_COLOR, 1, 0.9, 0.18)


func charge_start(source: Node3D) -> void:
	charge_end(source) # just in case
	var trail := Node3D.new()
	source.add_child(trail)
	var kick := FxKit.emitter({"amount": 30, "life": 0.9, "size": 1.0, "speed": [0.5, 1.5], "additive": false, "tex": "smoke",
		"scale": "swell", "spread": 60.0, "gravity": Vector3(0, 0.5, 0), "radius": 0.3, "spin": 30.0, "life_rand": 0.3,
		"look": {"dark": 0.3, "soft": 0.25},
		"colors": [Color(DUST, 0.0), Color(DUST, 0.75), Color(DUST.lightened(0.2), 0.0)]})
	kick.position = Vector3(0, 0.2, 0.3)
	trail.add_child(kick)
	var wind := FxKit.emitter({"amount": 26, "life": 0.3, "size": 0.5, "speed": [0.5, 1.0], "tex": "wisp",
		"dir": Vector3(0, 0, 1), "spread": 5.0, "box": Vector3(0.6, 0.8, 0.2), "look": {"hot": 0.3, "soft": 0.3},
		"colors": [Color(1, 0.95, 0.8, 0.0), Color(1, 0.95, 0.8, 0.6), Color(1, 0.9, 0.7, 0.0)]})
	wind.position = Vector3(0, 1.0, 0)
	trail.add_child(wind)
	kick.emitting = true
	wind.emitting = true
	# The ribbons live under Vfx (world space), so the trail node keeps a list to stop them by.
	var ribs: Array[FxTrail] = []
	for h in [0.6, 1.4]:
		var rib: FxTrail = FxTrail.make(source, Color(1.0, 0.92, 0.7, 0.7), Color(0.8, 0.6, 0.3), 0.35, 0.25,
			{"repeat": 2.0, "scroll": 3.0, "head_hot": 0.3, "intensity": 1.0})
		rib.offset = Vector3(0, h, 0)
		add_child(rib)
		ribs.append(rib)
	trail.set_meta("ribs", ribs)
	_charge_trails[source.get_path()] = trail
	get_tree().create_timer(3.0).timeout.connect(func() -> void:
		if is_instance_valid(source) and _charge_trails.get(source.get_path()) == trail:
			charge_end(source))


func charge_end(source: Node3D) -> void:
	var key := source.get_path()
	if _charge_trails.has(key):
		var trail = _charge_trails[key]
		_charge_trails.erase(key)
		if is_instance_valid(trail):
			for p in trail.get_children():
				p.emitting = false
			for rib in trail.get_meta("ribs", []):
				if is_instance_valid(rib):
					rib.stop()
			get_tree().create_timer(1.0).timeout.connect(trail.queue_free)


func charge_impact(source: Node3D, target: Node3D) -> void:
	charge_end(source)
	var pos := target.global_position if target else source.global_position
	ring_wave(pos, CHARGE_COLOR, 0.5, 4.5, 0.25, 0.0, 0.7, 1.6)
	ground("shock", pos, CHARGE_COLOR, 0.5, 4.5, 0.25, 0.3, 0.0, 1.2)
	smoke(pos + Vector3(0, 0.3, 0), DUST, 14, 1.3, 1.0, 6.0, 0.3, true, 0.6)
	sparks(pos + Vector3(0, 1.0, 0), CHARGE_COLOR, 18, 8.0, 0.45)
	glints(pos + Vector3(0, 1.0, 0), CHARGE_COLOR, 1, 2.2, 0.22)
	flash(pos, CHARGE_COLOR, 5.0, 8.0, 0.2)
	shake(pos, 0.45)


func level_up(unit: Node3D) -> void:
	var pos := unit.global_position
	ground("rune", pos, LEVEL_COLOR, 1.0, 5.0, 0.4, 1.0, 0.8, 4.0, 1.5)
	ring_wave(pos, LEVEL_COLOR, 0.5, 6.0, 0.5, 0.0, 0.8, 1.8)
	flash(pos, LEVEL_COLOR, 8.0, 12.0, 1.2)
	# two golden ribbons spiralling up round the hero, unwinding as they rise and fade
	for k in 2:
		var mi := FxKit.ribbon(FxKit.helix_mesh(1.4, 4.5, 1.1), LEVEL_COLOR, Color(1.0, 0.45, 0.05),
			{"repeat": 2.0, "scroll": -1.5, "head_hot": 0.0, "core_hot": 0.3, "along_fade": 0.6, "intensity": 1.3})
		add_child(mi)
		mi.global_position = pos
		mi.rotation.y = k * PI
		mi.scale = Vector3(1.1, 0.2, 1.1)
		var tw := create_tween()
		tw.tween_property(mi, "scale", Vector3(1.1, 1.0, 1.1), 0.5).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
		tw.parallel().tween_property(mi, "rotation:y", mi.rotation.y + TAU * 0.75, 1.8)
		tw.parallel().tween_method(func(v: float) -> void: mi.set_instance_shader_parameter("progress", v), 0.0, 1.0, 1.8).set_ease(Tween.EASE_IN)
		tw.tween_callback(mi.queue_free)
	_burst(pos + Vector3(0, 0.3, 0), {"amount": 36, "life": 1.6, "size": 0.35, "speed": [0.3, 1.0], "tex": "glint",
		"gravity": Vector3(0, 2.5, 0), "box": Vector3(1.0, 0.2, 1.0), "explode": 0.5, "scale": "pop", "spin": 120.0, "life_rand": 0.4,
		"look": {"hot": 0.8, "soft": 0.35}, "colors": [Color(1, 1, 0.85, 1.0), Color(LEVEL_COLOR, 0.9), Color(LEVEL_COLOR, 0.0)]})
	var cyl := CylinderMesh.new()
	cyl.top_radius = 1.0
	cyl.bottom_radius = 1.1
	cyl.height = 7.0
	cyl.radial_segments = 20
	cyl.cap_top = false
	cyl.cap_bottom = false
	var mi := MeshInstance3D.new()
	mi.mesh = cyl
	mi.material_override = FxKit.shader_material("res://assets/fx/pillar.gdshader")
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	mi.global_position = pos + Vector3(0, 3.5, 0)
	var tw2 := create_tween()
	tw2.tween_method(func(v: float) -> void: mi.set_instance_shader_parameter("fade", v), 0.0, 0.6, 0.15)
	tw2.tween_interval(0.7)
	tw2.tween_method(func(v: float) -> void: mi.set_instance_shader_parameter("fade", v), 0.6, 0.0, 0.9)
	tw2.parallel().tween_property(mi, "scale", Vector3(1.5, 1.0, 1.5), 0.9)
	tw2.tween_callback(mi.queue_free)


# ---------------------------------------------------------------- mage

## While casting: the spell's element gathering in the hands (flames licking up, frost mist
## swirling, arcane wisps), motes drawn in from around the caster and a rune at their feet.
func cast_start(source: Node3D, ability := "") -> void:
	cast_stop(source)
	var color: Color = SCHOOL_COLORS.get(ability, ARCANE_COLOR)
	var root := Node3D.new()
	source.add_child(root)
	var hands := Node3D.new()
	hands.position = HAND_OFFSET + Vector3(0, -0.05, -0.45)
	root.add_child(hands)
	var g := FxKit.glow(color, 0.55)
	hands.add_child(g)
	hands.add_child(FxKit.glow(Color(1, 1, 1, 0.8), 0.18))
	var tw := g.create_tween().set_loops()
	tw.tween_property(g, "scale", Vector3.ONE * 0.75, 0.45).set_trans(Tween.TRANS_SINE)
	tw.tween_property(g, "scale", Vector3.ONE * 0.5, 0.45).set_trans(Tween.TRANS_SINE)
	var body: GPUParticles3D
	match ability:
		"fireball":
			body = FxKit.emitter({"amount": 24, "life": 0.5, "size": 0.45, "speed": [0.2, 0.5], "tex": "fire", "additive": false, "radius": 0.08,
				"gravity": Vector3(0, 1.5, 0), "scale": "swell", "spin": 40.0, "life_rand": 0.3,
				"look": {"hot": 0.7, "distort": 0.1, "intensity": 1.2}, "colors": FIRE_RAMP})
		"frostbolt":
			body = FxKit.emitter({"amount": 18, "life": 0.7, "size": 0.45, "speed": [0.0, 0.1], "tex": "wisp", "radius": 0.15,
				"local": true, "orbit": 1.2, "scale": "swell", "look": {"hot": 0.5, "soft": 0.3}, "colors": FROST_RAMP})
		_:
			body = FxKit.emitter({"amount": 18, "life": 0.6, "size": 0.4, "speed": [0.0, 0.1], "tex": "wisp", "radius": 0.15,
				"local": true, "orbit": 1.4, "scale": "swell", "look": {"hot": 0.5, "soft": 0.3}, "colors": ARCANE_RAMP})
	hands.add_child(body)
	body.emitting = true
	# motes drawn in from a ring round the caster up into the hands
	var motes := FxKit.emitter({"amount": 26, "life": 0.9, "size": 0.18, "speed": [0.0, 0.0], "tex": "glint", "radius": 1.2,
		"flat": true, "local": true, "radial": -2.5, "gravity": Vector3(0, 1.4, 0), "scale": "pop", "spin": 90.0,
		"look": {"hot": 0.8, "soft": 0.35}, "colors": [Color(color, 0.0), Color(color.lerp(Color.WHITE, 0.5), 1.0), Color(color, 0.0)]})
	motes.position = Vector3(0, 0.2, 0)
	root.add_child(motes)
	motes.emitting = true
	var rune := FxKit.decal("rune", 2.6, Color(color, 0.0), 2.0)
	root.add_child(rune)
	rune.position = Vector3(0, 0.5, 0)
	var rt := rune.create_tween()
	rt.tween_property(rune, "modulate:a", 0.75, 0.4)
	rt.parallel().tween_property(rune, "rotation:y", TAU, 6.0)
	_cast_glows[source.get_path()] = root
	get_tree().create_timer(3.5).timeout.connect(func() -> void:
		if is_instance_valid(source) and _cast_glows.get(source.get_path()) == root:
			cast_stop(source))


func cast_stop(source: Node3D) -> void:
	var key := source.get_path()
	if _cast_glows.has(key):
		var root = _cast_glows[key]
		_cast_glows.erase(key)
		if is_instance_valid(root):
			root.queue_free()


## A projectile from the caster's hands to the target; speed matches the server's.
func projectile(source: Node3D, target: Node3D, color: Color, speed: float, kind: String) -> void:
	cast_stop(source)
	if target == null:
		return
	var from := source.global_position + HAND_OFFSET
	var to := target.global_position + Vector3(0, 1.0, 0)
	var travel := maxf(0.05, from.distance_to(to) / speed)
	var bolt := Node3D.new()
	add_child(bolt)
	bolt.global_position = from
	var trails: Array[GPUParticles3D] = []
	var ribbons: Array[FxTrail] = []
	match kind:
		"fireball":
			# a churning ball of flame (fire spawned at the bolt, left behind as it flies),
			# a white-hot heart, a ribbon of flame, dark smoke and falling embers
			bolt.add_child(FxKit.glow(Color(1.0, 0.5, 0.12, 0.7), 1.6))
			bolt.add_child(FxKit.glow(Color(1.0, 0.9, 0.6), 0.35))
			trails.append(FxKit.emitter({"amount": 48, "life": 0.3, "size": 0.95, "speed": [0.3, 0.9], "radius": 0.12, "tex": "fire", "additive": false,
				"local": true, "scale": "swell", "spin": 90.0, "life_rand": 0.3, "dir": Vector3(0, 0, 1), "spread": 50.0,
				"look": {"hot": 0.5, "dark": 0.6, "distort": 0.1}, "colors": FIRE_RAMP}))
			trails.append(FxKit.emitter({"amount": 50, "life": 0.35, "size": 0.55, "speed": [0.2, 0.6], "radius": 0.15, "tex": "fire", "additive": false,
				"scale": "shrink", "spin": 60.0, "life_rand": 0.4, "gravity": Vector3(0, 1.5, 0),
				"look": {"hot": 0.35, "dark": 0.7, "distort": 0.1}, "colors": FIRE_RAMP}))
			trails.append(FxKit.emitter({"amount": 26, "life": 1.0, "size": 0.7, "speed": [0.1, 0.4], "additive": false, "tex": "smoke",
				"scale": "swell", "gravity": Vector3(0, 0.9, 0), "spin": 30.0, "life_rand": 0.3, "look": {"dark": 0.3, "soft": 0.25},
				"colors": SMOKE_RAMP}))
			trails.append(FxKit.emitter({"amount": 18, "life": 0.6, "size": 0.09, "speed": [1.0, 2.5], "streak": 3.0, "tex": "spark",
				"gravity": Vector3(0, -5.0, 0), "life_rand": 0.4, "look": {"hot": 0.8, "dark": 0.2},
				"colors": [Color(1, 0.95, 0.6, 1.0), Color(1, 0.5, 0.1, 0.9), Color(0.8, 0.2, 0.0, 0.0)]}))
			ribbons.append(FxTrail.make(bolt, Color(1.0, 0.55, 0.12), Color(0.6, 0.1, 0.02), 0.7, 0.25,
				{"repeat": 1.5, "scroll": 2.5, "head_hot": 0.4, "intensity": 1.2}))
		"wand":
			bolt.add_child(FxKit.glow(ARCANE_COLOR, 0.5))
			bolt.add_child(FxKit.glow(Color(1, 0.95, 1), 0.18))
			trails.append(FxKit.emitter({"amount": 24, "life": 0.3, "size": 0.3, "speed": [0.1, 0.3], "tex": "wisp", "spin": 120.0,
				"scale": "swell", "look": {"hot": 0.6, "soft": 0.3}, "colors": ARCANE_RAMP}))
			ribbons.append(FxTrail.make(bolt, ARCANE_COLOR, Color(0.35, 0.1, 0.8), 0.25, 0.18,
				{"repeat": 1.0, "scroll": 3.0, "head_hot": 0.7, "intensity": 1.5}))
		_: # frostbolt: a spinning ice shard in a cold glow, trailing a frost ribbon, mist and glitter
			var shard := MeshInstance3D.new()
			shard.mesh = FxKit.ice_cone(0.85, 0.15)
			shard.material_override = FxKit.shader_material("res://assets/fx/ice.gdshader")
			shard.set_instance_shader_parameter("glow", 1.6)
			shard.rotation.x = -PI / 2 # tip forward (-Z)
			shard.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			var spin := Node3D.new()
			spin.add_child(shard)
			bolt.add_child(spin)
			var st := spin.create_tween().set_loops()
			st.tween_property(spin, "rotation:z", TAU, 0.5).from(0.0)
			bolt.add_child(FxKit.glow(Color(FROST_COLOR, 0.6), 1.2))
			bolt.add_child(FxKit.glow(Color(0.85, 0.95, 1.0), 0.28))
			trails.append(FxKit.emitter({"amount": 34, "life": 0.6, "size": 0.7, "speed": [0.1, 0.4], "tex": "smoke", "additive": false,
				"scale": "swell", "radius": 0.1, "spin": 40.0, "life_rand": 0.3, "look": {"dark": 0.15, "soft": 0.55},
				"colors": [Color(0.7, 0.85, 1.0, 0.0), Color(0.68, 0.84, 1.0, 0.45), Color(0.6, 0.78, 1.0, 0.0)]}))
			trails.append(FxKit.emitter({"amount": 30, "life": 0.5, "size": 0.22, "speed": [0.3, 1.0], "scale": "pop", "tex": "glint",
				"spin": 180.0, "life_rand": 0.4, "radius": 0.15, "look": {"hot": 0.6, "soft": 0.35}, "colors": FROST_RAMP}))
			ribbons.append(FxTrail.make(bolt, Color(0.55, 0.82, 1.0), Color(0.15, 0.35, 0.9), 0.45, 0.25,
				{"repeat": 1.5, "scroll": 2.0, "head_hot": 0.5, "intensity": 1.1}))
			trails.append(FxKit.emitter({"amount": 16, "life": 0.4, "size": 0.45, "speed": [0.0, 0.1], "tex": "wisp", "radius": 0.2,
				"local": true, "orbit": 2.0, "scale": "swell", "look": {"hot": 0.4, "soft": 0.3}, "colors": FROST_RAMP}))
	for t in trails:
		bolt.add_child(t)
		t.emitting = true
	for r in ribbons:
		add_child(r)
	var light := OmniLight3D.new()
	light.light_color = color
	light.light_energy = 2.5 if kind == "fireball" else 1.5
	light.omni_range = 6.0
	light.light_specular = 0.2
	bolt.add_child(light)
	bolt.look_at(to, Vector3.UP)
	var tw := create_tween()
	tw.tween_property(bolt, "global_position", to, travel)
	tw.tween_callback(func() -> void:
		var pos := target.global_position + Vector3(0, 1.0, 0) if is_instance_valid(target) else to
		var feet := pos - Vector3(0, 1.0, 0)
		match kind:
			"fireball":
				glints(pos, Color(1.0, 0.7, 0.3), 1, 2.2, 0.2)
				fire_burst(pos, 1.3, 18, 4.0)
				ring_wave(pos, FIRE_COLOR, 0.5, 3.4, 0.3, 0.0, 0.7, 1.5)
				ground("scorch", feet, Color(1, 1, 1, 0.9), 1.5, 2.6, 0.12, 2.5, 3.0)
				flash(feet, FIRE_COLOR, 8.0, 10.0, 0.35)
				shake(pos, 0.3)
			"wand":
				glints(pos, ARCANE_COLOR, 1, 1.0, 0.16)
				sparks(pos, ARCANE_COLOR, 8, 4.0, 0.3, 0.08)
				_burst(pos, {"amount": 6, "life": 0.35, "size": 0.5, "speed": [0.5, 1.5], "tex": "wisp", "spin": 200.0,
					"scale": "swell", "look": {"hot": 0.6, "soft": 0.3}, "colors": ARCANE_RAMP})
			_:
				glints(pos, FROST_COLOR, 1, 1.8, 0.2)
				_burst(pos, {"amount": 10, "life": 0.6, "size": 0.45, "speed": [3.0, 6.0], "tex": "shards", "spin": 300.0,
					"gravity": Vector3(0, -9.0, 0), "damping": [1.0, 2.0], "additive": false, "life_rand": 0.3,
					"look": {"dark": 0.0, "soft": 0.2, "intensity": 1.3},
					"colors": [Color(0.9, 0.97, 1.0, 1.0), Color(0.7, 0.88, 1.0, 0.95), Color(0.6, 0.8, 1.0, 0.0)]})
				cold_mist(pos, 10, 1.1, 0.9, 2.0)
				_burst(pos, {"amount": 16, "life": 0.7, "size": 0.25, "speed": [1.0, 3.0], "scale": "pop", "tex": "glint",
					"spin": 180.0, "life_rand": 0.4, "radius": 0.3, "look": {"hot": 0.6, "soft": 0.35}, "colors": FROST_RAMP})
				ring_wave(pos, FROST_COLOR, 0.4, 2.6, 0.28, 0.0, 0.75, 1.4)
				ground("frost", feet, Color(0.7, 0.88, 1.0), 1.0, 2.4, 0.15, 1.0, 0.8, 0.8)
				flash(feet, FROST_COLOR, 4.0, 7.0, 0.25)
		for t in trails:
			t.emitting = false
		for r in ribbons:
			r.stop()
		for c in bolt.get_children():
			if c is MeshInstance3D or c is OmniLight3D or (c is Node3D and not c is GPUParticles3D):
				c.queue_free()
		get_tree().create_timer(1.2).timeout.connect(bolt.queue_free))


func frost_nova(unit: Node3D) -> void:
	var pos := unit.global_position
	var r: float = GameData.ABILITIES.frost_nova.radius
	glints(pos + Vector3(0, 0.9, 0), Color(0.8, 0.93, 1.0), 1, 3.5, 0.25)
	ring_wave(pos, FROST_COLOR, 1.0, r * 2.2, 0.3, 0.0, 0.9, 1.1)
	ring_wave(pos, Color(0.7, 0.88, 1.0), 1.0, r * 1.6, 0.4, 0.6, 0.0, 0.6)
	ground("frost", pos, Color(0.72, 0.9, 1.0, 0.24), 1.0, r * 2.0, 0.22, 1.2, 1.2, 0.12)
	cold_mist(pos + Vector3(0, 0.3, 0), 22, 1.8, 1.1, 9.0, true)
	flash(pos, FROST_COLOR, 8.0, 12.0, 0.4)
	shake(pos, 0.3)
	for i in range(16):
		var a := randf() * TAU
		var d := randf_range(1.0, r)
		ice_spike(pos + Vector3(cos(a) * d, 0.0, sin(a) * d), randf_range(0.6, 1.6), d / r * 0.15)
	_burst(pos + Vector3(0, 0.5, 0), {"amount": 30, "life": 0.9, "size": 0.25, "speed": [2.0, 7.0], "tex": "glint", "spin": 200.0,
		"gravity": Vector3(0, -2.0, 0), "spread": 80.0, "scale": "pop", "life_rand": 0.4, "look": {"hot": 0.6, "soft": 0.35},
		"colors": FROST_RAMP})


func blink_out(unit: Node3D) -> void:
	var pos := unit.global_position + Vector3(0, 1.0, 0)
	_burst(pos, {"amount": 1, "life": 0.45, "size": 3.0, "speed": [0.0, 0.0], "tex": "swirl", "spin": 0.0, "scale": "shrink",
		"look": {"hot": 0.2, "soft": 0.3, "intensity": 0.6}, "colors": ARCANE_RAMP})
	_burst(pos, {"amount": 16, "life": 0.4, "size": 0.6, "speed": [0.0, 0.0], "tex": "wisp", "radius": 1.3, "radial": -14.0,
		"spin": 300.0, "scale": "shrink", "look": {"hot": 0.5, "soft": 0.3}, "colors": ARCANE_RAMP})
	glints(pos, ARCANE_COLOR, 1, 2.4, 0.25)
	glints(pos, ARCANE_COLOR, 14, 0.35, 0.5, 0.5, 3.0)
	ground("rune", unit.global_position, ARCANE_COLOR, 2.5, 3.0, 0.1, 0.6, 0.0, 3.0, 1.0)
	flash(pos - Vector3(0, 1.5, 0), ARCANE_COLOR, 4.0, 7.0, 0.2)


func blink_in(unit: Node3D) -> void:
	var pos := unit.global_position + Vector3(0, 1.0, 0)
	ring_wave(unit.global_position, ARCANE_COLOR, 0.6, 3.6, 0.35, 1.6, 0.0, 1.2)
	ring_wave(unit.global_position, ARCANE_COLOR, 0.5, 3.0, 0.3, 0.0, 0.7, 1.5)
	glints(pos, ARCANE_COLOR, 1, 2.0, 0.3)
	glints(pos, ARCANE_COLOR, 18, 0.3, 0.7, 0.9, 1.0)
	_burst(pos, {"amount": 10, "life": 0.6, "size": 0.7, "speed": [0.5, 1.5], "tex": "wisp", "radius": 0.5,
		"spin": 200.0, "scale": "swell", "gravity": Vector3(0, 1.5, 0), "look": {"hot": 0.5, "soft": 0.3}, "colors": ARCANE_RAMP})
	ground("shock", unit.global_position, ARCANE_COLOR, 0.5, 3.5, 0.25, 0.3, 0.0, 2.5)
	flash(pos - Vector3(0, 1.5, 0), ARCANE_COLOR, 5.0, 8.0, 0.25)


func death(target: Node3D) -> void:
	smoke(target.global_position + Vector3(0, 0.4, 0), DUST, 10, 1.1, 1.4, 1.5, 0.4, false, 0.5)


# ---------------------------------------------------------------- dispatch

static func _skip() -> bool:
	return not GameData.visuals_enabled()


## True the first time a key is seen within 200 ms (one effect per AoE, not one per victim).
func _once(key: String) -> bool:
	var t := Time.get_ticks_msec()
	if t - int(_once_at.get(key, -1000)) <= 200:
		return false
	_once_at[key] = t
	return true


## Called by World for every combat event (already broadcast to all peers).
func on_combat_event(source: Node, target: Node, amount: int, kind: String) -> void:
	if _skip():
		return
	match kind:
		"Heroic Strike":
			if source:
				heroic_strike(source, target)
				Audio.play_at("heroic_strike", source.global_position)
		"Thunder Clap":
			if source and _once("clap" + str(source.get_path())):
				thunder_clap(source)
				Audio.play_at("thunder_clap", source.global_position, 2.0)
		"Charge":
			if source:
				charge_impact(source, target)
				Audio.play_at("charge_impact", source.global_position)
		"Frost Nova":
			if source and _once("nova" + str(source.get_path())):
				frost_nova(source)
				Audio.play_at("frost_nova", source.global_position)
		"Frostbolt", "Fireball":
			pass # the projectile's arrival already drew the impact
		"Fireball (burn)":
			if target:
				_burst(target.global_position + Vector3(0, 1.0, 0), {"amount": 6, "life": 0.6, "size": 0.5, "radius": 0.4, "tex": "fire", "additive": false,
					"speed": [0.3, 1.0], "gravity": Vector3(0, 2.5, 0), "scale": "swell", "look": {"hot": 0.6, "distort": 0.1}, "colors": FIRE_RAMP})
		"melee":
			if amount > 0:
				var by_player: bool = source != null and source.get("faction") == "player"
				melee_hit(target, by_player)
				if by_player and source is Node3D:
					slash(source, HIT_COLOR, 1.0, randf_range(-0.4, 0.4))
				if target:
					if by_player:
						Audio.play_at("swing", target.global_position, -4.0)
						Audio.play_at("hit", target.global_position)
						var kind_name: String = target.get("kind") if target.get("kind") != null else ""
						if kind_name != "" and randf() < 0.5:
							Audio.play_at(kind_name, target.global_position, -2.0, 0.12, 300)
					else:
						Audio.play_at("hit_taken", target.global_position)
						if source and source.get("kind") != null:
							Audio.play_at(str(source.get("kind")), source.global_position, -3.0, 0.12, 400)
		"dies":
			if target:
				death(target)
				if target.get("kind") != null:
					Audio.play_at(str(target.get("kind")), target.global_position, 0.0, 0.25, 0)


## VFX-only pings from the server (no damage attached). "cast_start:<ability>" names the spell.
## An effect by name, straight into Vfx with no sound and no combat: for pictures (the screenshot
## request's "fx", tools/preview/fx_preview). False if `name` isn't one.
func preview(name: String, caster: Node3D, target: Node3D) -> bool:
	match name:
		"thunder_clap": thunder_clap(caster)
		"frost_nova": frost_nova(caster)
		"level_up": level_up(caster)
		"heroic_strike": heroic_strike(caster, target)
		"melee":
			melee_hit(target, true)
			slash(caster)
		"charge": charge_impact(caster, target)
		"charge_start": charge_start(caster)
		"blink":
			blink_out(caster)
			blink_in(caster)
		"blink_out": blink_out(caster)
		"blink_in": blink_in(caster)
		"fireball": projectile(caster, target, FIRE_COLOR, GameData.ABILITIES.fireball.speed, "fireball")
		"frostbolt": projectile(caster, target, FROST_COLOR, GameData.ABILITIES.frostbolt.speed, "frostbolt")
		"wand": projectile(caster, target, ARCANE_COLOR, WAND_SPEED, "wand")
		"cast_fire": cast_start(caster, "fireball")
		"cast_frost": cast_start(caster, "frostbolt")
		"cast_arcane": cast_start(caster, "wand")
		"death": death(target)
		_: return false
	return true


func play(kind: String, source: Node, target: Node) -> void:
	if _skip() or source == null:
		return
	var arg := ""
	if kind.contains(":"):
		arg = kind.get_slice(":", 1)
		kind = kind.get_slice(":", 0)
	match kind:
		"charge_start":
			charge_start(source)
			Audio.play_at("charge", source.global_position)
		"level_up":
			level_up(source)
			Audio.play_at("level_up", source.global_position, 2.0)
		"cast_start":
			cast_start(source, arg)
		"cast_stop":
			cast_stop(source)
		"frostbolt":
			projectile(source, target, FROST_COLOR, GameData.ABILITIES.frostbolt.speed, "frostbolt")
			Audio.play_at("frostbolt", source.global_position)
		"fireball":
			projectile(source, target, FIRE_COLOR, GameData.ABILITIES.fireball.speed, "fireball")
			Audio.play_at("fireball", source.global_position)
		"wand_shot":
			projectile(source, target, ARCANE_COLOR, WAND_SPEED, "wand")
			Audio.play_at("wand", source.global_position, -6.0)
		"blink":
			blink_out(source)
			Audio.play_at("blink", source.global_position)
		"blink_arrive":
			blink_in(source)
