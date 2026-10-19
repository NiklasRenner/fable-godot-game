## Client-side target selection for the local player: Tab cycling (WoW-style, by what is on screen
## and near the centre of the view), click picking (NPCs, loot, enemies) and mouse hover.
## The chosen target is sent to the server with the "target" request; the server validates it
## whenever it matters.
class_name Targeting
extends RefCounted

const TAB_RANGE := 40.0
const TAB_RESET_SECONDS := 2.5    # idle time after which Tab starts again from the best candidate
const TAB_CENTRE_WEIGHT := 25.0   # metres of "penalty" for a mob at the edge of the screen vs dead centre
const CLICK_PICK_RADIUS_PX := 40.0

var p: Player
var target: Node = null
var hovered: Node = null

var _ring: Decal  # the target circle on the ground under the target
var _hover_ring: Decal # a faint one under whatever the mouse is over
var _ring_t := 0.0
var _tab_list: Array = []
var _tab_index := -1
var _last_tab_time := -100.0
var _hover_t := 0.0


func _init(player: Player) -> void:
	p = player
	_ring = FxKit.decal("target", 2.0, Color.WHITE, 1.2)
	_hover_ring = FxKit.decal("ring", 2.0, Color(1, 1, 1, 0.35), 0.4)
	for d in [_ring, _hover_ring]:
		d.visible = false
		d.top_level = true
		p.add_child(d)


## Red for enemies, green for friends (players): the WoW selection circle's colours.
static func circle_color(t: Node) -> Color:
	return Color(0.35, 1.0, 0.3) if t.get("faction") == "player" else Color(1.0, 0.22, 0.12)


## How wide a unit's circle is: its footprint, bigger for big monsters.
static func circle_size(t: Node) -> float:
	var stats = t.get("stats")
	if stats is Dictionary and stats.has("scale"):
		return (2.4 if stats.get("shape", "") == "quadruped" else 1.9) * float(stats.scale)
	return 1.9


func set_target(t: Node) -> void:
	if t == target:
		return
	target = t
	p.target_changed.emit(t)
	p.request("target", [t.get_path() if is_instance_valid(t) else NodePath("")])


func process(delta: float) -> void:
	if not p.bot_mode:
		_hover_t += delta
		if _hover_t > 0.08:
			_hover_t = 0.0
			_update_hover()
	if not is_instance_valid(target) or target.is_dead:
		if target != null:
			set_target(null)
		_ring.visible = false
	else:
		_ring.visible = true
		_ring_t += delta
		var sz := circle_size(target) * (1.0 + 0.03 * sin(_ring_t * 4.0))
		_ring.size = Vector3(sz, 3.0, sz)
		_ring.modulate = circle_color(target)
		_ring.global_position = target.global_position + Vector3(0, 0.6, 0)
		_ring.rotation.y = _ring_t * 0.6
	var h: Node = hovered
	_hover_ring.visible = is_instance_valid(h) and h != target and not h.is_dead
	if _hover_ring.visible:
		var hs := circle_size(h)
		_hover_ring.size = Vector3(hs, 3.0, hs)
		_hover_ring.modulate = Color(circle_color(h), 0.45)
		_hover_ring.global_position = h.global_position + Vector3(0, 0.6, 0)


func _camera() -> Camera3D:
	return p.get_viewport().get_camera_3d()


func _update_hover() -> void:
	hovered = null
	var cam := _camera()
	if Input.mouse_mode != Input.MOUSE_MODE_VISIBLE or cam == null:
		return
	var hit := _ray(cam, p.get_viewport().get_mouse_position(), 2, 120.0)
	if hit and hit.collider is Unit:
		hovered = hit.collider


func _ray(cam: Camera3D, screen_pos: Vector2, mask: int, length: float) -> Dictionary:
	var from := cam.project_ray_origin(screen_pos)
	var q := PhysicsRayQueryParameters3D.create(from, from + cam.project_ray_normal(screen_pos) * length, mask)
	q.exclude = [p.get_rid()]
	return p.get_world_3d().direct_space_state.intersect_ray(q)


## Living hostiles sorted the way WoW cycles them: those on screen, scored by distance plus how far
## from the centre of the view they are, so a mob dead centre at 10 m beats one at 5 m on the edge.
## Only when nothing is on screen does it fall back to everything in range by distance.
func _candidates() -> Array:
	var cam := _camera()
	var vp := p.get_viewport().get_visible_rect().size
	var centre := vp * 0.5
	var on_screen := []
	var all := []
	for m in p.get_tree().get_nodes_in_group("monsters"):
		if m.is_dead:
			continue
		var dist: float = p.global_position.distance_to(m.global_position)
		if dist > TAB_RANGE:
			continue
		all.append([dist, m])
		if cam == null:
			continue
		var head: Vector3 = m.global_position + Vector3(0, 1.0, 0)
		if cam.is_position_behind(head):
			continue
		var sp := cam.unproject_position(head)
		if sp.x < -40 or sp.y < -40 or sp.x > vp.x + 40 or sp.y > vp.y + 40:
			continue
		on_screen.append([dist + TAB_CENTRE_WEIGHT * (sp - centre).length() / centre.length(), m])
	var list := on_screen if not on_screen.is_empty() else all
	list.sort_custom(func(a, b): return a[0] < b[0])
	return list.map(func(e): return e[1])


func cycle(backwards := false) -> void:
	var t := Unit.now()
	if t - _last_tab_time > TAB_RESET_SECONDS or _tab_list.is_empty():
		_tab_list = _candidates()
		_tab_index = -1
	else:
		_tab_list = _tab_list.filter(func(m): return is_instance_valid(m) and not m.is_dead)
	_last_tab_time = t
	if _tab_list.is_empty():
		set_target(null)
		return
	var step := -1 if backwards else 1
	_tab_index = posmod(_tab_index + step, _tab_list.size())
	if _tab_list[_tab_index] == target and _tab_list.size() > 1:
		_tab_index = posmod(_tab_index + step, _tab_list.size()) # fresh list: skip the current target
	set_target(_tab_list[_tab_index])


## Click: talk to an NPC, loot a bag, or target an enemy (with a forgiving pixel radius).
## Returns true when an enemy was targeted.
func click(screen_pos: Vector2) -> bool:
	var cam := _camera()
	if cam == null:
		return false
	var npc_hit := _ray(cam, screen_pos, 16, 200.0)
	if npc_hit and npc_hit.collider.is_in_group("npcs"):
		if p.global_position.distance_to(npc_hit.collider.global_position) <= npc_hit.collider.INTERACT_RANGE:
			p.npc_opened.emit(npc_hit.collider.npc_id)
		else:
			p.message.emit("You are too far away.")
		return false
	var loot_hit := _ray(cam, screen_pos, 8, 200.0)
	if loot_hit and loot_hit.collider.is_in_group("loot"):
		if p.global_position.distance_to(loot_hit.collider.global_position) <= LootBag.PICKUP_RANGE:
			p.request("loot", [loot_hit.collider.get_path()])
		else:
			p.message.emit("You are too far away.")
		return false
	var hit := _ray(cam, screen_pos, 2, 200.0)
	if hit and hit.collider is Unit and hit.collider.faction != "player":
		set_target(hit.collider)
		return true
	var best: Node = null
	var best_px := CLICK_PICK_RADIUS_PX
	for m in p.get_tree().get_nodes_in_group("monsters"):
		var centre: Vector3 = m.global_position + Vector3.UP * 0.9
		if m.is_dead or cam.is_position_behind(centre):
			continue
		var px: float = cam.unproject_position(centre).distance_to(screen_pos)
		if px < best_px:
			best_px = px
			best = m
	if best:
		set_target(best)
	return best != null
