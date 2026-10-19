## A pile of loot dropped by a monster. Spawned by the server through World.LootSpawner.
## Contents are synced; the server hands items out via the player's "loot" request and frees the bag
## when it is empty or after LIFETIME seconds.
class_name LootBag
extends StaticBody3D

const LIFETIME := 90.0
const PICKUP_RANGE := 4.0
const OWNER_SECONDS := 60.0 # the tagger's loot; after this anyone may take it

var items: Array = []  # synced
var owner_peer := 0    # synced: who it belongs to (0 = anyone)
var _label: Label3D
var _model: Node3D
var _sparkle: GPUParticles3D
var _spawned_at := 0.0


func setup(data: Dictionary) -> void:
	position = data.pos
	items = data.items.duplicate()
	owner_peer = int(data.get("owner", 0))


func _ready() -> void:
	add_to_group("loot")
	collision_layer = 8  # loot layer, for click-picking
	collision_mask = 0
	_spawned_at = Unit.now()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.8, 0.6, 0.8)
	shape.shape = box
	shape.position.y = 0.3
	add_child(shape)
	# a sack on the ground (assets/prop_lootbag.glb), turned at random, with gold motes rising
	# off it while it's yours to loot (the Classic sparkle on a lootable corpse)
	_model = load("res://assets/prop_lootbag.glb").instantiate()
	_model.scale = Vector3.ONE * 0.75
	_model.rotation.y = randf() * TAU
	add_child(_model)
	if GameData.visuals_enabled():
		_sparkle = FxKit.emitter({"amount": 10, "life": 1.4, "size": 0.07, "speed": [0.1, 0.3], "box": Vector3(0.35, 0.1, 0.35),
			"gravity": Vector3(0, 0.7, 0), "scale": "pop", "colors": [Color(1, 0.85, 0.3, 0.0), Color(1, 0.9, 0.5, 0.9), Color(1, 0.8, 0.3, 0.0)]})
		_sparkle.position.y = 0.2
		add_child(_sparkle)
		_sparkle.emitting = true
	_label = WorldLabel.make("", 0.9, Color(0.95, 0.85, 0.4), 36, 8, 0.005)
	add_child(_label)


func _process(_delta: float) -> void:
	var names := []
	for id in items:
		names.append(GameData.item_stat(id, "name", id))
	_label.text = "\n".join(names)
	_label.visible = WorldLabel.near_local_player(get_tree(), global_position)
	var mine := can_loot(multiplayer.get_unique_id())
	_label.modulate = Color(0.95, 0.85, 0.4) if mine else Color(0.6, 0.6, 0.6)
	if _sparkle:
		_sparkle.emitting = mine
	if Net.is_server():
		var age := Unit.now() - _spawned_at
		if items.is_empty() or age > LIFETIME:
			queue_free()


## Whether `peer` may take from this bag: its owner, or anyone once the owner's window is over.
func can_loot(peer: int) -> bool:
	return owner_peer == 0 or owner_peer == peer or Unit.now() - _spawned_at > OWNER_SECONDS


## Server only. Moves as many items as fit into the player's inventory; returns the ids given.
func server_take_all(player: Node) -> Array:
	var given := []
	var remaining := []
	for id in items:
		if player.gear.add_item(id):
			given.append(id)
		else:
			remaining.append(id)
	items = remaining
	return given
