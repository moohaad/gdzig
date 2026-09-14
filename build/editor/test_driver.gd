@tool
extends EditorPlugin

var failures := 0

func _enter_tree() -> void:
	_run.call_deferred()
	get_tree().create_timer(30.0).timeout.connect(func():
		printerr("Editor integration test timed out")
		get_tree().quit(1))

func check(value: bool, message: String) -> void:
	if not value:
		failures += 1
		printerr("FAIL: ", message)

func _run() -> void:
	var panel_plugin = get_tree().get_first_node_in_group("gdzig_editor_plugin")
	check(panel_plugin != null, "addon enabled")
	if panel_plugin == null:
		get_tree().quit(1)
		return
	check(not panel_plugin.runner.busy(), "enabling does not launch commands")
	panel_plugin._doctor()
	check(panel_plugin.runner.busy(), "Doctor launched")
	check(panel_plugin.action_buttons[0].disabled, "buttons disabled during command")
	while panel_plugin.runner.busy():
		await get_tree().process_frame
	check(panel_plugin.log_view.text.contains("gdzig doctor"), "CLI diagnostic captured")
	check(panel_plugin.log_view.text.contains("summary:"), "complete doctor output captured")
	check(panel_plugin.status.text.begins_with("Failed"), "failed doctor not reported successful")
	check(not panel_plugin.action_buttons[0].disabled, "buttons restored")
	var runner = load("res://addons/gdzig/process.gd").new()
	add_child(runner)
	var output := [""]
	var codes := []
	runner.output.connect(func(text: String): output[0] += text)
	runner.finished.connect(func(code: int): codes.append(code))
	check(runner.start(OS.get_executable_path(), PackedStringArray(["--version"])), "success command starts")
	check(not runner.start(OS.get_executable_path(), PackedStringArray(["--version"])), "concurrent job rejected")
	while runner.busy():
		await get_tree().process_frame
	check(codes == [0], "success exit code")
	check(output[0].contains("4.7"), "stdout captured")
	output[0] = ""
	codes.clear()
	check(runner.start(OS.get_executable_path(), PackedStringArray(["--headless", "--path", ProjectSettings.globalize_path("res://"), "--script", "res://test_job.gd"])), "failing command starts")
	while runner.busy():
		await get_tree().process_frame
	check(codes == [7], "nonzero exit code retained")
	check(output[0].contains("stdout marker") and output[0].contains("stderr marker"), "both pipes drained")
	check(output[0].contains("last marker"), "output drained through end")
	check(runner.start(OS.get_executable_path(), PackedStringArray(["--version"])), "detached command starts")
	runner.release()
	while is_instance_valid(runner):
		await get_tree().process_frame
	# Exercise symmetric enable/disable cleanup of controls and menu entry.
	EditorInterface.set_plugin_enabled("gdzig", false)
	await get_tree().process_frame
	check(get_tree().get_first_node_in_group("gdzig_editor_plugin") == null, "plugin removed")
	EditorInterface.set_plugin_enabled("gdzig", true)
	await get_tree().process_frame
	check(get_tree().get_nodes_in_group("gdzig_editor_plugin").size() == 1, "plugin re-enabled once")
	print("gdzig editor integration: %d failures" % failures)
	var result := FileAccess.open("res://.godot/gdzig-test-result", FileAccess.WRITE)
	result.store_string(str(failures))
	result.close()
	get_tree().quit(0 if failures == 0 else 1)
