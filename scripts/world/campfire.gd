## The camp's fire: shader flames (Flame) over the campfire model's logs, rising embers, a smoke
## plume and a light that breathes with the flames. Purely cosmetic, runs on every peer.
extends Node3D

var _flames: Array[Node3D] = []
var _light: OmniLight3D
var _t := 0.0


func _ready() -> void:
	# one big flame in the middle and two smaller ones leaning off it, out of step
	for spec in [[Vector2(1.1, 1.5), Vector3(0, 0.15, 0), 0.0], [Vector2(0.7, 1.0), Vector3(0.25, 0.12, 0.1), 2.1],
			[Vector2(0.6, 0.85), Vector3(-0.2, 0.12, -0.15), 4.3]]:
		var f := Flame.make(spec[0], spec[2])
		f.position = spec[1]
		add_child(f)
		_flames.append(f)

	_light = OmniLight3D.new()
	_light.light_color = Color(1.0, 0.65, 0.3)
	_light.light_energy = 3.0
	_light.omni_range = 13.0
	_light.light_specular = 0.3 # warm light, not wet highlights
	_light.shadow_enabled = true
	_light.position.y = 1.3
	add_child(_light)

	add_child(_embers())
	add_child(_smoke())
	Audio.loop_at("fire", self, -4.0, 22.0)


func _embers() -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.amount = 28
	p.lifetime = 1.8
	p.position.y = 0.5
	var mat := ParticleProcessMaterial.new()
	mat.direction = Vector3(0, 1, 0)
	mat.spread = 25.0
	mat.initial_velocity_min = 1.2
	mat.initial_velocity_max = 2.4
	mat.gravity = Vector3(0, 0.6, 0)
	mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	mat.emission_sphere_radius = 0.3
	mat.scale_min = 0.5
	mat.scale_max = 1.0
	mat.turbulence_enabled = true
	mat.turbulence_noise_strength = 1.5
	mat.turbulence_noise_scale = 3.0
	var ramp := Gradient.new()
	ramp.set_color(0, Color(1.0, 0.85, 0.4, 1.0))
	ramp.set_color(1, Color(1.0, 0.25, 0.0, 0.0))
	var ramp_tex := GradientTexture1D.new()
	ramp_tex.gradient = ramp
	mat.color_ramp = ramp_tex
	p.process_material = mat
	var mesh := QuadMesh.new()
	mesh.size = Vector2(0.09, 0.09)
	mesh.material = Flame.puff_material(true)
	p.draw_pass_1 = mesh
	return p


func _smoke() -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.amount = 14
	p.lifetime = 4.0
	p.position.y = 1.4
	var mat := ParticleProcessMaterial.new()
	mat.direction = Vector3(0, 1, 0)
	mat.spread = 12.0
	mat.initial_velocity_min = 0.6
	mat.initial_velocity_max = 1.0
	mat.gravity = Vector3(0.15, 0.25, 0)
	mat.scale_min = 0.6
	mat.scale_max = 1.2
	mat.angle_min = -180.0
	mat.angle_max = 180.0
	mat.turbulence_enabled = true
	mat.turbulence_noise_strength = 0.8
	var ramp := Gradient.new()
	ramp.set_offset(0, 0.0)
	ramp.set_color(0, Color(0.3, 0.27, 0.25, 0.0))
	ramp.add_point(0.15, Color(0.3, 0.27, 0.25, 0.35))
	ramp.set_offset(ramp.get_point_count() - 1, 1.0)
	ramp.set_color(ramp.get_point_count() - 1, Color(0.4, 0.4, 0.42, 0.0))
	var ramp_tex := GradientTexture1D.new()
	ramp_tex.gradient = ramp
	mat.color_ramp = ramp_tex
	var curve := Curve.new()
	curve.add_point(Vector2(0, 0.5))
	curve.add_point(Vector2(1, 2.0))
	var ct := CurveTexture.new()
	ct.curve = curve
	mat.scale_curve = ct
	p.process_material = mat
	var mesh := QuadMesh.new()
	mesh.size = Vector2(0.8, 0.8)
	mesh.material = Flame.puff_material(false)
	p.draw_pass_1 = mesh
	return p


func _process(delta: float) -> void:
	_t += delta
	# the shader animates the fire itself; this only breathes its size and the light with it
	for i in range(_flames.size()):
		var ph := _t * (3.0 + i * 1.3) + i * 1.7
		_flames[i].scale = Vector3.ONE * (1.0 + 0.08 * sin(ph) + 0.05 * sin(ph * 2.3))
	_light.light_energy = 2.6 + 0.6 * sin(_t * 9.0) + 0.3 * sin(_t * 23.0)
