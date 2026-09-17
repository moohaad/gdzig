@tool
extends EditorPlugin

var failures := 0

func _enter_tree() -> void:
	_run.call_deferred()
	get_tree().create_timer(90.0).timeout.connect(func():
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
	check(panel_plugin.zig_highlighter._get_supported_languages().has("zig"), "native Script Editor highlighter targets Zig files")
	check(panel_plugin.source_view.syntax_highlighter != panel_plugin.zig_highlighter, "each editor has its own Zig highlighter instance")
	panel_plugin.source_view.text = "pub const answer: u32 = 42; // comment"
	var colors: Dictionary = panel_plugin.source_view.syntax_highlighter.get_line_syntax_highlighting(0)
	check(colors.has(0) and colors.has(3) and colors.has(4), "Zig keywords receive distinct color spans")
	check(colors.has(24), "Zig numbers receive a color span")
	check(colors.has(28), "Zig comments receive a color span")
	check(not panel_plugin.build_before_play.button_pressed, "build-before-play defaults off")
	check(EditorInterface.has_method("popup_create_dialog"), "Godot Create Node dialog is available")
	check(panel_plugin.selected_node_base == "Node", "Node is the default Zig base")
	check(panel_plugin._valid_native_node_base("AnimationPlayer"), "live Godot Node class is accepted")
	check(not panel_plugin._valid_native_node_base("RefCounted"), "non-Node class is rejected")
	panel_plugin._node_base_selected("AnimationPlayer")
	check(panel_plugin.selected_node_base == "AnimationPlayer" and panel_plugin.base_button.text.contains("AnimationPlayer"), "Create Node selection updates the Zig base")
	panel_plugin._node_base_selected("RefCounted")
	check(panel_plugin.selected_node_base == "AnimationPlayer", "invalid base selection retains the previous Node")
	panel_plugin._node_base_selected("")
	check(panel_plugin.selected_node_base == "AnimationPlayer", "canceling the Create Node dialog retains the Node")
	check(panel_plugin._with_zig_extension("txt,md") == "txt,md,zig", "native Zig text extension is appended")
	check(panel_plugin._with_zig_extension("txt, .ZIG ,md") == "txt, .ZIG ,md", "native Zig text extension is not duplicated")
	check(panel_plugin._build(), "disabled play hook allows Play")
	var parser = load("res://addons/gdzig/diagnostics.gd")
	var parsed: Dictionary = parser.parse("C:\\game with spaces\\src\\Player.zig:12:3: error: broken", "/unused")
	check(parsed.path == "C:/game with spaces/src/Player.zig" and parsed.line == 12, "Windows diagnostic path")
	parsed = parser.parse("\u001b[31msrc/Player.zig:2:4: note: declared here\u001b[0m", "/game")
	check(parsed.path == "/game/src/Player.zig" and parsed.severity == "note", "relative ANSI diagnostic")
	check(parser.parse("error: build failed", "/game").is_empty(), "unlocated output remains raw")
	check(panel_plugin._source_arguments({"path": "C:/game with spaces/src/Player.zig", "line": 12, "column": 3}) == PackedStringArray(["--goto", "C:/game with spaces/src/Player.zig:12:3"]), "external editor receives unsplit path and exact location")
	panel_plugin._doctor()
	check(panel_plugin.runner.busy(), "Doctor launched")
	check(panel_plugin.action_buttons[0].disabled, "buttons disabled during command")
	while panel_plugin.runner.busy():
		await get_tree().process_frame
	check(panel_plugin.log_view.text.contains("gdzig doctor"), "CLI diagnostic captured")
	check(panel_plugin.log_view.text.contains("summary:"), "complete doctor output captured")
	check(panel_plugin.status.text.begins_with("Failed"), "failed doctor not reported successful")
	check(not panel_plugin.action_buttons[0].disabled, "buttons restored")
	print("gdzig editor: Doctor checked; testing Build")
	panel_plugin._build_extension()
	check(panel_plugin.runner.busy(), "Build launched")
	while panel_plugin.runner.busy():
		await get_tree().process_frame
	check(panel_plugin.status.text == "Succeeded", "actual Zig build succeeded")
	if panel_plugin.status.text != "Succeeded":
		printerr(panel_plugin.log_view.text)
	panel_plugin.build_before_play.set_pressed_no_signal(true)
	check(panel_plugin._build(), "successful pre-play build permits Play")
	var build_path: String = panel_plugin.build_root.text.path_join("build.zig")
	var original_build := FileAccess.get_file_as_string(build_path)
	var broken_build := FileAccess.open(build_path, FileAccess.WRITE)
	broken_build.store_string(original_build + "\nthis is not valid Zig;\n")
	broken_build.close()
	check(not panel_plugin._build(), "compiler failure blocks Play")
	check(panel_plugin.diagnostics.item_count > 0, "actual compiler error is clickable")
	if panel_plugin.diagnostics.item_count > 0:
		panel_plugin._open_diagnostic(0)
		var location: Dictionary = panel_plugin.diagnostics.get_item_metadata(0)
		check(panel_plugin.source_view.get_caret_line() == location.line - 1, "source editor opens correct line")
		check(panel_plugin.source_view.editable, "project Zig diagnostic is editable")
		panel_plugin.source_window.hide()
	var restored_build := FileAccess.open(build_path, FileAccess.WRITE)
	restored_build.store_string(original_build)
	restored_build.close()
	check(panel_plugin.runner.start(OS.get_executable_path(), PackedStringArray(["--version"])), "busy-hook probe starts")
	check(not panel_plugin._build(), "busy runner blocks Play")
	while panel_plugin.runner.busy():
		await get_tree().process_frame
	panel_plugin.build_before_play.set_pressed_no_signal(false)
	panel_plugin.class_name_input.text = "EditorProbe"
	panel_plugin._generate()
	while panel_plugin.runner.busy():
		await get_tree().process_frame
	check(panel_plugin.status.text == "Succeeded", "class generation succeeded")
	check(FileAccess.file_exists(panel_plugin.build_root.text.path_join("src/EditorProbe.zig")), "class file created in build root")
	check(FileAccess.get_file_as_string(panel_plugin.build_root.text.path_join("src/EditorProbe.zig")).contains("*godot.class.AnimationPlayer"), "selected live base reaches generated Zig class")
	print("gdzig editor: testing Zig source editing")
	panel_plugin._show_sources()
	check(panel_plugin.source_files.item_count >= 2, "source browser lists build.zig and src files")
	check(not panel_plugin._valid_source_name("../Escape.zig") and panel_plugin._valid_source_name("Clouds.zig"), "new filenames are constrained to src")
	panel_plugin.source_name.text = "EditorSourceProbe.zig"
	panel_plugin._new_source()
	var source_path: String = panel_plugin.build_root.text.path_join("src/EditorSourceProbe.zig")
	check(FileAccess.file_exists(source_path), "new Zig file created")
	check(panel_plugin.source_path == source_path and panel_plugin.source_view.editable, "new file opens editable")
	panel_plugin.source_view.text += "pub const answer = 42;\n"
	panel_plugin._source_changed()
	check(panel_plugin.source_dirty, "edit marks source dirty")
	panel_plugin._close_sources()
	check(panel_plugin.source_window.visible, "dirty source cannot close silently")
	panel_plugin._open_source(build_path, 1, 1)
	check(panel_plugin.source_path == source_path, "dirty source cannot be replaced silently")
	check(panel_plugin._save_source(), "source save succeeds")
	check(FileAccess.get_file_as_string(source_path).contains("answer = 42"), "saved Zig edits reach disk")
	panel_plugin.source_view.text += "pub const draft = true;\n"
	panel_plugin._source_changed()
	var external_change := FileAccess.open(source_path, FileAccess.WRITE)
	external_change.store_string("// changed externally\n")
	external_change.close()
	check(not panel_plugin._save_source(), "external edits prevent overwrite")
	check(FileAccess.get_file_as_string(source_path) == "// changed externally\n", "external content preserved")
	panel_plugin._discard_source()
	panel_plugin._open_source(source_path, 1, 1)
	check(panel_plugin.source_view.text == "// changed externally\n", "reopen loads external edits")
	panel_plugin.source_view.text += "// draft survives plugin reload\n"
	panel_plugin._source_changed()
	print("gdzig editor: Build and Generate checked; testing process lifecycle")
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
	var restored = get_tree().get_first_node_in_group("gdzig_editor_plugin")
	check(restored.source_dirty and restored.source_view.text.contains("draft survives plugin reload"), "unsaved Zig draft restored after plugin reload")
	restored._discard_source()
	print("gdzig editor integration: %d failures" % failures)
	var result := FileAccess.open("res://.godot/gdzig-test-result", FileAccess.WRITE)
	result.store_string(str(failures))
	result.close()
	get_tree().quit(0 if failures == 0 else 1)
