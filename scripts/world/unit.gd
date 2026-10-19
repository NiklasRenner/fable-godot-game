## Base class for anything with health that can fight: players and monsters.
## Combat state is only mutated on the server; every peer reads the synced copies and drives
## the model's animation and nameplate from them.
class_name Unit
extends CharacterBody3D


const GRAVITY := 22.0
const JUMP_AIRTIME := 0.73 # 2 * Player.JUMP_VELOCITY / GRAVITY: how long a jump on flat ground lasts
const STEP_HEIGHT := 0.6 # ledges up to this high are walked up, not bumped into (cave lips, rocks)

@export var display_name := "Unit"
@export var level := 1
@export var max_health := 100
var health := 100
var is_dead := false
var is_ghost := false # players only; ghosts can't fight or be fought
var faction := "hostile" # "player" or "hostile"

# Server-only timers (seconds, from Unit.now()).
var slow_until := 0.0
var slow_factor := 1.0
var stun_until := 0.0
var root_until := 0.0
var burn_until := 0.0
var last_combat_time := -100.0

# Status effects as a synced bitmask, so every peer can show them (StatusFx).
const EFFECT_SLOW := 1
const EFFECT_ROOT := 2
const EFFECT_STUN := 4
const EFFECT_BURN := 8
const EFFECT_COMBAT := 16 # not a status: "squared up for a fight", so every peer plays the combat stance
var effects := 0
var _shown_effects := 0
var _effect_nodes := {} # effect bit -> Node3D

var rng := RandomNumberGenerator.new()

# Synced animation hints (server writes, every peer reads).
var moving := false
var attack_tick := 0
var airborne := false
var move_dir := Vector2.ZERO # local-space movement: x strafe, y forward(-1)/back(+1)
var sitting := false
## Where the server has this unit (synced ~20 times a second). Clients ease their copy towards it
## every frame instead of jumping, so remote units glide rather than step; see _smooth_transform.
var net_pos := Vector3.ZERO
var net_yaw := 0.0
const SMOOTH_RATE := 18.0 # per second; ~55 ms behind the latest update
const SNAP_DISTANCE := 6.0 # teleports (blink, respawn, spirit release) don't glide
var casting := false

var anim: AnimationPlayer = null
var walk_anim_speed := 1.5
var anim_profile := {} # the GameData.MODELS profile the model was loaded with (clip timing etc.)
var _ghost_visual := false
var _seen_attack_tick := 0

@onready var collision: CollisionShape3D = $CollisionShape3D
@onready var model: Node3D = $Model

var _nameplate: Label3D
var _plate: Node3D
var _hp_bar: MeshInstance3D
var _hp_lag := 1.0
var _hp_last := 1.0
var _lag_hold_until := 0.0


static func now() -> float:
	return Time.get_ticks_msec() / 1000.0


func _ready() -> void:
	rng.randomize()
	floor_snap_length = STEP_HEIGHT + 0.2 # stay glued to the ground after stepping up or walking off a ledge
	floor_max_angle = deg_to_rad(55.0)
	_build_nameplate()


## move_and_slide() with a step-up: when the body is on the ground and its horizontal motion is
## blocked at foot level but clear STEP_HEIGHT higher, it is lifted first and the floor snap sets it
## down on the ledge. Lets units walk up small steps the capsule would otherwise stop dead against.
func move_with_step() -> void:
	var motion := Vector3(velocity.x, 0, velocity.z) * get_physics_process_delta_time()
	# Not while rising: uphill the horizontal motion always "hits" the slope, and stepping up then
	# zeroed the vertical speed, eating every jump started on an incline.
	if is_on_floor() and velocity.y <= 0.0 and motion.length_squared() > 1e-6 and test_move(global_transform, motion):
		var lift := Vector3.UP * STEP_HEIGHT
		if not test_move(global_transform, lift) and not test_move(global_transform.translated(lift), motion):
			global_position += lift
			velocity.y = minf(velocity.y, 0.0)
	move_and_slide()


func _process(delta: float) -> void:
	_smooth_transform(delta)
	model.visible = not is_dead
	collision.disabled = is_dead
	_update_nameplate()
	_drive_animation()
	if effects != _shown_effects:
		_update_effect_visuals()
	if is_ghost != _ghost_visual:
		_ghost_visual = is_ghost
		for mi in model.find_children("*", "MeshInstance3D", true, false):
			mi.transparency = 0.6 if is_ghost else 0.0


# ---------------------------------------------------------------- model & animation

## Instance a .glb under Model and find its AnimationPlayer (looping the ambient clips).
func load_model(path: String, profile := {}) -> void:
	var scene: PackedScene = load(path)
	if scene == null:
		push_warning("Missing model: " + path)
		return
	var inst := scene.instantiate()
	prepare_model(inst, profile)
	anim_profile = profile
	model.add_child(inst)
	anim = inst.find_child("AnimationPlayer", true, false)
	if anim == null:
		return
	for n in ["idle", "idle_calm", "combat_idle", "walk", "cast", "sit"]:
		if anim.has_animation(n):
			anim.get_animation(n).loop_mode = Animation.LOOP_LINEAR
	if anim.has_animation("idle"):
		anim.play("idle")


## Applies a GameData.MODELS profile to a freshly instanced model (its facing). Shared with the
## model previewer so what it renders is what the game shows.
static func prepare_model(inst: Node3D, profile: Dictionary) -> void:
	inst.rotation.y = profile.get("yaw", 0.0)


## Picks the clip from the synced state, in priority order: dead, attack, sit, cast, jump, move.
func _drive_animation() -> void:
	if anim == null:
		return
	_lean_model()
	if is_dead:
		if anim.is_playing():
			anim.stop()
		return
	if attack_tick != _seen_attack_tick:
		_seen_attack_tick = attack_tick
		if anim.has_animation("attack"):
			anim.play("attack", 0.05, 1.4)
			return
	if anim.current_animation == "attack" and anim.is_playing():
		return
	if sitting and anim.has_animation("sit"):
		_play_once("sit", 0.2, 1.0)
		return
	if casting and anim.has_animation("cast"):
		_play_once("cast", 0.1, 1.0)
		return
	if airborne and anim.has_animation("jump"):
		# The profile's `jump_clip` [from, to] is the in-air part of the clip (no crouch, no landing),
		# stretched over the airtime, then held until the feet are down.
		var seg: Array = anim_profile.get("jump_clip", [0.0, anim.get_animation("jump").length])
		if anim.current_animation != "jump":
			anim.play("jump", 0.08, (seg[1] - seg[0]) / JUMP_AIRTIME)
			anim.seek(seg[0], true)
		elif anim.current_animation_position >= seg[1]:
			anim.pause()
		return
	var want := "walk" if moving else _idle_clip()
	var speed := walk_anim_speed if moving else 1.0
	if moving and move_dir.y > 0.3 and absf(move_dir.x) < 0.5:
		speed = -walk_anim_speed # backpedalling plays the walk cycle in reverse
	if moving and effects & EFFECT_SLOW:
		speed *= 0.6 # trudging
	if anim.current_animation != want or (moving and signf(anim.speed_scale) != signf(speed)):
		anim.play(want, 0.15, speed)
		if speed < 0.0 and anim.current_animation_position < 0.01:
			anim.seek(anim.current_animation_length - 0.01, true)


## Standing still: the combat stance while squared up for a fight (if the model has one), else idle.
func _idle_clip() -> String:
	if effects & EFFECT_COMBAT and anim.has_animation("combat_idle"):
		return "combat_idle"
	return "idle"


func _play_once(clip: String, blend: float, speed: float) -> void:
	if anim.current_animation != clip:
		anim.play(clip, blend, speed)


## Strafing turns the body a little towards the movement direction (like most third-person games)
## so sideways movement doesn't look like a sliding statue. The facing (and the camera) is unchanged.
func _lean_model() -> void:
	var target_yaw := 0.0
	if moving and not airborne and absf(move_dir.x) > 0.2:
		var dir := move_dir
		if dir.y > 0.0:
			dir.x = -dir.x # backing up sideways: lean the other way so legs read right
		target_yaw = clampf(atan2(-dir.x, maxf(0.15, -dir.y if dir.y < 0 else 0.15)) * 0.5, -deg_to_rad(45), deg_to_rad(45))
	model.rotation.y = lerp_angle(model.rotation.y, target_yaw, 0.15)


# ---------------------------------------------------------------- combat state (server)

func is_server() -> bool:
	return Net.is_server()


## Server: publish the transform for the synchronizer (call at the end of the physics tick).
func publish_transform() -> void:
	net_pos = position
	net_yaw = rotation.y


## Client: glide towards the last synced transform (snap if far: a teleport or the first update).
func _smooth_transform(delta: float) -> void:
	if is_server():
		return
	if position.distance_to(net_pos) > SNAP_DISTANCE:
		position = net_pos
		rotation.y = net_yaw
		return
	var a := 1.0 - exp(-SMOOTH_RATE * delta)
	position = position.lerp(net_pos, a)
	rotation.y = lerp_angle(rotation.y, net_yaw, a)


func in_combat() -> bool:
	return now() - last_combat_time < GameData.OUT_OF_COMBAT_AFTER


## Server: whether to stand in the combat stance (EFFECT_COMBAT). Players: while in combat.
func _combat_ready() -> bool:
	return in_combat()


func speed_multiplier() -> float:
	if now() < stun_until or now() < root_until:
		return 0.0
	if now() < slow_until:
		return slow_factor
	return 1.0


## Server: recompute the synced status bitmask from the timers (call every tick).
func update_effects() -> void:
	var e := 0
	if now() < slow_until:
		e |= EFFECT_SLOW
	if now() < root_until:
		e |= EFFECT_ROOT
	if now() < stun_until:
		e |= EFFECT_STUN
	if now() < burn_until:
		e |= EFFECT_BURN
	if _combat_ready():
		e |= EFFECT_COMBAT
	if is_dead:
		e = 0
	effects = e


func _update_effect_visuals() -> void:
	_shown_effects = effects
	for bit in [EFFECT_SLOW, EFFECT_ROOT, EFFECT_STUN, EFFECT_BURN]:
		var on: bool = (effects & bit) != 0
		if on and not _effect_nodes.has(bit) and GameData.visuals_enabled():
			var n := StatusFx.make(bit, head_height())
			add_child(n)
			_effect_nodes[bit] = n
		elif not on and _effect_nodes.has(bit):
			_effect_nodes[bit].queue_free()
			_effect_nodes.erase(bit)


func apply_slow(factor: float, duration: float) -> void:
	slow_factor = factor
	slow_until = now() + duration


func apply_stun(duration: float) -> void:
	stun_until = now() + duration


func apply_root(duration: float) -> void:
	root_until = now() + duration


## Server only. Returns the damage actually dealt.
func take_damage(amount: int, source: Node) -> int:
	if is_dead or is_ghost or not is_server():
		return 0
	amount = maxi(0, _mitigate(amount))
	health = maxi(0, health - amount)
	last_combat_time = now()
	_on_damaged(amount, source)
	if health == 0:
		_die(source)
	return amount


func heal_full() -> void:
	health = max_health


func _on_damaged(_amount: int, _source: Node) -> void:
	pass


## Armor etc. Override in subclasses.
func _mitigate(amount: int) -> int:
	return amount


func _die(killer: Node) -> void:
	is_dead = true
	velocity = Vector3.ZERO


## Faces a point on the horizontal plane.
func face_towards(point: Vector3) -> void:
	var d := point - global_position
	if d.length_squared() > 0.001:
		rotation.y = atan2(-d.x, -d.z)


# ---------------------------------------------------------------- nameplate

func nameplate_color() -> Color:
	return Color(0.4, 0.85, 0.4) if faction == "player" else Color(0.95, 0.35, 0.3)


func head_height() -> float:
	return 2.2


## Subclasses can hide the floating name/health (the local player uses the HUD frame instead).
func shows_nameplate() -> bool:
	return true


func _build_nameplate() -> void:
	_nameplate = WorldLabel.make("", head_height() + 0.3, nameplate_color(), 34, 9)
	add_child(_nameplate)
	# The bar is one quad drawn by assets/fx/plate.gdshader (frame, fill, gloss, the damage that
	# drains after the fill); the plate node turns it to face the camera each frame.
	_plate = Node3D.new()
	_plate.top_level = true
	add_child(_plate)
	var quad := QuadMesh.new()
	quad.size = Vector2(1.3, 0.152) # the shader's 120 x 14 pixel bar
	_hp_bar = MeshInstance3D.new()
	_hp_bar.mesh = quad
	_hp_bar.material_override = FxKit.shader_material("res://assets/fx/plate.gdshader")
	_hp_bar.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_plate.add_child(_hp_bar)


## Bosses get a gold rim on their bar (as on the target frame).
func plate_rim() -> Color:
	return Color(0.45, 0.42, 0.38)


func _update_nameplate() -> void:
	var show := not is_dead and shows_nameplate()
	_nameplate.visible = show
	_hp_bar.visible = show
	var frac := clampf(float(health) / float(maxi(1, max_health)), 0.0, 1.0)
	# The pale "just lost" chunk holds a moment, then drains down to the health.
	if frac >= _hp_lag:
		_hp_lag = frac
	elif now() > _lag_hold_until:
		_hp_lag = move_toward(_hp_lag, frac, get_process_delta_time() * 0.8)
	if frac < _hp_last:
		_lag_hold_until = now() + 0.45
	_hp_last = frac
	if not show:
		return
	_nameplate.text = "%s  [%d]%s" % [display_name, level, " (Ghost)" if is_ghost else ""]
	_nameplate.modulate = nameplate_color()
	_hp_bar.set_instance_shader_parameter("frac", frac)
	_hp_bar.set_instance_shader_parameter("lag", _hp_lag)
	_hp_bar.set_instance_shader_parameter("fill", nameplate_color())
	_hp_bar.set_instance_shader_parameter("rim", plate_rim())
	var cam := get_viewport().get_camera_3d()
	_plate.global_transform = Transform3D(cam.global_transform.basis if cam else Basis(), global_position + Vector3(0, head_height(), 0))
