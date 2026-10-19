## Text floating in the 3D world (nameplates, NPC names, loot contents, corpse markers): one way
## to build it, and one rule for when it shows — only within a short distance of the local player,
## so the world isn't plastered with labels. Quest markers and anything targeted or hovered are
## exempt (see the callers).
class_name WorldLabel
extends RefCounted

const RANGE := 12.0        # names and labels
const RANGE_NEAR := 9.0    # monster nameplates (health bars): a bit tighter


static func make(text: String, y: float, color: Color, font_size := 40, outline := 10, pixel_size := 0.006) -> Label3D:
	var l := Label3D.new()
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.no_depth_test = true
	l.font_size = font_size
	l.pixel_size = pixel_size
	l.outline_size = outline
	l.modulate = color
	l.font = UITheme.serif(700)
	l.position.y = y
	l.text = text
	return l


static func near_local_player(tree: SceneTree, pos: Vector3, max_dist := RANGE) -> bool:
	var p: Node3D = tree.get_first_node_in_group("local_player")
	return p != null and pos.distance_to(p.global_position) < max_dist
