# Godot editor integration

Install the optional addon from the directory containing `build.zig`:

```sh
gdzig setup-editor                   # project.godot beside build.zig
gdzig setup-editor --project project # split layout
```

Enable **gdzig** in **Project > Project Settings > Plugins**. Open the **gdzig**
bottom panel or choose **Project > Tools > gdzig**. Nothing is executed merely
by installing or enabling the addon.

The panel provides:

- **Build**: runs `gdzig build`, selecting the currently running Godot executable.
  By default, build before pressing Play. An optional build-before-play setting is
  described below; the addon never starts another Godot editor.
- **Doctor**: diagnoses the current Godot project and its Zig build directory.
- **Zig files**: browses `build.zig` and Zig files under `src/`, creates new
  `src/*.zig` files, and edits them in a line-numbered source window. New files
  are not automatically registered as Godot classes; use **Generate class** for that.
- **Enable .zig in Script Editor**: adds `zig` to Godot's editable text-file
  extensions. Zig files inside the Godot project then appear in the FileSystem
  dock and open in Godot's Script Editor when double-clicked. This changes a
  global Editor Setting, so the button is opt-in and never removes other extensions.
- **Generate class**: creates and registers a node, resource, or editor plugin
  through `gdzig add`. Enter a Zig class name. For nodes, click **Base** to use
  Godot's searchable **Create Node** dialog. The selected base must be an
  instantiable native Node class in the running Godot build; script and custom
  extension classes are rejected. Existing files are never overwritten.

Set the gdzig executable to an absolute path if it is not on the editor's PATH.
Zig must also be on that PATH. The build directory is detected beside the Godot
project or one directory above it; select an absolute directory for other layouts.
Build options are **one argument per line**, without shell quoting, for example:

```text
-j2
-Doptimize=ReleaseSafe
```

Settings are stored locally in `.godot/gdzig-editor.cfg`, not in shared project
settings. Commands use argument arrays and `gdzig -C <directory>` rather than shell
commands or changing the editor's working directory. Only use this addon with
projects you trust: building executes the project's `build.zig`.

For manual commands, both output streams are drained asynchronously; the panel shows plain-text
diagnostics and the exit status. Its visible log is limited to the latest 262,144
characters; overlong individual lines are discarded. A successful command
requests a resource filesystem scan. Native class reloading remains subject to
Godot's GDExtension reload support; restart the editor if it requests one.

Only one panel command runs at a time. Disabling the addon does **not** cancel a
running build: a detached runner keeps draining it, and re-enabling reconnects to
that runner. Wait for completion before closing Godot. There is no process-tree
cancellation, background watch, or export button in this version. Use `gdzig export`
from a terminal for the export workflow.

## Clickable diagnostics

The diagnostics list recognizes Zig `file.zig:line:column: error/warning/note`
messages, including ANSI-colored output and Windows paths. Relative paths resolve
against the command's build directory. Click an entry to open its source at the
reported line and column. Without a configured external editor, this opens a
line-numbered editor for project Zig files. Diagnostics in dependencies or other
locations open read-only. The editor does not execute the source.

To open your code editor instead, set **External source editor** to its executable
and provide one argument per line. For VS Code the defaults are `--goto` and
`{file}:{line}:{column}` on separate lines. Placeholders are substituted after
splitting arguments, so paths containing spaces remain one argument; do not add
shell quotes. A failed launch falls back to the built-in editor. Both the raw log and
unlocated errors remain available. The list retains up to 500 entries per command;
the built-in editor accepts files up to 2 MiB. External editor launching is opt-in.

The **Zig files** window has **New**, **Refresh**, **Open**, **Save**, and
**Discard changes** actions. New filenames are restricted to simple `.zig` names
inside the build project's existing `src/` directory; existing files are not
overwritten. Unsaved edits block opening another file or closing the window.
Manual and pre-Play builds save the current buffer first. If the file changed on
disk since it was opened, saving refuses to overwrite it. Disabling the addon
preserves an unsaved draft in the project's `.godot/gdzig-source-draft.cfg` and
restores it when the addon is re-enabled. A successful save or explicit discard
removes the draft.

For the native Script Editor workflow, click **Enable .zig in Script Editor**
once, then double-click a `.zig` file in Godot's FileSystem dock. The equivalent
manual setting is **Editor > Editor Settings > Docks > FileSystem > Textfile
Extensions**: add `zig` to the comma-separated list. Godot's dock only displays
files under its `res://` project root. If `build.zig` and `src/` live outside
that root in a split-layout project, use the gdzig **Zig files** browser or an
external editor instead. Native editing handles Zig as a text file rather than
a Godot script, so it does not provide Zig language-server completion or inline
compiler diagnostics. The addon
registers a lightweight Zig syntax highlighter for new `.zig` tabs in Godot's
Script Editor and uses the same highlighting in its own **Zig files** window.
It colors keywords, builtin names, strings, numbers, and comments; it is not a
Zig parser or formatter. Close and reopen any `.zig` tab that was already open
when the addon was enabled, as Godot only applies newly registered highlighters
to subsequently opened files.

## Build before Play

Enable **Build before Play** in the panel to build on each Play action. It uses
the same build directory, options, CLI, and running Godot executable as manual
Build. A failed build, invalid setup, or an already-running command blocks Play.
Successful compilation lets Godot continue its original requested scene and mode.

Godot's `_build()` hook requires an immediate boolean result. Consequently, this
opt-in build is synchronous: the editor waits until compilation finishes, and
output is shown afterward. Manual Build remains asynchronous. The hook does not
queue or replay Play, bypass other editor plugins, or claim a previous build is
still current. Save externally edited Zig files before playing.

A successful build does not prove native hot reload succeeded. If Godot reports
a reload failure or requests a restart, stop the game and restart the editor.
The panel reminds you of this after a successful pre-play build; it does not
automatically detect or repair every native reload failure.

Installation refuses an existing `addons/gdzig` directory. To update, disable the
plugin, wait for commands to finish, back up any customizations, remove the old
addon, and run setup again. To uninstall, disable it and remove `addons/gdzig`.
The addon is independent of the native extension, so it remains usable when the
game's Zig code does not compile.

`zig build test-editor` installs into a temporary split-layout project and uses
headless Godot to test installation protection, Build/Doctor/class generation,
nonblocking stdout/stderr handling, exit codes, concurrent-command refusal, and
addon lifecycle. It is included in `test-all`.
