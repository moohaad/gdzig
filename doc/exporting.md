# Desktop exports

New `gdzig init` projects and the tutorial provide an `export` build step.
Create and save a preset in **Project > Export**, selecting your host platform
and architecture. Install the selected engine's matching export templates in
**Editor > Manage Export Templates**. For macOS choose a single architecture,
not Universal: gdzig currently generates a single-target library descriptor.

Run beside `build.zig` (Windows example):

```sh
gdzig export -- --preset "Windows Desktop" --output ../exports/v1/Game.exe
gdzig export -Doptimize=debug -- --preset "Windows Desktop" --output ../exports/debug/Game.exe --debug
```

Zig options go before `--`; export options go after it. The CLI defaults to
`-Doptimize=safe` and a Godot release export. `--debug` selects the Godot
debug template; use `-Doptimize=debug` separately if desired. Engine options such
as `-Dgodot-path=/absolute/path/to/godot` or `-Dgodot-version=4.7` are forwarded.
Godot is invoked directly, without a shell, so quoted preset names and paths work.

Output paths are relative to the **build directory**, not the Godot project.
The parent directory is created if missing, must be empty, and must be outside
the Godot project (including through symlinks). Use a dedicated directory per
export. Existing exports are never overwritten. On failure, any partial output
is retained for inspection; choose another directory or remove it yourself before
retrying. Windows outputs require `.exe`; macOS outputs require `.zip`.

The command builds and installs the extension, checks the preset's platform and
explicit `binary_format/architecture`, then imports and exports with the same
host editor selected by gdzig. Godot's output remains visible. An import failure
stops export; an export failure or missing/empty output fails the command.
Godot validates templates, signing tools, credentials, and other preset settings;
gdzig does not download export templates or rewrite your presets.

This helper currently supports **host-native Windows, Linux, and macOS** only.
Cross-target, mobile, web, and universal/fat-binary exports are rejected. They
need a multi-target library/import workflow, not just a different export preset.
Keep all emitted libraries and resource packs with the exported executable.

## Existing projects

After your extension's install steps, add:

```zig
_ = gdzig.addExportStep(b, .{
    .dependency = gdzig_dep,
    .target = target,
    .project = ".", // or "project" for a split layout
});
```

The helper depends on `b.getInstallStep()`. Ensure that step installs both the
extension library and its descriptor into your Godot project. It forwards
arguments after `--` to the export runner using `addPassthruArgs`. The equivalent without the CLI is:

```sh
zig build export -Doptimize=safe -- --preset "Windows Desktop" --output ../exports/v1/Game.exe
```

`zig build test-export` checks argument/preset validation and fake-editor process
scenarios (success, debug mode, import/export failure, missing output, stale files,
and output inside the project). It is part of `test-all`; it does not certify an
actual distributable. Test your exported game on the destination machine.

See Godot's [export guide](https://docs.godotengine.org/en/stable/tutorials/export/exporting_projects.html)
and [command-line reference](https://docs.godotengine.org/en/stable/tutorials/editor/command_line_tutorial.html).
