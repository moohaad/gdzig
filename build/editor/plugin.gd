@tool
extends EditorPlugin

const Runner = preload("process.gd")
const Diagnostics = preload("diagnostics.gd")
const ZigHighlighter = preload("zig_highlighter.gd")
const CONFIG := "res://.godot/gdzig-editor.cfg"
const SOURCE_DRAFT := "res://.godot/gdzig-source-draft.cfg"
const TEXTFILE_EXTENSIONS := "docks/filesystem/textfile_extensions"
var runner: Node
var panel: VBoxContainer
var log_view: TextEdit
var executable: LineEdit
var build_root: LineEdit
var build_args: TextEdit
var class_name_input: LineEdit
var base_button: Button
var selected_node_base := "Node"
var kind_input: OptionButton
var action_buttons: Array[Button] = []
var status: Label
var diagnostics: ItemList
var diagnostic_pending := ""
var command_root := ""
var source_window: Window
var source_view: CodeEdit
var zig_highlighter: EditorSyntaxHighlighter
var source_files: ItemList
var source_name: LineEdit
var source_path := ""
var source_original := ""
var source_dirty := false
var source_loading := false
var source_read_only := false
var build_before_play: CheckBox
var synchronous_build := false
var source_editor: LineEdit
var source_editor_args: TextEdit

func _enter_tree() -> void:
	add_to_group("gdzig_editor_plugin")
	runner = get_tree().get_first_node_in_group("gdzig_editor_runner")
	if runner == null or runner.is_queued_for_deletion():
		runner = Runner.new()
		# Lifetime is independent of the panel while a command is running.
		EditorInterface.get_base_control().add_child(runner)
		runner.add_to_group("gdzig_editor_runner")
	runner.release_when_done = false
	runner.output.connect(_append_output)
	runner.finished.connect(_finished)
	zig_highlighter = ZigHighlighter.new()
	EditorInterface.get_script_editor().register_syntax_highlighter(zig_highlighter)
	panel = VBoxContainer.new()
	panel.custom_minimum_size = Vector2(0, 260)
	executable = _field("gdzig executable (PATH name or absolute path)", "gdzig")
	var root := ProjectSettings.globalize_path("res://")
	if not FileAccess.file_exists(root.path_join("build.zig")) and FileAccess.file_exists(root.path_join("../build.zig")):
		root = root.path_join("..").simplify_path()
	build_root = _field("Directory containing build.zig", root)
	source_editor = _field("External source editor (optional; blank uses built-in Zig editor)", "")
	var editor_label := Label.new()
	editor_label.text = "Source editor arguments: one per line; {file}, {line}, {column}. Defaults below suit VS Code."
	panel.add_child(editor_label)
	source_editor_args = TextEdit.new()
	source_editor_args.custom_minimum_size.y = 40
	source_editor_args.text = "--goto\n{file}:{line}:{column}"
	panel.add_child(source_editor_args)
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
	_button(row, "Zig files", _show_sources)
	_button(row, "Enable .zig in Script Editor", _enable_native_source_editor)
	kind_input = OptionButton.new()
	for kind in ["node", "resource", "plugin"]:
		kind_input.add_item(kind)
	row.add_child(kind_input)
	kind_input.item_selected.connect(_kind_changed)
	class_name_input = LineEdit.new()
	class_name_input.placeholder_text = "ClassName"
	row.add_child(class_name_input)
	base_button = Button.new()
	base_button.text = "Base: Node…"
	base_button.tooltip_text = "Choose a native Node base using Godot's Create Node dialog"
	base_button.custom_minimum_size.x = 190
	base_button.pressed.connect(_choose_node_base)
	row.add_child(base_button)
	_button(row, "Generate class", _generate)
	status = Label.new()
	status.text = "Ready. Commands run only when clicked; build before playing."
	panel.add_child(status)
	build_before_play = CheckBox.new()
	build_before_play.text = "Build before Play (waits for compilation; blocks Play on failure)"
	panel.add_child(build_before_play)
	build_before_play.toggled.connect(func(_enabled: bool): _save())
	diagnostics = ItemList.new()
	diagnostics.custom_minimum_size.y = 80
	diagnostics.item_selected.connect(_open_diagnostic)
	panel.add_child(diagnostics)
	source_window = Window.new()
	source_window.size = Vector2i(1100, 650)
	source_window.close_requested.connect(_close_sources)
	panel.add_child(source_window)
	var source_layout := VBoxContainer.new()
	source_layout.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	source_window.add_child(source_layout)
	var source_toolbar := HBoxContainer.new()
	source_layout.add_child(source_toolbar)
	source_name = LineEdit.new()
	source_name.placeholder_text = "New file name (e.g. Player.zig), created in src/"
	source_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	source_toolbar.add_child(source_name)
	_source_button(source_toolbar, "New", _new_source)
	_source_button(source_toolbar, "Refresh", _refresh_sources)
	_source_button(source_toolbar, "Open", _open_selected_source)
	_source_button(source_toolbar, "Save", _save_source)
	_source_button(source_toolbar, "Discard changes", _discard_source)
	var source_body := HBoxContainer.new()
	source_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	source_layout.add_child(source_body)
	source_files = ItemList.new()
	source_files.custom_minimum_size.x = 250
	source_files.item_activated.connect(_open_selected_source)
	source_body.add_child(source_files)
	source_view = CodeEdit.new()
	source_view.editable = false
	source_view.gutters_draw_line_numbers = true
	source_view.syntax_highlighter = ZigHighlighter.new()
	source_view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	source_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	source_view.text_changed.connect(_source_changed)
	source_body.add_child(source_view)
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
		build_before_play.set_pressed_no_signal(bool(config.get_value("tools", "build_before_play", false)))
		source_editor.text = str(config.get_value("tools", "source_editor", ""))
		source_editor_args.text = str(config.get_value("tools", "source_editor_args", source_editor_args.text))
	_restore_source_draft()
	add_control_to_bottom_panel(panel, "gdzig")
	add_tool_menu_item("gdzig", _show_panel)
	if runner.busy():
		status.text = "Reconnected to running command…"
		for button in action_buttons:
			button.disabled = true

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

func _choose_node_base() -> void:
	EditorInterface.popup_create_dialog(_node_base_selected, &"Node", selected_node_base, "Choose native Node base for Zig class")

func _node_base_selected(engine_class: String) -> void:
	if engine_class.is_empty():
		return
	if not _valid_native_node_base(engine_class):
		_append_output("Choose an instantiable native Node class. Script and custom extension classes cannot be used as Zig bases.\n")
		return
	selected_node_base = engine_class
	base_button.text = "Base: %s…" % engine_class

func _valid_native_node_base(engine_class: String) -> bool:
	return ClassDB.class_exists(engine_class) and ClassDB.class_get_api_type(engine_class) == ClassDB.API_CORE and (engine_class == "Node" or ClassDB.is_parent_class(engine_class, "Node")) and ClassDB.is_class_enabled(engine_class) and ClassDB.can_instantiate(engine_class)

func _kind_changed(index: int) -> void:
	base_button.disabled = kind_input.get_item_text(index) != "node"

func _button(row: HBoxContainer, title: String, action: Callable) -> void:
	var button := Button.new()
	button.text = title
	button.pressed.connect(action)
	row.add_child(button)
	action_buttons.append(button)

func _source_button(row: HBoxContainer, title: String, action: Callable) -> void:
	var button := Button.new()
	button.text = title
	button.pressed.connect(action)
	row.add_child(button)

func _show_sources() -> void:
	if not _valid_build_root():
		return
	_refresh_sources()
	source_window.popup_centered()

func _enable_native_source_editor() -> void:
	var settings := EditorInterface.get_editor_settings()
	var extensions := str(settings.get_setting(TEXTFILE_EXTENSIONS))
	var updated := _with_zig_extension(extensions)
	if updated != extensions:
		settings.set_setting(TEXTFILE_EXTENSIONS, updated)
		EditorInterface.get_resource_filesystem().scan()
	_append_output("Godot now treats .zig as editable text. Double-click a .zig file under res:// in the FileSystem dock to edit it in the Script Editor.\n")

func _with_zig_extension(extensions: String) -> String:
	for extension in extensions.split(",", false):
		if extension.strip_edges().trim_prefix(".").to_lower() == "zig":
			return extensions
	return extensions + ("," if not extensions.strip_edges().is_empty() else "") + "zig"

func _refresh_sources() -> void:
	source_files.clear()
	if not _valid_build_root():
		return
	var root := build_root.text.strip_edges().simplify_path()
	if FileAccess.file_exists(root.path_join("build.zig")):
		_list_source(root.path_join("build.zig"), "build.zig")
	_scan_sources(root.path_join("src"), "src", 0)

func _scan_sources(directory: String, relative: String, depth: int) -> void:
	if depth > 12 or source_files.item_count >= 2000:
		return
	var dir := DirAccess.open(directory)
	if dir == null:
		return
	for file_name in dir.get_files():
		if file_name.ends_with(".zig") and source_files.item_count < 2000:
			_list_source(directory.path_join(file_name), relative.path_join(file_name))
	for subdir in dir.get_directories():
		_scan_sources(directory.path_join(subdir), relative.path_join(subdir), depth + 1)

func _list_source(path: String, relative: String) -> void:
	var index := source_files.add_item(relative)
	source_files.set_item_metadata(index, path)

func _open_selected_source(_index: int = -1) -> void:
	var selected := source_files.get_selected_items()
	if selected.is_empty():
		return
	_open_source(str(source_files.get_item_metadata(selected[0])), 1, 1)

func _new_source() -> void:
	if source_dirty:
		_append_output("Save or discard the current Zig edits before creating another file.\n")
		return
	if not _valid_build_root():
		return
	var name_text := source_name.text.strip_edges()
	if not _valid_source_name(name_text):
		_append_output("Choose a simple .zig filename (letters, digits, and underscores; no path separators).\n")
		return
	var src_dir := build_root.text.strip_edges().simplify_path().path_join("src")
	if not DirAccess.dir_exists_absolute(src_dir):
		_append_output("The build project has no src/ directory.\n")
		return
	var path := src_dir.path_join(name_text)
	if FileAccess.file_exists(path):
		_append_output("Zig file already exists: %s\n" % path)
		return
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_append_output("Could not create Zig file: %s\n" % error_string(FileAccess.get_open_error()))
		return
	file.store_string("// New gdzig source file.\n")
	file.close()
	source_name.clear()
	_refresh_sources()
	_open_source(path, 1, 1)
	EditorInterface.get_resource_filesystem().scan()

func _valid_source_name(name_text: String) -> bool:
	if not name_text.ends_with(".zig") or name_text.length() <= 4:
		return false
	var stem := name_text.substr(0, name_text.length() - 4)
	for i in range(stem.length()):
		var c := stem.unicode_at(i)
		if not ((c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c == 95 or (i > 0 and c >= 48 and c <= 57)):
			return false
	return true

func _editable_source(path: String) -> bool:
	var root := build_root.text.strip_edges().simplify_path().replace("\\", "/")
	var normalized := path.simplify_path().replace("\\", "/")
	return normalized == root.path_join("build.zig") or normalized.begins_with(root.path_join("src") + "/")

func _open_source(path: String, line: int, column: int) -> void:
	if source_dirty and path != source_path:
		_append_output("Save or discard the current Zig edits before opening another file.\n")
		source_window.popup_centered()
		return
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		_append_output("Source no longer exists or is unreadable: %s\n" % path)
		return
	if file.get_length() > 2 * 1024 * 1024:
		_append_output("Source is too large for the built-in editor: %s\n" % path)
		return
	var disk_text := file.get_as_text()
	if source_dirty:
		# Reposition within an already edited buffer without losing its changes.
		source_window.popup_centered()
	else:
		source_loading = true
		source_path = path
		source_original = disk_text
		source_read_only = not _editable_source(path)
		source_view.editable = not source_read_only
		source_view.text = disk_text
		source_dirty = false
		source_loading = false
		_update_source_title()
		source_window.popup_centered()
	source_view.set_caret_line(clampi(line - 1, 0, source_view.get_line_count() - 1))
	source_view.set_caret_column(maxi(column - 1, 0))
	source_view.center_viewport_to_caret()

func _source_changed() -> void:
	if source_loading:
		return
	source_dirty = source_view.text != source_original
	_update_source_title()

func _update_source_title() -> void:
	source_window.title = ("* " if source_dirty else "") + (source_path if not source_path.is_empty() else "Zig files") + (" (read-only)" if source_read_only else "")

func _save_source() -> bool:
	if source_path.is_empty() or source_read_only:
		return false
	if not source_dirty:
		return true
	if not FileAccess.file_exists(source_path) or FileAccess.get_file_as_string(source_path) != source_original:
		_append_output("Zig file changed on disk; refusing to overwrite: %s\n" % source_path)
		return false
	var file := FileAccess.open(source_path, FileAccess.WRITE)
	if file == null:
		_append_output("Could not save Zig file: %s\n" % error_string(FileAccess.get_open_error()))
		return false
	file.store_string(source_view.text)
	file.close()
	source_original = source_view.text
	source_dirty = false
	_update_source_title()
	_clear_source_draft()
	EditorInterface.get_resource_filesystem().scan()
	return true

func _discard_source() -> void:
	if not source_dirty:
		return
	source_loading = true
	source_view.text = source_original
	source_loading = false
	source_dirty = false
	_update_source_title()
	_clear_source_draft()

func _close_sources() -> void:
	if source_dirty:
		_append_output("Zig edits are unsaved. Save or discard them before closing the source window.\n")
		return
	source_window.hide()

func _persist_source_draft() -> void:
	if not source_dirty or source_path.is_empty():
		return
	var draft := ConfigFile.new()
	draft.set_value("source", "path", source_path)
	draft.set_value("source", "original", source_original)
	draft.set_value("source", "text", source_view.text)
	var err := draft.save(SOURCE_DRAFT)
	if err != OK:
		push_warning("Could not preserve unsaved Zig edits: %s" % error_string(err))

func _restore_source_draft() -> void:
	var draft := ConfigFile.new()
	if draft.load(SOURCE_DRAFT) != OK:
		return
	var path := str(draft.get_value("source", "path", ""))
	if path.is_empty() or not _editable_source(path):
		return
	source_loading = true
	source_path = path
	source_original = str(draft.get_value("source", "original", ""))
	source_view.text = str(draft.get_value("source", "text", ""))
	source_view.editable = true
	source_read_only = false
	source_dirty = source_view.text != source_original
	source_loading = false
	_update_source_title()
	if source_dirty:
		_append_output("Restored unsaved Zig edits: %s\n" % path)

func _clear_source_draft() -> void:
	var path := ProjectSettings.globalize_path(SOURCE_DRAFT)
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)

func _show_panel() -> void:
	make_bottom_panel_item_visible(panel)

func _save() -> void:
	var config := ConfigFile.new()
	config.set_value("tools", "executable", executable.text)
	config.set_value("tools", "build_root", build_root.text)
	config.set_value("tools", "build_args", build_args.text)
	config.set_value("tools", "build_before_play", build_before_play.button_pressed)
	config.set_value("tools", "source_editor", source_editor.text)
	config.set_value("tools", "source_editor_args", source_editor_args.text)
	var err := config.save(CONFIG)
	if err != OK:
		_append_output("Could not save settings: %s\n" % error_string(err))

func _build_extension() -> void:
	if source_dirty and not _save_source():
		return
	var args := _build_arguments()
	if not args.is_empty():
		_start(args)

func _build_arguments() -> PackedStringArray:
	var args := PackedStringArray(["build"])
	for line in build_args.text.split("\n", false):
		var arg := line.strip_edges()
		if arg.is_empty():
			continue
		if arg == "--" or not arg.begins_with("-") or arg.begins_with("-Dgodot-"):
			_append_output("Use only Zig build options, one per line; Godot is selected by the editor.\n")
			return PackedStringArray()
		args.append(arg)
	args.append("-Dgodot-path=" + OS.get_executable_path())
	return args

func _build() -> bool:
	# Godot requires an immediate boolean from this hook. Do not replay Play
	# asynchronously: that loses the requested scene/mode and can recurse.
	if not build_before_play.button_pressed:
		return true
	if source_dirty and not _save_source():
		_show_panel()
		return false
	if runner.busy() or synchronous_build:
		_append_output("Play blocked: wait for the current gdzig command to finish.\n")
		_show_panel()
		return false
	var args := _build_arguments()
	if args.is_empty() or not _valid_build_root():
		_show_panel()
		return false
	_save()
	_reset_diagnostics()
	var command := PackedStringArray(["-C", command_root])
	command.append_array(args)
	synchronous_build = true
	status.text = "Building before Play…"
	var output: Array = []
	var code := OS.execute(executable.text.strip_edges(), command, output, true, false)
	synchronous_build = false
	for text in output:
		_append_output(str(text))
	_finished(code)
	if code != 0:
		_show_panel()
		return false
	_append_output("Build passed; continuing the requested Play action. If Godot reports a native reload failure, stop and restart the editor.\n")
	return true

func _doctor() -> void:
	_start(PackedStringArray(["doctor", "--project", ProjectSettings.globalize_path("res://"), "--godot", OS.get_executable_path()]))

func _generate() -> void:
	var kind := kind_input.get_item_text(kind_input.selected)
	var name_text := class_name_input.text.strip_edges()
	if name_text.is_empty() or name_text.begins_with("-"):
		_append_output("Enter a Zig class name first.\n")
		return
	var args := PackedStringArray(["add", kind, name_text])
	if kind == "node":
		if not _valid_native_node_base(selected_node_base):
			_append_output("Choose an instantiable native Node base class.\n")
			return
		args.append_array(["--base", selected_node_base])
	_start(args)

func _start(args: PackedStringArray) -> void:
	if runner.busy() or synchronous_build:
		return
	if not _valid_build_root():
		return
	_save()
	_reset_diagnostics()
	var command := PackedStringArray(["-C", command_root])
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
	diagnostic_pending += text
	var lines := diagnostic_pending.split("\n")
	diagnostic_pending = lines[-1].right(65536)
	for i in range(lines.size() - 1):
		_add_diagnostic(lines[i])

func _valid_build_root() -> bool:
	var root := build_root.text.strip_edges()
	if not root.is_absolute_path() or not FileAccess.file_exists(root.path_join("build.zig")):
		_append_output("Choose an absolute build directory containing build.zig.\n")
		return false
	return true

func _reset_diagnostics() -> void:
	command_root = build_root.text.strip_edges()
	diagnostics.clear()
	diagnostic_pending = ""

func _add_diagnostic(line: String) -> void:
	if diagnostics.item_count >= 500:
		return
	var diagnostic := Diagnostics.parse(line, command_root)
	if diagnostic.is_empty():
		return
	var index := diagnostics.add_item("%s:%d:%d: %s: %s" % [diagnostic.path.get_file(), diagnostic.line, diagnostic.column, diagnostic.severity, diagnostic.message])
	diagnostics.set_item_metadata(index, diagnostic)
	diagnostics.set_item_tooltip(index, "%s:%d:%d" % [diagnostic.path, diagnostic.line, diagnostic.column])

func _open_diagnostic(index: int) -> void:
	var diagnostic: Dictionary = diagnostics.get_item_metadata(index)
	if not source_editor.text.strip_edges().is_empty():
		_save()
		var arguments := _source_arguments(diagnostic)
		if OS.create_process(source_editor.text.strip_edges(), arguments, false) != -1:
			return
		_append_output("Could not start source editor; opening built-in Zig editor instead.\n")
	_open_source(diagnostic.path, diagnostic.line, diagnostic.column)

func _source_arguments(diagnostic: Dictionary) -> PackedStringArray:
	var arguments := PackedStringArray()
	for arg in source_editor_args.text.split("\n", false):
		arguments.append(arg.replace("{file}", diagnostic.path).replace("{line}", str(diagnostic.line)).replace("{column}", str(diagnostic.column)))
	return arguments

func _finished(code: int) -> void:
	_add_diagnostic(diagnostic_pending)
	diagnostic_pending = ""
	status.text = "Succeeded" if code == 0 else "Failed (exit %d); see output below" % code
	_append_output("\n[exit %d]\n" % code)
	for button in action_buttons:
		button.disabled = false
	if code == 0:
		EditorInterface.get_resource_filesystem().scan()

func _exit_tree() -> void:
	_persist_source_draft()
	EditorInterface.get_script_editor().unregister_syntax_highlighter(zig_highlighter)
	remove_tool_menu_item("gdzig")
	remove_control_from_bottom_panel(panel)
	panel.queue_free()
	runner.output.disconnect(_append_output)
	runner.finished.disconnect(_finished)
	if runner.busy():
		push_warning("gdzig command is still running. Disabling the panel does not cancel it; wait before closing the editor.")
	runner.release()
