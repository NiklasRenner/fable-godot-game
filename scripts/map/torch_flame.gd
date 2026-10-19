## The fire of a placed light prop (torches, lanterns, the cook fire): shader flames or, for a
## flame behind glass, a soft glow halo. Built in the game only, so the editor stays light.
extends Node3D

## Width and height of the open flame, in metres.
@export var size := Vector2(0.43, 0.62)
## Above 0: a glow halo this many metres across instead of an open flame (lanterns).
@export var glow := 0.0


func _ready() -> void:
	if not GameData.visuals_enabled():
		return
	if glow > 0.0:
		add_child(FxKit.glow(Color(1.0, 0.72, 0.38, 0.6), glow))
	else:
		add_child(Flame.make(size, randf() * 10.0))
