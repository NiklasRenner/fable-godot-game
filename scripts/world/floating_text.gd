## Floating combat number that rises and fades. Client-side cosmetic only.
extends Label3D


func show_text(pos: Vector3, amount: int, kind: String, on_player: bool) -> void:
	global_position = pos
	billboard = BaseMaterial3D.BILLBOARD_ENABLED
	no_depth_test = true
	pixel_size = 0.008
	font_size = 56
	outline_size = 12
	if kind == "dies":
		text = "dies"
		modulate = Color(0.7, 0.7, 0.7)
	elif amount == 0:
		text = kind
		modulate = Color(0.95, 0.85, 0.4)
	else:
		text = str(amount)
		modulate = Color(1, 0.3, 0.25) if on_player else Color(1, 0.95, 0.6)
		if kind != "melee":
			text = "%d %s" % [amount, kind]
	var tween := create_tween()
	tween.tween_property(self, "position:y", position.y + 2.0, 1.1)
	tween.parallel().tween_property(self, "modulate:a", 0.0, 1.1).set_delay(0.4)
	tween.tween_callback(queue_free)
