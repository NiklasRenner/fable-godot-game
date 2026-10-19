## Networking autoload: ENet server/client, the input map (kept in code so it is version
## controlled) and the lobby protocol (login, character list, enter/leave the world).
## Clients send lobby intents through `request()`; the server answers with `rpc_lobby_reply`.
extends Node

const DEFAULT_PORT := 7777
const MAX_PLAYERS := 32
const AUTOSAVE_SECONDS := 30.0

signal connection_failed
signal server_disconnected
signal character_list(characters: Array)
signal lobby_error(message: String)
signal entered_world

var bot_mode := false # this client is the headless test bot

# server-side
var accounts := {}   # peer -> account name
var entered := {}    # peer -> character name
var _autosave_t := 0.0


func _ready() -> void:
	_setup_input()
	multiplayer.peer_disconnected.connect(_on_peer_left)
	multiplayer.connection_failed.connect(func() -> void: connection_failed.emit())
	multiplayer.server_disconnected.connect(func() -> void: server_disconnected.emit())


# ---------------------------------------------------------------- connection

func host(port: int = DEFAULT_PORT) -> Error:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port, MAX_PLAYERS)
	if err != OK:
		push_error("Failed to create server on port %d: %s" % [port, error_string(err)])
		return err
	multiplayer.multiplayer_peer = peer
	print("[Net] Hosting on port %d" % port)
	return OK


func join(ip: String, port: int = DEFAULT_PORT) -> Error:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(ip, port)
	if err != OK:
		push_error("Failed to create client for %s:%d: %s" % [ip, port, error_string(err)])
		return err
	multiplayer.multiplayer_peer = peer
	print("[Net] Connecting to %s:%d" % [ip, port])
	return OK


func is_server() -> bool:
	return multiplayer.multiplayer_peer != null and multiplayer.is_server()


## Drop the connection and forget every session (Log out; the scene reloads afterwards).
func reset() -> void:
	if is_server():
		for p in get_tree().get_nodes_in_group("players"):
			save_player(p)
	if multiplayer.multiplayer_peer:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	accounts.clear()
	entered.clear()
	bot_mode = false


# ---------------------------------------------------------------- input map

func _setup_input() -> void:
	const KEYS := {
		"move_forward": [KEY_W, KEY_UP], "move_back": [KEY_S, KEY_DOWN],
		"strafe_left": [KEY_A], "strafe_right": [KEY_D],
		"turn_left": [KEY_LEFT], "turn_right": [KEY_RIGHT],
		"jump": [KEY_SPACE], "target_next": [KEY_TAB], "escape": [KEY_ESCAPE], "interact": [KEY_F],
		"toggle_inventory": [KEY_I, KEY_B], "toggle_character": [KEY_C],
		"ability_1": [KEY_1], "ability_2": [KEY_2], "ability_3": [KEY_3], "ability_4": [KEY_4], "ability_5": [KEY_5],
	}
	for action in KEYS:
		if not InputMap.has_action(action):
			InputMap.add_action(action)
		for keycode in KEYS[action]:
			var ev := InputEventKey.new()
			ev.physical_keycode = keycode
			InputMap.action_add_event(action, ev)


# ---------------------------------------------------------------- lobby

## Client -> server. actions: login(account), create(name, class), delete(name), enter(name), leave().
func request(action: String, args: Array = []) -> void:
	if is_server():
		_handle(multiplayer.get_unique_id(), action, args)
	else:
		rpc_lobby.rpc_id(1, action, args)


@rpc("any_peer", "call_remote", "reliable")
func rpc_lobby(action: String, args: Array) -> void:
	if is_server():
		_handle(multiplayer.get_remote_sender_id(), action, args)


## Server -> client. kinds: characters(list), error(message), entered().
@rpc("authority", "call_remote", "reliable")
func rpc_lobby_reply(kind: String, args: Array) -> void:
	match kind:
		"characters": character_list.emit(args[0])
		"error": lobby_error.emit(args[0])
		"entered": entered_world.emit()


func _reply(peer: int, kind: String, args: Array = []) -> void:
	if peer == multiplayer.get_unique_id():
		rpc_lobby_reply(kind, args) # the host is its own client
	else:
		rpc_lobby_reply.rpc_id(peer, kind, args)


func _handle(peer: int, action: String, args: Array) -> void:
	match action:
		"login":
			var acc := Persistence.sanitize(str(args[0]))
			if acc.length() < 2:
				_reply(peer, "error", ["Account name must be at least 2 letters or digits."])
				return
			accounts[peer] = acc
			_send_list(peer)
		"create":
			if not accounts.has(peer):
				return
			var acc: String = accounts[peer]
			var cname := Persistence.sanitize(str(args[0]))
			var class_id := str(args[1])
			if cname.length() < 2:
				_reply(peer, "error", ["Character name must be at least 2 letters or digits."])
			elif not GameData.CLASSES.has(class_id):
				return
			elif Persistence.exists(acc, cname):
				_reply(peer, "error", ["You already have a character called %s." % cname])
			elif Persistence.list_characters(acc).size() >= Persistence.MAX_CHARACTERS:
				_reply(peer, "error", ["Character limit reached."])
			else:
				Persistence.save_character(acc, cname, Persistence.new_character(cname, class_id))
				_send_list(peer)
		"delete":
			if accounts.has(peer) and not entered.has(peer):
				Persistence.delete_character(accounts[peer], str(args[0]))
				_send_list(peer)
		"enter":
			if not accounts.has(peer) or entered.has(peer):
				return
			var data := Persistence.load_character(accounts[peer], str(args[0]))
			if data.is_empty():
				_reply(peer, "error", ["No such character."])
				return
			entered[peer] = data.name
			_world().server_add_player(peer, data)
			_reply(peer, "entered")
		"leave":
			if not accounts.has(peer) or not entered.has(peer):
				return
			var p: Node = _world().get_player(peer)
			if p:
				save_player(p)
				_world().server_remove_player(peer)
			entered.erase(peer)
			_send_list(peer)


func _send_list(peer: int) -> void:
	_reply(peer, "characters", [Persistence.list_characters(accounts[peer])])


func _world() -> Node:
	return get_tree().get_first_node_in_group("world")


# ---------------------------------------------------------------- saving

## Server: write a player's current state to disk.
func save_player(p: Node) -> void:
	var acc: String = accounts.get(p.peer_id, "")
	if acc != "":
		Persistence.save_character(acc, p.char_name, p.save_data())


func _on_peer_left(peer: int) -> void:
	if not is_server():
		return
	var w := _world()
	var p: Node = w.get_player(peer) if w else null
	if p:
		save_player(p)
	accounts.erase(peer)
	entered.erase(peer)


func _process(delta: float) -> void:
	if not is_server():
		return
	_autosave_t += delta
	if _autosave_t >= AUTOSAVE_SECONDS:
		_autosave_t = 0.0
		for p in get_tree().get_nodes_in_group("players"):
			save_player(p)
