## Visuals for the status effects a unit can be under (see Unit.EFFECT_*). Built on every peer
## from the synced `effects` bitmask: ice around a rooted unit's feet, drifting frost on a slowed
## one, orbiting sparks over a stunned head and flames on a burning body.
class_name StatusFx
extends RefCounted


static func make(effect: int, head_height: float) -> Node3D:
	match effect:
		Unit.EFFECT_SLOW: return _frost(head_height)
		Unit.EFFECT_ROOT: return _ice_root()
		Unit.EFFECT_STUN: return _stun_sparks(head_height)
		Unit.EFFECT_BURN: return _flames(head_height)
	return Node3D.new()


## A standing torch: wooden post (its top at the node's origin), warm light and a small flame.
## The cave's torches (the camp's are scenes/props/torch.tscn).
static func torch(post_height: float, energy: float, light_range: float) -> Node3D:
	# The post is the torch model (2 m, basket on top) scaled to post_height, hanging from the
	# root so the root is where the fire burns.
	var root := Node3D.new()
	var post: Node3D = load("res://assets/prop_torch.glb").instantiate()
	post.scale = Vector3.ONE * post_height / 2.0
	post.position.y = -post_height
	root.add_child(post)
	var light := OmniLight3D.new()
	light.light_color = Color(1.0, 0.72, 0.4)
	light.light_energy = energy
	light.omni_range = light_range
	light.light_specular = 0.3
	light.shadow_enabled = false
	root.add_child(light)
	if GameData.visuals_enabled():
		var flame := Flame.make(Vector2(0.45, 0.65) * post_height / 2.0, randf() * 10.0)
		flame.position.y = -0.12 * post_height / 2.0
		root.add_child(flame)
	return root


static func _unshaded(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.vertex_color_use_as_albedo = true
	return m


static func _particles(color: Color, amount: int, lifetime: float, size: float, fade_in := 0.2) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.amount = amount
	p.lifetime = lifetime
	var mat := ParticleProcessMaterial.new()
	mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	var ramp := Gradient.new()
	ramp.set_color(0, Color(color, 0.0))
	ramp.add_point(fade_in, Color(color, 0.9))
	ramp.set_color(ramp.get_point_count() - 1, Color(color, 0.0))
	var rt := GradientTexture1D.new()
	rt.gradient = ramp
	mat.color_ramp = rt
	p.process_material = mat
	var mesh := BoxMesh.new()
	mesh.size = Vector3.ONE * size
	mesh.material = _unshaded(color)
	p.draw_pass_1 = mesh
	return p


## Slowed: pale motes drifting down around the body.
static func _frost(head_height: float) -> Node3D:
	var p := _particles(Color(0.75, 0.9, 1.0), 24, 1.6, 0.05)
	var mat: ParticleProcessMaterial = p.process_material
	mat.emission_box_extents = Vector3(0.6, head_height * 0.5, 0.6)
	mat.direction = Vector3(0, -1, 0)
	mat.spread = 20.0
	mat.initial_velocity_min = 0.2
	mat.initial_velocity_max = 0.5
	mat.gravity = Vector3.ZERO
	p.position.y = head_height * 0.6
	return p


## Rooted: a ring of ice crystals that grows out of the ground around the feet.
static func _ice_root() -> Node3D:
	var root := Node3D.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	for i in range(7):
		var a := i * TAU / 7.0 + rng.randf_range(-0.2, 0.2)
		var r := rng.randf_range(0.45, 0.7)
		var h := rng.randf_range(0.5, 1.0)
		var mi := MeshInstance3D.new()
		mi.mesh = FxKit.ice_cone(h, 0.14)
		var m := _unshaded(Color(0.8, 0.92, 1.0, 0.85))
		m.vertex_color_use_as_albedo = false
		mi.material_override = m
		mi.position = Vector3(cos(a) * r, h * 0.5, sin(a) * r)
		mi.rotation = Vector3(rng.randf_range(-0.35, 0.35), 0, rng.randf_range(-0.35, 0.35))
		mi.scale = Vector3(1, 0.05, 1)
		root.add_child(mi)
		var tw := mi.create_tween()
		tw.tween_property(mi, "scale", Vector3.ONE, 0.25).set_delay(i * 0.03)
	var p := _particles(Color(0.85, 0.95, 1.0), 16, 1.2, 0.04)
	var mat: ParticleProcessMaterial = p.process_material
	mat.emission_box_extents = Vector3(0.7, 0.1, 0.7)
	mat.direction = Vector3(0, 1, 0)
	mat.spread = 30.0
	mat.initial_velocity_min = 0.3
	mat.initial_velocity_max = 0.7
	mat.gravity = Vector3(0, -0.5, 0)
	p.position.y = 0.1
	root.add_child(p)
	return root


## Stunned: yellow sparks circling above the head.
static func _stun_sparks(head_height: float) -> Node3D:
	var p := _particles(Color(1.0, 0.9, 0.35), 10, 1.0, 0.07, 0.05)
	var mat: ParticleProcessMaterial = p.process_material
	mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_RING
	mat.emission_ring_radius = 0.4
	mat.emission_ring_inner_radius = 0.35
	mat.emission_ring_height = 0.05
	mat.emission_ring_axis = Vector3(0, 1, 0)
	mat.orbit_velocity_min = 0.8
	mat.orbit_velocity_max = 0.8
	mat.gravity = Vector3.ZERO
	mat.initial_velocity_min = 0.0
	mat.initial_velocity_max = 0.0
	p.position.y = head_height + 0.15
	return p


## Burning: flames licking up the body with a warm light.
static func _flames(head_height: float) -> Node3D:
	var root := Node3D.new()
	var p := _particles(Color(1.0, 0.55, 0.15), 40, 0.7, 0.09, 0.1)
	var mat: ParticleProcessMaterial = p.process_material
	mat.emission_box_extents = Vector3(0.35, head_height * 0.4, 0.35)
	mat.direction = Vector3(0, 1, 0)
	mat.spread = 15.0
	mat.initial_velocity_min = 1.0
	mat.initial_velocity_max = 2.0
	mat.gravity = Vector3(0, 1.5, 0)
	mat.scale_min = 0.6
	mat.scale_max = 1.4
	var ramp: Gradient = mat.color_ramp.gradient
	ramp.set_color(ramp.get_point_count() - 1, Color(0.3, 0.05, 0.0, 0.0))
	p.position.y = head_height * 0.5
	root.add_child(p)
	var light := OmniLight3D.new()
	light.light_color = Color(1.0, 0.6, 0.25)
	light.light_energy = 1.5
	light.omni_range = 4.0
	light.position.y = head_height * 0.6
	root.add_child(light)
	return root
