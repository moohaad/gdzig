@tool
extends EditorPlugin

const Runner = preload("process.gd")
const CONFIG := "res://.godot/gdzig-editor.cfg"
var runner: Node
var panel: VBoxContainer
var log_view: TextEdit
var executable: LineEdit
var build_root: LineEdit
var build_args: TextEdit
var class_name_input: LineEdit
var base_input: LineEdit
var kind_input: OptionButton
var action_buttons: Array[Button] = []
var status: Label

func _enter_tree() -> void:
	add_to_group("gdzig_editor_plugin")
	runner = Runner.new()
	# Lifetime is independent of the panel while a command is running.
	EditorInterface.get_base_control().add_child(runner)
	runner.output.connect(_append_output)
	runner.finished.connect(_finished)
	panel = VBoxContainer.new()
	panel.custom_minimum_size = Vector2(0, 260)
	executable = _field("gdzig executable (PATH name or absolute path)", "gdzig")
	var root := ProjectSettings.globalize_path("res://")
	if not FileAccess.file_exists(root.path_join("build.zig")) and FileAccess.file_exists(root.path_join("../build.zig")):
		root = root.path_join("..").simplify_path()
	build_root = _field("Directory containing build.zig", root)
	var label := Label.new()
	label.text = "Build options: one argument per line, without shell quotes. The current Godot executable is selected automatically."
	panel.add_child(label)
	build_args = TextEdit.new()
	build_args.custom_minimum_size.y = 48
	build_args.text = "-j2"
	panel.add_child(build_args)
	var row := HBoxContainer.new()
	panel.add_child(row)
	_button(row, "Build", _build_extension)
	_button(row, "Doctor", _doctor)
	_button(row, "Save settings", _save)
	kind_input = OptionButton.new()
	for kind in ["node", "resource", "plugin"]:
		kind_input.add_item(kind)
	row.add_child(kind_input)
	class_name_input = LineEdit.new()
	class_name_input.placeholder_text = "ClassName"
	row.add_child(class_name_input)
	base_input = LineEdit.new()
	base_input.placeholder_text = "Node base (optional)"
	row.add_child(base_input)
	_button(row, "Generate class", _generate)
	status = Label.new()
	status.text = "Ready. Commands run only when clicked; build before playing."
	panel.add_child(status)
	log_view = TextEdit.new()
	log_view.editable = false
	log_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	log_view.custom_minimum_size.y = 120
	panel.add_child(log_view)
	var config := ConfigFile.new()
	if config.load(CONFIG) == OK:
		executable.text = str(config.get_value("tools", "executable", executable.text))
		build_root.text = str(config.get_value("tools", "build_root", build_root.text))
		build_args.text = str(config.get_value("tools", "build_args", build_args.text))
	add_control_to_bottom_panel(panel, "gdzig")
	add_tool_menu_item("gdzig", _show_panel)

func _field(label_text: String, value: String) -> LineEdit:
	var row := HBoxContainer.new()
	panel.add_child(row)
	var label := Label.new()
	label.text = label_text
	row.add_child(label)
	var input := LineEdit.new()
	input.text = value
	input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(input)
	return input

func _button(row: HBoxContainer, title: String, action: Callable) -> void:
	var button := Button.new()
	button.text = title
	button.pressed.connect(action)
	row.add_child(button)
	action_buttons.append(button)

func _show_panel() -> void:
	make_bottom_panel_item_visible(panel)

func _save() -> void:
	var config := ConfigFile.new()
	config.set_value("tools", "executable", executable.text)
	config.set_value("tools", "build_root", build_root.text)
	config.set_value("tools", "build_args", build_args.text)
	var err := config.save(CONFIG)
	if err != OK:
		_append_output("Could not save settings: %s\n" % error_string(err))

func _build_extension() -> void:
	var args := PackedStringArray(["build"])
	for line in build_args.text.split("\n", false):
		var arg := line.strip_edges()
		if arg.is_empty():
			continue
		if arg == "--" or not arg.begins_with("-") or arg.begins_with("-Dgodot-"):
			_append_output("Use only Zig build options, one per line; Godot is selected by the editor.\n")
			return
		args.append(arg)
	args.append("-Dgodot-path=" + OS.get_executable_path())
	_start(args)

func _doctor() -> void:
	_start(PackedStringArray(["doctor", "--project", ProjectSettings.globalize_path("res://"), "--godot", OS.get_executable_path()]))

func _generate() -> void:
	var kind := kind_input.get_item_text(kind_input.selected)
	var name_text := class_name_input.text.strip_edges()
	if name_text.is_empty() or name_text.begins_with("-"):
		_append_output("Enter a Zig class name first.\n")
		return
	var args := PackedStringArray(["add", kind, name_text])
	if kind == "node" and not base_input.text.strip_edges().is_empty():
		args.append_array(["--base", base_input.text.strip_edges()])
	_start(args)

func _start(args: PackedStringArray) -> void:
	if runner.busy():
		return
	var root := build_root.text.strip_edges()
	if not root.is_absolute_path() or not FileAccess.file_exists(root.path_join("build.zig")):
		_append_output("Choose an absolute build directory containing build.zig.\n")
		return
	_save()
	var command := PackedStringArray(["-C", root])
	command.append_array(args)
	_append_output("\n> gdzig %s\n" % str(command))
	_show_panel()
	if not runner.start(executable.text.strip_edges(), command):
		_append_output("Could not start gdzig. Set the executable's absolute path and check permissions.\n")
		return
	status.text = "Running %s…" % args[0]
	for button in action_buttons:
		button.disabled = true

func _append_output(text: String) -> void:
	# Plain text: compiler output is never interpreted as markup or commands.
	log_view.text = (log_view.text + text).right(262144)
	log_view.set_caret_line(log_view.get_line_count() - 1)

func _finished(code: int) -> void:
	status.text = "Succeeded" if code == 0 else "Failed (exit %d); see output below" % code
	_append_output("\n[exit %d]\n" % code)
	for button in action_buttons:
		button.disabled = false
	if code == 0:
		EditorInterface.get_resource_filesystem().scan()

func _exit_tree() -> void:
	remove_tool_menu_item("gdzig")
	remove_control_from_bottom_panel(panel)
	panel.queue_free()
	runner.output.disconnect(_append_output)
	runner.finished.disconnect(_finished)
	if runner.busy():
		push_warning("gdzig command is still running. Disabling the panel does not cancel it; wait before closing the editor.")
	runner.release()
