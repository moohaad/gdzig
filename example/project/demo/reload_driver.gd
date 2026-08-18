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

	# Everything above reloads the same binary. That proves the machinery is
	# sound, not that a rebuild is picked up -- which is the whole point of the
	# feature. `build_tag` is baked into the code, so a stale library keeps
	# answering 1 no matter how cleanly it reloaded.
	var probe: Object = ClassDB.instantiate("ConfigNode")
	if probe != null:
		check(probe.build_tag() == 1, "starts on the old build")
		probe.free()

	var live := ProjectSettings.globalize_path("res://lib/example.dll")
	var staged := ProjectSettings.globalize_path("res://lib/next.dll")

	# Staging a second build cannot be done from here, so this half runs only
	# when one has been put in place. To make it, from `example/`:
	#
	#   sed -i 's/return 1;/return 2;/' src/ConfigNode.zig
	#   zig build && cp project/lib/example.dll project/lib/next.dll
	#   sed -i 's/return 2;/return 1;/' src/ConfigNode.zig && zig build
	#
	# then `zig build reload-test`.
	if not FileAccess.file_exists("res://lib/next.dll"):
		print("  skip no lib/next.dll staged; the changed-code half did not run")
	else:
		var copied := DirAccess.copy_absolute(staged, live)
		check(copied == OK, "the live library can be replaced on disk (err=%d)" % copied)

		var after_swap := GDExtensionManager.reload_extension(EXT)
		check(after_swap == GDExtensionManager.LOAD_STATUS_OK, "reload after the swap reports OK")

		var reloaded: Object = ClassDB.instantiate("ConfigNode")
		if reloaded != null:
			var tag: int = reloaded.build_tag()
			check(tag == 2, "the NEW build is the one answering (build_tag=%d)" % tag)
			reloaded.free()

	print("DRIVER failures=%d" % failures)
	quit(1 if failures > 0 else 0)
