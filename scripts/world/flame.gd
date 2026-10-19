## Shader flames (assets/fx/flame.gdshader) for campfires and torches: three crossed quads so the
## fire looks round from every side. Shared material; each flame gets its own phase.
class_name Flame
extends RefCounted

static var _material: ShaderMaterial
static var _puff: Texture2D


static func make(size: Vector2, phase := 0.0) -> Node3D:
	var root := Node3D.new()
	root.name = "Flame"
	var quad := QuadMesh.new()
	quad.size = size
	quad.center_offset = Vector3(0, size.y * 0.5, 0)
	for i in range(3):
		var mi := MeshInstance3D.new()
		mi.mesh = quad
		mi.material_override = material()
		mi.rotation.y = i * PI / 3.0
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.set_instance_shader_parameter("phase", phase + i * 0.37)
		root.add_child(mi)
	return root


static func material() -> ShaderMaterial:
	if _material == null:
		var noise := FastNoiseLite.new()
		noise.frequency = 0.03
		noise.fractal_octaves = 3
		var tex := NoiseTexture2D.new()
		tex.width = 128
		tex.height = 128
		tex.seamless = true
		tex.noise = noise
		_material = ShaderMaterial.new()
		_material.shader = load("res://assets/fx/flame.gdshader")
		_material.set_shader_parameter("noise_tex", tex)
	return _material


## A soft round dot (white, alpha falling off to the edge) for embers and smoke puffs.
static func puff() -> Texture2D:
	if _puff == null:
		var g := Gradient.new()
		g.set_color(0, Color(1, 1, 1, 1))
		g.set_color(1, Color(1, 1, 1, 0))
		var t := GradientTexture2D.new()
		t.gradient = g
		t.fill = GradientTexture2D.FILL_RADIAL
		t.fill_from = Vector2(0.5, 0.5)
		t.fill_to = Vector2(1.0, 0.5)
		t.width = 64
		t.height = 64
		_puff = t
	return _puff


## Billboarded particle material using puff(): additive for embers, alpha for smoke.
static func puff_material(additive: bool) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_texture = puff()
	m.vertex_color_use_as_albedo = true
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD if additive else BaseMaterial3D.BLEND_MODE_MIX
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	return m
