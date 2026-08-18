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

	# Splits "reload broke freeing" from "reload broke instances that survived it":
	# a node created after the reload has a binding minted by the new library.
	var fresh: Object = ClassDB.instantiate("ConfigNode")
	check(fresh != null, "instantiates after the reload")
	if fresh != null:
		fresh.free()
		print("  ok   freeing a post-reload instance")

	# Three more cycles. One reload cannot catch an over-release of the interned
	# name cache: the damage lands on the *next* init, when a name that was
	# dropped too far is interned again.
	for i in range(3):
		var again := GDExtensionManager.reload_extension(EXT)
		check(again == GDExtensionManager.LOAD_STATUS_OK, "reload %d of 3 reports OK" % (i + 1))
		var spun: Object = ClassDB.instantiate("ConfigNode")
		check(spun != null, "class still usable after reload %d" % (i + 1))
		if spun != null:
			spun.startup_delay = 1.25
			check(spun.startup_delay == 1.25, "property round-trips after reload %d" % (i + 1))
			spun.free()

	check(is_instance_valid(node), "survivor still valid before free")
	if is_instance_valid(node):
		node.free()
		print("  ok   freeing an instance that survived the reload")

	print("DRIVER failures=%d" % failures)
	quit(1 if failures > 0 else 0)
