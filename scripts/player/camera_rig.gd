## WoW-style third-person camera.
##   left drag   : orbit the camera around the character (character keeps facing)
##   right drag  : turn the character (camera follows); pressing it after an orbit first turns
##                 the character to the camera's heading
##   both buttons: move forward (player reads `both_held`)
##   wheel       : zoom
## Camera yaw = character facing + `orbit_yaw`. After a left-drag, when the character moves
## again the orbit eases back to 0 so the camera settles behind them (WoW "camera follow").
extends Node3D

const MOUSE_SENS := 0.004
const MIN_PITCH := -1.2
const MAX_PITCH := 0.4
const MIN_ZOOM := 2.0
const MAX_ZOOM := 16.0
const FOLLOW_SPEED := 4.0

var orbit_yaw := 0.0
var pitch := -0.35
var left_held := false
var right_held := false
var _drag_origin := Vector2.ZERO
var _drag_distance := 0.0
var _trauma := 0.0 # camera shake, 0..1, decays (Vfx.shake: big hits and AoEs nearby)

@onready var arm: SpringArm3D = $SpringArm3D
@onready var camera: Camera3D = $SpringArm3D/Camera3D


func _ready() -> void:
	add_to_group("camera_rig")
	top_level = true
	arm.add_excluded_object(get_parent().get_rid())


func set_active(on: bool) -> void:
	camera.current = on
	set_process(on)
	set_process_unhandled_input(on)
	if not on:
		arm.spring_length = 0.0


func both_held() -> bool:
	return left_held and right_held


## True if the mouse moved enough during the last press to count as a drag, not a click.
func was_dragging() -> bool:
	return _drag_distance > 4.0


## Where the current/last press began (the cursor is captured while a button is held, so a
## release event's own position is meaningless).
func press_position() -> Vector2:
	return _drag_origin


func yaw() -> float:
	return get_parent().input_yaw + orbit_yaw


func _process(delta: float) -> void:
	var p: Node3D = get_parent()
	# Camera follow: while not orbiting and the character is moving, swing back behind them.
	if not left_held and p.input_dir.length_squared() > 0.01 and absf(orbit_yaw) > 0.001:
		orbit_yaw = lerp_angle(orbit_yaw, 0.0, 1.0 - exp(-FOLLOW_SPEED * delta))
		if absf(orbit_yaw) < 0.002:
			orbit_yaw = 0.0
	global_position = p.global_position + Vector3(0, 1.6, 0)
	rotation = Vector3(pitch, yaw(), 0)
	if _trauma > 0.0:
		_trauma = maxf(0.0, _trauma - delta * 2.2)
		var k := _trauma * _trauma
		var t := Time.get_ticks_msec() * 0.001
		camera.h_offset = k * 0.18 * sin(t * 47.0)
		camera.v_offset = k * 0.14 * sin(t * 59.0 + 1.3)
	elif camera.h_offset != 0.0 or camera.v_offset != 0.0:
		camera.h_offset = 0.0
		camera.v_offset = 0.0


## A camera shake of `amount` (0..1) from something at `from`: weaker with distance, gone at 25 m.
func shake(amount: float, from: Vector3) -> void:
	var d := global_position.distance_to(from)
	_trauma = clampf(maxf(_trauma, amount * clampf(1.0 - d / 25.0, 0.0, 1.0)), 0.0, 1.0)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		match event.button_index:
			MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT:
				var was_held := left_held or right_held
				if event.button_index == MOUSE_BUTTON_LEFT:
					left_held = event.pressed
				else:
					right_held = event.pressed
				var now_held := left_held or right_held
				if now_held and not was_held:
					_drag_origin = event.position
					_drag_distance = 0.0
					Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
				if event.button_index == MOUSE_BUTTON_RIGHT and event.pressed and absf(orbit_yaw) > 0.001:
					# Right button after an orbit: the character turns to face where the camera
					# looks (the view itself doesn't move), instead of the camera snapping behind them.
					get_parent().turn(orbit_yaw)
					orbit_yaw = 0.0
				elif was_held and not now_held:
					Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
					get_viewport().warp_mouse(_drag_origin) # cursor reappears where the drag began
			MOUSE_BUTTON_WHEEL_UP:
				arm.spring_length = clampf(arm.spring_length - 1.0, MIN_ZOOM, MAX_ZOOM)
			MOUSE_BUTTON_WHEEL_DOWN:
				arm.spring_length = clampf(arm.spring_length + 1.0, MIN_ZOOM, MAX_ZOOM)
	elif event is InputEventMouseMotion and (left_held or right_held):
		_drag_distance += event.relative.length()
		var dyaw: float = -event.relative.x * MOUSE_SENS
		pitch = clampf(pitch - event.relative.y * MOUSE_SENS, MIN_PITCH, MAX_PITCH)
		if right_held:
			# Mouselook: turn the character; camera stays behind.
			get_parent().turn(dyaw)
			orbit_yaw = 0.0
		else:
			orbit_yaw = wrapf(orbit_yaw + dyaw, -PI, PI)
