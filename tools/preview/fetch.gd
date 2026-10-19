## Dev helper: downloads URLs to files using the engine's own HTTP client (useful for Meshy outputs
## that are only handed out as links). Reads res://fetch.request: pairs of lines, a URL then its
## destination path, as many pairs as needed. Run this scene; it downloads them in turn and quits.
extends Node


func _ready() -> void:
	var lines := Array(FileAccess.get_file_as_string("res://fetch.request").split("\n")).map(func(l): return l.strip_edges()).filter(func(l): return l != "")
	var http := HTTPRequest.new()
	add_child(http)
	for i in range(0, lines.size() - 1, 2):
		var dest := ProjectSettings.globalize_path(lines[i + 1])
		DirAccess.make_dir_recursive_absolute(dest.get_base_dir())
		http.download_file = dest
		if http.request(lines[i]) != OK:
			print("[fetch] request failed: %s" % lines[i + 1])
			continue
		var res: Array = await http.request_completed
		print("[fetch] result %d, HTTP %d -> %s (%d bytes)" % [res[0], res[1], dest, FileAccess.get_file_as_bytes(dest).size()])
	get_tree().quit()
