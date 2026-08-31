# gdzig

Idiomatic Zig bindings for Godot 4.

## DISCLAIMER

This library is currently undergoing rapid development and refactoring as we figure out the best API to expose. Bugs and missing features are
expected until a stable version is released. Issue reports, feature requests, and pull requests are all very welcome.

## Prerequisites

1. zig 0.16.0
2. godot 4.7

**Note:** gdzig targets Godot 4.7 only. Earlier versions are not supported; pin an older gdzig if you need one.

**Note:** We are targeting stable releases of Zig only. 0.15.x is no longer supported; use a tag prior to the 0.16 migration if you need it.

## Usage:

See the [example](example/) folder for reference.

```sh
zig build
```

That downloads a matching Godot automatically. To build against a specific version or an
engine you already have:

```sh
zig build -Dgodot-version=4.7
zig build -Dgodot-path=/absolute/path/to/godot   # must be absolute
```

In a project of your own, `zig build watch` rebuilds on every change and restarts Godot,
clearing the stale `~`-prefixed libraries that otherwise block the next load.

`zig build test` runs the unit and Godot tests; `zig build test-all` adds the
integration gates that cover the build tooling itself, which is what CI runs.

## Starting a project

Fastest route: `zig build` in a gdzig checkout installs `init-gdzig`; then
`init-gdzig --name mygame --out mygame` scaffolds a working project anywhere.
[doc/quickstart.md](doc/quickstart.md) is that path end to end.

To build one by hand instead, [doc/getting-started.md](doc/getting-started.md) walks
this same setup and finishes with a character you can drive with WASD. What follows is
the condensed reference for the files involved.

By hand a project is four files and a directory. The [example](example/) is the working
reference for all of it.

Your Zig code and a normal Godot project sit side by side, and the build installs the
library into the Godot project:

```
mygame/
  build.zig
  build.zig.zon
  src/main.zig              root module: must export `register`
  project/project.godot     an ordinary Godot project
  project/mygame.gdextension
  project/lib/              the build installs here
```

**Depend on gdzig.**

```sh
zig fetch --save git+https://github.com/moohaad/gdzig
```

**`build.zig`.** Three calls: take the dependency, make a module that imports it as `godot`,
and hand that module to `addExtension`.

```zig
const gdzig_dep = b.dependency("gdzig", .{
    .target = target,
    .optimize = optimize,
    .@"godot-version" = b.option([]const u8, "godot-version", "Godot version to download"),
    .@"godot-path" = b.option([]const u8, "godot-path", "Path to a Godot executable"),
});

const mod = b.createModule(.{
    .root_source_file = b.path("src/main.zig"),
    .target = target,
    .optimize = optimize,
    .imports = &.{.{ .name = "godot", .module = gdzig_dep.module("gdzig") }},
});

const extension = gdzig.addExtension(b, .{
    .name = "mygame",
    .root_module = mod,
    .entry_symbol = "mygame_init",
    .target = target,
    .optimize = optimize,
    // Names every `.tscn` under the project as an import, so
    // `Scene(@embedFile("Player.tscn"))` can reach one. Omit if unused.
    .godot_project = "project",
}) orelse return;

b.default_step.dependOn(&b.addInstallFileWithDir(
    extension.output,
    .{ .custom = "../project/lib" },
    extension.filename,
).step);
```

**`project/mygame.gdextension`.** Written by hand. `entry_symbol` has to match `build.zig`
exactly, and the `[libraries]` paths have to match where the install step puts the file.

```ini
[configuration]
entry_symbol = "mygame_init"
compatibility_minimum = "4.7"
reloadable = true

[libraries]
windows.debug.x86_64 = "lib/mygame.dll"
linux.debug.x86_64 = "lib/libmygame.so"
macos.debug = "lib/libmygame.dylib"
```

`compatibility_minimum` is the engine gdzig itself requires. Claiming an older one does not
buy compatibility: Godot loads the extension and gdzig then refuses it, which is a worse
error than Godot declining in the first place.

`reloadable = true` opts into hot reload. Exported properties and the instances
themselves survive; a class whose base changed does not, and says so rather than
crashing. `example/` has a harness -- `zig build reload-test` -- that reloads the
extension and checks what came through.

**`src/main.zig`.** gdzig provides the entry point itself; your root module only registers.
`register` is required, `unregister` is optional -- the registry unregisters anything left
behind either way.

```zig
pub fn register(r: *Registry) void {
    r.addClass(PlayerNode, r.allocator, .auto);
}

const godot = @import("godot");
const Registry = godot.extension.Registry;
const PlayerNode = @import("PlayerNode.zig");
```

Then `zig build`, and open `project/` in Godot.

Before writing much, skim [doc/what-gdzig-gives-you.md](doc/what-gdzig-gives-you.md).
It is short, and it exists because a real port hand-wrote five things that were
already in the box.

## Threading

Engine calls are safe from any thread; the scene tree is still main-thread only.
See [doc/threading.md](doc/threading.md) for the contract and the
`callDeferred` pattern.

## Code Sample:

https://github.com/gdzig/gdzig/blob/1cdfec61d185a9440e6419b122a08e003ad3dcde/example/src/GuiNode.zig#L1-L56

# Community

Find us in the [gdzig Discord server](https://discord.gg/GEUZGRGeDj).
