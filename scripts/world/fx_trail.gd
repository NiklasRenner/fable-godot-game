## A ribbon trailing behind a moving node (a fireball, a charging warrior): every frame it records
## where `follow` is and draws the last `life` seconds of that path as a camera-facing strip with
## the ribbon shader (FxKit.ribbon_material), tapering from `width` at the head to nothing at the
## tail. When `follow` goes away (or stop() is called) the trail stops growing, its tail catches
## up with its head and it frees itself.
class_name FxTrail
extends MeshInstance3D

var follow: Node3D
var life := 0.35
var width := 0.5
var offset := Vector3.ZERO
var _points: Array = [] # [position, time]
var _mesh := ImmediateMesh.new()
var _stopped := false


static func make(follow_: Node3D, color: Color, tail_color: Color, width_ := 0.5, life_ := 0.35, opts := {}) -> FxTrail:
	var t := FxTrail.new()
	t.follow = follow_
	t.width = width_
	t.life = life_
	t.mesh = t._mesh
	t.material_override = FxKit.ribbon_material(opts)
	t.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	t.set_instance_shader_parameter("tint", color)
	t.set_instance_shader_parameter("tail", tail_color)
	t.set_instance_shader_parameter("seed", randf() * 10.0)
	t.top_level = true
	return t


func stop() -> void:
	_stopped = true


func _ready() -> void:
	global_transform = Transform3D.IDENTITY
	extra_cull_margin = 50.0
	# rebuilt just before drawing, after this frame's tweens have moved what it follows (in
	# _process it would trail a frame behind: a gap between a fast bolt and its ribbon)
	RenderingServer.frame_pre_draw.connect(_rebuild)


func _exit_tree() -> void:
	if RenderingServer.frame_pre_draw.is_connected(_rebuild):
		RenderingServer.frame_pre_draw.disconnect(_rebuild)


func _rebuild() -> void:
	var now := Time.get_ticks_msec() / 1000.0
	if not _stopped and is_instance_valid(follow) and follow.is_inside_tree():
		var p := follow.global_position + offset
		if _points.is_empty() or (_points[-1][0] as Vector3).distance_to(p) > 0.04:
			_points.append([p, now])
		else:
			_points[-1][1] = now
	else:
		_stopped = true
	while _points.size() > 0 and now - float(_points[0][1]) > life:
		_points.pop_front()
	_mesh.clear_surfaces()
	if _points.size() < 2:
		if _stopped:
			queue_free()
		return
	var cam := get_viewport().get_camera_3d()
	var eye := cam.global_position if cam else Vector3(0, 10, 10)
	_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	var n := _points.size()
	var total := 0.0
	for i in range(n - 1, 0, -1):
		total += (_points[i][0] as Vector3).distance_to(_points[i - 1][0])
	var along := 0.0
	for i in range(n - 1, -1, -1): # head first
		var p: Vector3 = _points[i][0]
		var age := clampf((now - float(_points[i][1])) / life, 0.0, 1.0)
		var dir: Vector3 = (_points[mini(i + 1, n - 1)][0] - _points[maxi(i - 1, 0)][0])
		if dir.length_squared() < 1e-8:
			dir = Vector3.FORWARD
		var side := dir.normalized().cross((eye - p).normalized()).normalized() * width * 0.5 * (1.0 - age * 0.7)
		var u := along / maxf(total, 0.001)
		_mesh.surface_set_color(Color(1, 1, 1, 1.0 - age))
		_mesh.surface_set_uv(Vector2(u, 0.0))
		_mesh.surface_add_vertex(p - side)
		_mesh.surface_set_color(Color(1, 1, 1, 1.0 - age))
		_mesh.surface_set_uv(Vector2(u, 1.0))
		_mesh.surface_add_vertex(p + side)
		if i > 0:
			along += p.distance_to(_points[i - 1][0])
	_mesh.surface_end()
