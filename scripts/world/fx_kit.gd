## The building blocks of the spell and combat effects (Vfx), shared so every effect draws from
## the same few materials:
##   - textured particles (emitter with a "tex": fire, smoke, wisps, glints, sparks, shards from
##     assets/fx/tex/, drawn by fx_add / fx_mix: colour ramps, erosion, shading);
##   - plain soft glowing sprites (glow cores: sprite_*.gdshader);
##   - ribbons (fx_ribbon.gdshader): trails behind moving things (FxTrail), swing arcs, rings and
##     walls of a shockwave, the level-up helix;
##   - ground decals: painted ones (assets/fx/tex/decal_*.png: shockwave, frost, scorch, rune) and
##     the target and hover rings drawn here. Decals only land on the ground: terrain and cave
##     meshes carry GROUND_LAYER and decals cull everything else, so units never wear them.
@tool # GROUND_LAYER is read by the terrain, which the map editor builds
class_name FxKit
extends RefCounted

const GROUND_LAYER := 1 << 10  # visual layer 11

static var _mats := {}
static var _tex := {}
static var _meshes := {}

## Effect textures (tools/build_fx_textures.py): file, atlas cells (cols, rows: variants, one
## random cell per particle), baked shading (smoke), upright (barely spun: flames point up).
const TEX := {
	"fire": ["fire.png", Vector2(2, 2), false, true],
	"smoke": ["smoke.png", Vector2(2, 2), true, false],
	"wisp": ["wisp.png", Vector2(2, 2), false, false],
	"glint": ["glint.png", Vector2(1, 1), false, false],
	"spark": ["spark.png", Vector2(1, 1), false, false],
	"swirl": ["swirl.png", Vector2(1, 1), false, false],
	"shards": ["shards.png", Vector2(2, 2), false, false],
}


# ---------------------------------------------------------------- materials

static func sprite_material(additive: bool, streak := 0.0, hardness := 1.6, core := 0.35) -> ShaderMaterial:
	var key := "%s_%.2f_%.2f_%.2f" % [additive, streak, hardness, core]
	if not _mats.has(key):
		var m := ShaderMaterial.new()
		m.shader = load("res://assets/fx/sprite_add.gdshader" if additive else "res://assets/fx/sprite_mix.gdshader")
		m.set_shader_parameter("streak", streak)
		m.set_shader_parameter("hardness", hardness)
		m.set_shader_parameter("core", core)
		_mats[key] = m
	return _mats[key]


## A textured particle material (see fx_particle.gdshaderinc). `opts`: hot, dark, soft, distort,
## intensity, fade (all optional; alpha-blended ones fade 0.6 by default: smoke thins as it erodes).
static func fx_material(tex_name: String, additive: bool, streak := 0.0, opts := {}) -> ShaderMaterial:
	var key := "fx_%s_%s_%.2f_%s" % [tex_name, additive, streak, str(opts)]
	if not _mats.has(key):
		var info: Array = TEX[tex_name]
		var m := ShaderMaterial.new()
		m.shader = load("res://assets/fx/fx_add.gdshader" if additive else "res://assets/fx/fx_mix.gdshader")
		m.set_shader_parameter("tex", load("res://assets/fx/tex/" + info[0]))
		m.set_shader_parameter("noise", load("res://assets/fx/tex/noise.png"))
		m.set_shader_parameter("frames", info[1])
		m.set_shader_parameter("shade", 1.0 if info[2] else 0.0)
		m.set_shader_parameter("spin_amount", 0.08 if info[3] else 1.0)
		m.set_shader_parameter("streak", streak)
		m.set_shader_parameter("hot", opts.get("hot", 0.6 if additive else 0.0))
		m.set_shader_parameter("dark", opts.get("dark", 0.5 if additive else 0.25))
		m.set_shader_parameter("softness", opts.get("soft", 0.18))
		m.set_shader_parameter("distort", opts.get("distort", 0.0))
		m.set_shader_parameter("intensity", opts.get("intensity", 1.0))
		m.set_shader_parameter("fade", opts.get("fade", 0.0 if additive else 0.6))
		_mats[key] = m
	return _mats[key]


## The ribbon material (fx_ribbon.gdshader). `opts`: repeat, scroll, soft, head_hot, core_hot,
## along_fade, intensity.
static func ribbon_material(opts := {}) -> ShaderMaterial:
	var key := "ribbon_" + str(opts)
	if not _mats.has(key):
		var m := ShaderMaterial.new()
		m.shader = load("res://assets/fx/fx_ribbon.gdshader")
		m.set_shader_parameter("tex", load("res://assets/fx/tex/" + opts.get("tex", "trail.png")))
		for k in ["repeat", "scroll", "head_hot", "core_hot", "along_fade", "intensity"]:
			if opts.has(k):
				m.set_shader_parameter(k, opts[k])
		if opts.has("soft"):
			m.set_shader_parameter("softness", opts.soft)
		_mats[key] = m
	return _mats[key]


## A flat ring in the XZ plane from `inner` to 1 (scale it to size): UV.x round the ring (0..1),
## UV.y from the inner to the outer edge. With `height` > 0 it is instead an open cylinder wall of
## radius 1 that tall, UV.y from the ground up.
static func ring_mesh(inner := 0.6, height := 0.0, segments := 48) -> ArrayMesh:
	var key := "ring_%.2f_%.2f_%d" % [inner, height, segments]
	if _meshes.has(key):
		return _meshes[key]
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in segments:
		var quad := []
		for j in [i, i + 1]:
			var a: float = TAU * j / segments
			var dir := Vector3(cos(a), 0, sin(a))
			var u: float = float(j) / segments
			if height > 0.0:
				quad.append([dir, Vector2(u, 0.0)])
				quad.append([dir + Vector3(0, height, 0), Vector2(u, 1.0)])
			else:
				quad.append([dir * inner, Vector2(u, 0.0)])
				quad.append([dir, Vector2(u, 1.0)])
		for idx in [0, 1, 2, 2, 1, 3]:
			st.set_uv(quad[idx][1])
			st.add_vertex(quad[idx][0])
	_meshes[key] = st.commit()
	return _meshes[key]


## A ribbon wound round a vertical axis: `turns` turns of radius 1 over `height`, `width` wide,
## UV.x along it from the bottom (0) to the top (1). Two of them make the level-up spiral.
static func helix_mesh(turns := 2.0, height := 4.0, width := 0.5, segments := 96) -> ArrayMesh:
	var key := "helix_%.2f_%.2f_%.2f" % [turns, height, width]
	if _meshes.has(key):
		return _meshes[key]
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	for i in segments + 1:
		var u := float(i) / segments
		var a := TAU * turns * u
		var r := 1.0 - 0.35 * u # narrowing as it rises
		var p := Vector3(cos(a) * r, height * u, sin(a) * r)
		var w := width * (0.4 + 0.6 * sin(u * PI))
		st.set_uv(Vector2(u, 0.0))
		st.add_vertex(p - Vector3(0, w * 0.5, 0))
		st.set_uv(Vector2(u, 1.0))
		st.add_vertex(p + Vector3(0, w * 0.5, 0))
	_meshes[key] = st.commit()
	return _meshes[key]


## A ribbon / ring mesh instance with its own instance colours; Vfx animates `progress`.
static func ribbon(mesh: Mesh, color: Color, tail: Color, opts := {}) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = ribbon_material(opts)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.set_instance_shader_parameter("tint", color)
	mi.set_instance_shader_parameter("tail", tail)
	mi.set_instance_shader_parameter("seed", randf() * 10.0)
	return mi


static func shader_material(path: String) -> ShaderMaterial:
	if not _mats.has(path):
		var m := ShaderMaterial.new()
		m.shader = load(path)
		_mats[path] = m
	return _mats[path]


## A glowing camera-facing sprite (not a particle): projectile cores, hand glows.
static func glow(color: Color, size: float, additive := true) -> MeshInstance3D:
	var q := QuadMesh.new()
	q.size = Vector2.ONE
	var mi := MeshInstance3D.new()
	mi.mesh = q
	mi.material_override = sprite_material(additive, 0.0, 1.2, 0.6)
	mi.set_instance_shader_parameter("tint", color)
	mi.scale = Vector3.ONE * size
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


# ---------------------------------------------------------------- particles

## A particle emitter from a spec (all keys optional):
##   amount, life, one_shot, explode (explosiveness 0..1), colors (ramp over the lifetime),
##   size (metres), speed [min, max], dir, spread (degrees), gravity, damping [min, max],
##   radius (sphere emission) or box (Vector3 extents), additive, streak (spark stretch),
##   scale "shrink" | "grow" | "pop" | "swell" | "", local (move with the emitter), orbit
##   (tangential velocity), flat (spread only horizontally), hardness; tex (a TEX name: textured,
##   eroding particles) with look {hot, dark, soft, distort, intensity}; spin (degrees/s),
##   tangent / radial (accelerations), life_rand (0..1 shorter random lives).
static func emitter(spec: Dictionary) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.amount = spec.get("amount", 16)
	p.lifetime = spec.get("life", 0.6)
	p.one_shot = spec.get("one_shot", false)
	p.explosiveness = spec.get("explode", 1.0 if p.one_shot else 0.0)
	p.local_coords = spec.get("local", false)
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	p.visibility_aabb = AABB(Vector3(-8, -8, -8), Vector3(16, 16, 16))
	var m := ParticleProcessMaterial.new()
	m.direction = spec.get("dir", Vector3.UP)
	m.spread = spec.get("spread", 180.0)
	var sp: Array = spec.get("speed", [1.0, 3.0])
	m.initial_velocity_min = sp[0]
	m.initial_velocity_max = sp[1]
	m.gravity = spec.get("gravity", Vector3.ZERO)
	var dm: Array = spec.get("damping", [0.0, 0.0])
	m.damping_min = dm[0]
	m.damping_max = dm[1]
	m.scale_min = 0.6
	m.scale_max = 1.3
	if spec.has("radius"):
		m.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
		m.emission_sphere_radius = spec.radius
	elif spec.has("box"):
		m.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
		m.emission_box_extents = spec.box
	if spec.get("flat", false):
		m.flatness = 1.0 # spread in the horizontal plane only (shockwave dust)
	if spec.has("orbit"):
		m.orbit_velocity_min = spec.orbit
		m.orbit_velocity_max = spec.orbit * 1.3
	var streak: float = spec.get("streak", 0.0)
	m.particle_flag_align_y = streak > 0.0
	m.angle_min = -180.0
	m.angle_max = 180.0
	if spec.has("spin"):
		m.angular_velocity_min = -float(spec.spin)
		m.angular_velocity_max = float(spec.spin)
	if spec.has("life_rand"):
		m.lifetime_randomness = float(spec.life_rand)
	if spec.has("tangent"):
		m.tangential_accel_min = float(spec.tangent)
		m.tangential_accel_max = float(spec.tangent) * 1.3
	if spec.has("radial"):
		m.radial_accel_min = float(spec.radial)
		m.radial_accel_max = float(spec.radial) * 1.3
	m.color_ramp = _ramp(spec.get("colors", [Color.WHITE, Color(1, 1, 1, 0)]))
	match spec.get("scale", "shrink"):
		"shrink": m.scale_curve = _curve([1.0, 0.0])
		"grow": m.scale_curve = _curve([0.45, 1.6])
		"pop": m.scale_curve = _curve([0.0, 1.0, 0.7])
		"swell": m.scale_curve = _curve([0.3, 0.85, 1.0, 1.1])
	p.process_material = m
	var q := QuadMesh.new()
	q.size = Vector2.ONE * float(spec.get("size", 0.15))
	if spec.has("tex"):
		q.material = fx_material(spec.tex, spec.get("additive", true), streak, spec.get("look", {}))
	else:
		q.material = sprite_material(spec.get("additive", true), streak, spec.get("hardness", 1.6))
	p.draw_pass_1 = q
	return p


## A burst that frees itself when done.
static func burst(parent: Node, pos: Vector3, spec: Dictionary) -> GPUParticles3D:
	spec = spec.duplicate()
	spec.one_shot = true
	var p := emitter(spec)
	parent.add_child(p)
	p.global_position = pos
	p.emitting = true
	parent.get_tree().create_timer(p.lifetime + 0.5).timeout.connect(p.queue_free)
	return p


static func _ramp(colors: Array) -> GradientTexture1D:
	var g := Gradient.new()
	var offsets := PackedFloat32Array()
	var cols := PackedColorArray()
	for i in range(colors.size()):
		offsets.append(float(i) / float(maxi(1, colors.size() - 1)))
		cols.append(colors[i])
	g.offsets = offsets
	g.colors = cols
	var t := GradientTexture1D.new()
	t.gradient = g
	return t


static func _curve(points: Array) -> CurveTexture:
	var c := Curve.new()
	for i in range(points.size()):
		c.add_point(Vector2(float(i) / float(points.size() - 1), points[i]))
	var t := CurveTexture.new()
	t.curve = c
	return t


# ---------------------------------------------------------------- ground decals

## A decal lying on the ground at `pos`, `size` metres across, tinted `color`; `glow` > 0 also
## makes it emit (bright magic on dark ground).
static func decal(kind: String, size: float, color: Color, glow := 0.0) -> Decal:
	var d := Decal.new()
	d.texture_albedo = decal_texture(kind)
	if glow > 0.0:
		d.texture_emission = decal_texture(kind + "+glow")
		d.emission_energy = glow
	d.modulate = color
	d.size = Vector3(size, 3.0, size)
	d.upper_fade = 0.3
	d.lower_fade = 0.3
	d.normal_fade = 0.4
	d.cull_mask = GROUND_LAYER
	return d


static func decal_texture(kind: String) -> Texture2D:
	if _tex.has(kind):
		return _tex[kind]
	if kind.ends_with("+glow"):
		# Emission isn't masked by the albedo's alpha: the glow texture carries the shape in its
		# colour (premultiplied), or the decal's whole box would glow.
		var src := decal_texture(kind.trim_suffix("+glow")).get_image()
		if src.is_compressed():
			src.decompress()
		src.clear_mipmaps()
		if src.get_width() > 256:
			src.resize(256, 256) # the glow is soft anyway; keeps the per-pixel loop cheap
		for y in src.get_height():
			for x in src.get_width():
				var c := src.get_pixel(x, y)
				src.set_pixel(x, y, Color(c.r * c.a, c.g * c.a, c.b * c.a, 1.0))
		src.generate_mipmaps()
		_tex[kind] = ImageTexture.create_from_image(src)
		return _tex[kind]
	var painted := "res://assets/fx/tex/decal_%s.png" % kind
	if ResourceLoader.exists(painted):
		# painted decals (tools/build_fx_textures.py): rune circle, frost patch, shock ring, scorch
		_tex[kind] = load(painted)
		return _tex[kind]
	# drawn here: the hover ring and the target circle
	var n := 128
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	for y in n:
		for x in n:
			var d := Vector2(x + 0.5 - n * 0.5, y + 0.5 - n * 0.5) / (n * 0.5)
			var r := d.length()
			var a := d.angle()
			var c := Color(1, 1, 1, 0)
			match kind:
				"ring":
					c.a = _band(r, 0.86, 0.07) + 0.12 * smoothstep(0.9, 0.2, r)
				"target":
					# a solid inner ring, a dashed outer one and four arrowheads pointing in
					var dash := float(fposmod(a * 12.0 / TAU + 0.25, 1.0) < 0.7)
					c.a = _band(r, 0.74, 0.035) * 0.8 + _band(r, 0.86, 0.05) * dash
					for k in 4:
						var ak := absf(wrapf(a - k * PI / 2.0, -PI, PI))
						if r > 0.9 and r < 1.0 and ak < (1.0 - r) * 1.4:
							c.a = 1.0
			img.set_pixel(x, y, c)
	img.generate_mipmaps()
	_tex[kind] = ImageTexture.create_from_image(img)
	return _tex[kind]


## A five-sided ice spike (tip up, centred): frost nova's spikes, the frostbolt's shard, a frozen
## unit's crystals.
static func ice_cone(height: float, radius: float) -> CylinderMesh:
	var cone := CylinderMesh.new()
	cone.top_radius = 0.0
	cone.bottom_radius = radius
	cone.height = height
	cone.radial_segments = 5
	cone.rings = 1
	return cone


## A soft band of width w centred on radius r0.
static func _band(r: float, r0: float, w: float) -> float:
	if w <= 0.0:
		return 0.0
	return clampf(1.0 - absf(r - r0) / w, 0.0, 1.0)
