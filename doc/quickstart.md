# Quickstart

If you just want to write some Zig code in Godot immediately, `gdzig` provides a CLI scaffolding tool that does all the heavy lifting for you.

## Requirements
* Zig `0.16.0`
* Godot `4.7`

## The 30-Second Scaffold

gdzig ships a scaffolder. Build it once:

```sh
git clone https://github.com/moohaad/gdzig.git
cd gdzig
zig build
```

That installs `init-gdzig` into `zig-out/bin`. Put that directory on your `PATH`, and
every project after this one is one command, run wherever the project should live:

```sh
init-gdzig --name my_awesome_game --out my_awesome_game
```

`--out` says where to write it and has no default: the scaffolder writes where it is
told and nowhere else. The directory must be empty, so it cannot overwrite an existing
project. The project name must be a valid Zig identifier (for example, `my_game`, not
`my-game`).

If you would rather not put anything on your `PATH`, this does the same from any
directory, with no `cd`:

```sh
zig build --build-file /path/to/gdzig/build.zig init-gdzig -- --name my_awesome_game --out my_awesome_game
```

Either way you get:
* `build.zig` and `build.zig.zon` correctly referencing the `gdzig` dependency.
* A build that generates `my_awesome_game.gdextension` from the compiled target and
  installs it beside `project.godot`.
* `project.godot` and `main.tscn`, configured as a runnable starter scene.
* `src/my_awesome_game.zig` with a valid entry point and `registerAll` call.
  The file is named after the project, not `main.zig`.
* `src/Game.zig`, a registered `Node` with a Godot-style `_ready` callback.
* `.gitignore` entries for Zig, gdzig, and Godot build artifacts, including the
  target-specific generated descriptor.

## Build the Extension

Build before opening the editor. This creates both the library and its `.gdextension`
descriptor; importing first means neither exists yet.

```sh
cd ../my_awesome_game
zig build
```

The compiled library will appear in `my_awesome_game/lib/`.

## Open in Godot

Open the Godot Editor and import `my_awesome_game/project.godot`. That import pass is
what writes `.godot/extension_list.cfg`, the file Godot reads to decide what to load --
until it exists your classes are simply absent, with nothing logged to say why.
Headless equivalent, if you would rather not open the editor:

```sh
godot --path . --headless --import
```

Your extension now loads and the starter scene prints `Hello from gdzig!`. Add game logic
in `src/Game.zig` and run `zig build` (or `zig build watch`) whenever you want to update
the engine.

---

> For a deep dive into building actual game features (like characters, WASD movement, and following cameras) from scratch, read the comprehensive [Getting Started Guide](getting-started.md).
