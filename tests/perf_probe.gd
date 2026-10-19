## Prints physics/process time per frame once a second. Enabled with THORNHILL_PERF=1 (main.gd).
extends Node

var _t := 0.0
var _frames := 0


func _process(delta: float) -> void:
	_t += delta
	_frames += 1
	if _t < 1.0:
		return
	print("[perf] fps=%d physics=%.2fms process=%.2fms nodes=%d" % [_frames,
		Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
		Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
		Performance.get_monitor(Performance.OBJECT_NODE_COUNT)])
	_t = 0.0
	_frames = 0
