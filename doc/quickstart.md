# Quickstart

If you just want to write some Zig code in Godot immediately, `gdzig` provides a CLI scaffolding tool that does all the heavy lifting for you.

## Requirements
* Zig `0.16.0`
* Godot `4.7`

## The 30-Second Scaffold

Instead of manually creating boilerplate configuration files, you can clone `gdzig` and run its initializer script to generate a fully functioning project instantly.

```sh
git clone https://github.com/moohaad/gdzig.git
cd gdzig
zig build init-gdzig -- --name my_awesome_game --out ../my_awesome_game
```

`--out` says where to write it, and has no default: the scaffolder writes where it is
told and nowhere else. `../my_awesome_game` puts the project alongside the `gdzig`
checkout rather than inside it. You get:
* `build.zig` and `build.zig.zon` correctly referencing the `gdzig` dependency.
* `my_awesome_game.gdextension` configured to load the compiled Zig DLL.
* `project.godot` configured for the editor.
* `src/my_awesome_game.zig` with a valid entry point and `registerAll` call.
  The file is named after the project, not `main.zig`.

## Build the Extension

Build before opening the editor. The `.gdextension` names a library that does not exist
until you do, and importing first just means Godot complains about its absence.

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

Your extension now loads. Add logic in `src/my_awesome_game.zig` and run `zig build` (or
`zig build watch`) whenever you want to update the engine.

---

> For a deep dive into building actual game features (like characters, WASD movement, and following cameras) from scratch, read the comprehensive [Getting Started Guide](getting-started.md).
