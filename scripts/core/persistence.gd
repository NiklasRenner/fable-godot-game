## Server-side character storage: one JSON file per character under user://saves/<account>/.
## Accounts are just names for now (no passwords); characters are what gets saved.
extends Node

const DIR := "user://saves"
const MAX_NAME := 16
const MAX_CHARACTERS := 6


static func sanitize(name: String) -> String:
	var out := ""
	for ch in name.strip_edges():
		if (ch >= "a" and ch <= "z") or (ch >= "A" and ch <= "Z") or (ch >= "0" and ch <= "9") or ch == "_":
			out += ch
	return out.substr(0, MAX_NAME)


func _account_dir(account: String) -> String:
	return "%s/%s" % [DIR, sanitize(account).to_lower()]


func _path(account: String, name: String) -> String:
	return "%s/%s.json" % [_account_dir(account), sanitize(name).to_lower()]


func list_characters(account: String) -> Array:
	var out := []
	var dir := DirAccess.open(_account_dir(account))
	if dir == null:
		return out
	for f in dir.get_files():
		if not f.ends_with(".json"):
			continue
		var data := load_character(account, f.get_basename())
		if not data.is_empty():
			out.append({"name": data.get("name", f.get_basename()), "class": data.get("class", "warrior"),
				"level": int(data.get("level", 1))})
	out.sort_custom(func(a, b): return a.name.to_lower() < b.name.to_lower())
	return out


func exists(account: String, name: String) -> bool:
	return FileAccess.file_exists(_path(account, name))


func load_character(account: String, name: String) -> Dictionary:
	var path := _path(account, name)
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	if parsed is Dictionary:
		return _fix_types(parsed)
	push_warning("Corrupt save: " + path)
	return {}


func save_character(account: String, name: String, data: Dictionary) -> bool:
	var adir := _account_dir(account)
	DirAccess.make_dir_recursive_absolute(adir)
	var path := _path(account, name)
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		push_error("Cannot write save: " + path)
		return false
	f.store_string(JSON.stringify(data, "  "))
	f.close()
	# Atomic-ish replace so a crash mid-write never leaves a half file.
	var d := DirAccess.open(adir)
	if d.file_exists(path.get_file()):
		d.remove(path.get_file())
	d.rename(tmp.get_file(), path.get_file())
	return true


func delete_character(account: String, name: String) -> void:
	var path := _path(account, name)
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)


## A brand-new character's save (the player fills in gear etc. on first spawn).
static func new_character(name: String, class_id: String) -> Dictionary:
	return {"name": name, "class": class_id, "level": 1, "xp": 0, "fresh": true,
		"created": Time.get_datetime_string_from_system()}


## JSON turns ints into floats; put the ones we care about back.
static func _fix_types(d: Dictionary) -> Dictionary:
	for k in ["level", "xp", "health", "resource", "copper"]:
		if d.has(k):
			d[k] = int(d[k])
	if d.has("inventory"):
		for slot in d.inventory:
			slot["n"] = int(slot.get("n", 0))
	if d.has("quests"):
		for qid in d.quests:
			var prog: Array = d.quests[qid].get("progress", [])
			for i in range(prog.size()):
				prog[i] = int(prog[i])
	return d
