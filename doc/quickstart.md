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
zig build init-gdzig -- --name my_awesome_game
```

This will automatically create a directory named `my_awesome_game` alongside `gdzig`, populated with:
* `build.zig` and `build.zig.zon` correctly referencing the `gdzig` dependency.
* `my_awesome_game.gdextension` configured to load the compiled Zig DLL.
* `project.godot` configured for the editor.
* `src/main.zig` with a valid entry point and `registerAll` call.

## Open in Godot

Open the Godot Editor and import the generated `my_awesome_game/project.godot` file. The project will open, but you will see a warning in the console that the `my_awesome_game.dll` cannot be found. This is expected—we just need to compile it!

## Build the Extension

Open a terminal, navigate into your newly generated project, and compile your Zig extension:

```sh
cd ../my_awesome_game
zig build
```

The compiled library will appear in `my_awesome_game/lib/`. 

Return to Godot, and your extension will automatically load! You can now start adding logic in `src/main.zig` and run `zig build` (or `zig build watch`) whenever you want to update the engine.

---

> For a deep dive into building actual game features (like characters, WASD movement, and following cameras) from scratch, read the comprehensive [Getting Started Guide](getting-started.md).
