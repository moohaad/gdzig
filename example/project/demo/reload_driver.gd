@tool
extends SceneTree
##
## Drives a GDExtension reload and checks what survived it.
##
## GDScript, not a Zig test: reloading unloads the library, so anything
## asserting from inside it is unloaded mid-assertion. Editor mode, because
## `reload_extension` answers "GDExtension reloading is disabled" anywhere else.
##
##   godot --headless --editor --script res://demo/reload_driver.gd

const EXT := "res://example.gdextension"

var failures := 0

func check(ok: bool, what: String) -> void:
	print(("  ok   " if ok else "  FAIL ") + what)
	if not ok:
		failures += 1

func _initialize() -> void:
	var node: Object = ClassDB.instantiate("ConfigNode")
	check(node != null, "ConfigNode instantiates")
	if node == null:
		quit(1)
		return

	node.startup_delay = 3.5
	check(node.startup_delay == 3.5, "exported property takes a value")

	var before_count: int = Performance.get_monitor(Performance.OBJECT_COUNT)

	var status := GDExtensionManager.reload_extension(EXT)
	check(status == GDExtensionManager.LOAD_STATUS_OK, "reload reports OK")

	check(is_instance_valid(node), "the instance survived")
	if is_instance_valid(node):
		check(node.get_class() == "ConfigNode", "kept its class, not degraded to the base")
		check(node.startup_delay == 3.5, "exported property survived the reload")

	var after_count: int = Performance.get_monitor(Performance.OBJECT_COUNT)
	print("  info object count %d -> %d" % [before_count, after_count])
	print("DRIVER failures=%d" % failures)

	# Known broken, and reported after the summary so the summary survives it:
	# freeing a reloaded instance trips gdzig's own dispatch guard --
	#   "object freed while one of its methods was still running"
	# -- on an instance that is not dispatching. The instance binding carries
	# state from before the reload. Re-enable when that is fixed; until then the
	# node is deliberately leaked, which the count above shows.
	const FREE_AFTER_RELOAD_WORKS := false
	if FREE_AFTER_RELOAD_WORKS and is_instance_valid(node):
		node.free()

	quit(1 if failures > 0 else 0)
