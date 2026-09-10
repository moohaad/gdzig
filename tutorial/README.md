# Star Catcher: your first gdzig game

Move the blue player with **WASD**, touch five yellow stars before twenty seconds
run out, and press **R** to restart. This is a complete native desktop game with
no downloaded art, fonts, or audio. The yellow circles stand in for star sprites.

Use Zig 0.16 and Godot 4.7. Start from a checkout of gdzig: this project's package
dependency points to its parent directory. If you copy the project elsewhere,
replace that path dependency with your pinned gdzig dependency.

## 1. Run before changing anything

From this directory:

```sh
zig build run
```

Or, after installing the CLI with `zig build cli` in the repository root and
adding `zig-out/bin` to PATH:

```sh
gdzig run
gdzig editor
```

The build installs the extension into `project/lib`, installs the generated
descriptor, imports the project, and launches the selected engine. You do not
need to maintain a `.gdextension` file yourself. To select an engine explicitly:

```sh
gdzig run -Dgodot-path=/absolute/path/to/godot
```

Use that same engine selection for subsequent builds and exports.

The source is deliberately small:

| File | Responsibility |
|---|---|
| [Game.zig](src/Game.zig) | Movement, collection, drawing, score, and countdown |
| [main.zig](src/main.zig) | Symmetric class registration |
| [Main.tscn](project/Main.tscn) | Game root and HUD label |
| [project.godot](project/project.godot) | Input Map, main scene, and window |
| [palette.tres](project/palette.tres) | Editable player color resource |
| [test_game.gd](project/test_game.gd) | Automated gameplay checks, not game logic |

## 2. A Zig class becomes a scene node

`Game.zig` has an allocator and a `base: *godot.class.Node2d` field. gdzig uses
these to provide the ordinary construction and destruction hooks. `main.zig`
passes the same tuple to `registerAll` and `unregisterAll`; the scene can then
instantiate a node whose type is `Game`.

`_ready` runs when the scene is ready, `_physics_process` advances gameplay,
`_draw` draws the circles, and `_exit_tree` releases the resource reference.
The underscore callback spellings match Godot.

Try changing the player radius in `_draw`, rebuild, and run again. No asset
import is required because Godot draws both objects directly.

## 3. Input becomes typed movement

The Input Map defines `left`, `right`, `up`, `down`, and `restart`. Passing
`godot_project` to the dependency generates `godot.input.Action` from those
names. `_physics_process` reads the four movement actions with `input.getVector`.
Renaming an action without updating its Zig reference fails at compile time.

Movement multiplies direction by speed and `delta`, measured in seconds. This
keeps speed independent of the physics tick rate. The position is clamped inside
the play area; the HUD occupies the top strip.

Collection uses squared distance between the player and star. If it is less
than the squared sum of their pickup radii, the score increases and the star
moves to its next deterministic position. This keeps the tutorial focused on
bindings. For walls and collision response, extend it with CharacterBody2d and
Godot collision shapes instead of this distance check.

Exercise: change movement speed from 230 to 160. Then change the Input Map key
bindings in Godot; the Zig action names can stay the same.

## 4. Let the scene type the HUD

The `children` field is `godot.Scene(@embedFile("Main.tscn"))`. Its `Hud` member
comes from the scene's Label node. gdzig resolves it before `_ready`; game code
uses `self.children.Hud.get()` without a NodePath allocation or a downcast.

Rename `Hud` in the scene and rebuild: `children.Hud` no longer exists, so the
compiler points at the stale reference. Change both names to restore the build.

These fields contain weak references. `get()` can return null if the node was
removed or freed. The pointer it returns is borrowed: do not free a HUD that is
still owned by the scene tree.

## 5. Use a signal to update presentation

`Scored` declares one `i64` payload, `total`, and is listed in the class's
`signals` tuple. `_ready` connects it to `onScore`. The collection code emits
`Scored`; the handler updates the HUD. Other nodes can connect to the same signal
without adding their behavior to the collection code.

The typed connection checks the handler parameters against the signal. Change
the handler's `total` parameter to `bool` to see the diagnostic, then restore it.
The local signal's receiver is the same engine object as its emitter, so both
disappear together when the game node is destroyed.

`updateHud` formats into a stack buffer and passes the text to `Label.setText`.
Godot copies the text; the buffer does not need to survive the call.

## 6. Resources and asynchronous work have lifetimes

`godot.load(Gradient, "res://palette.tres")` returns an optional owning `Gd` handle.
The game keeps that reference across frames and releases it in `_exit_tree`.
If loading fails, `_draw` uses a fallback color. Open the gradient resource in
the editor and change its first color to customize the player.

The countdown uses `coro.spawn` and `coro.wait`, letting the code read as a loop
that waits one second and decreases the remaining time. Waiting yields control
to Godot; it does not block the main thread or start a background game thread.

Each restart increments `round_id`. An older countdown checks its saved ID after
waking and returns if a newer round has started. This prevents repeatedly pressing
R from creating multiple active countdowns. `_exit_tree` invalidates the round
as well. gdzig tracks the object argument passed to the coroutine and cancels
resumption if that object has been destroyed.

This tutorial targets native desktop platforms. Its stackful coroutine path is
not a WebAssembly tutorial; a web version needs the explicit state-machine path.

## 7. Test what you teach

```sh
zig build test
```

The test builds the actual extension and runs the actual scene headlessly. It
presses a movement action, moves the player onto each pickup, counts score
signals, checks the HUD and win state, restarts with a one-second round, and
checks that the coroutine ends it. A watchdog returns failure if the script
cannot finish. Expected final output: `Star Catcher: 0 failures`.

From the repository root, `zig build test-tutorial` runs the same gate;
`zig build test-all` includes it for CI. The guide points to those source files
instead of maintaining a second copy of the game in Markdown code blocks.

If your classes do not load, run `gdzig doctor --project project` from this
directory. A missing library needs a build; a missing import list needs an import.

## 8. Export a native desktop build

First build a release-safe extension for your current platform:

```sh
gdzig build -Doptimize=ReleaseSafe
```

Open the project with the same Godot 4.7 executable. Install its matching export
templates through **Editor > Manage Export Templates**, then create a preset in
**Project > Export** for your platform. Select all project resources and exclude
`test_game.gd`; save the preset. Choose an output directory outside `project/`.

For example, after creating a preset named `Windows Desktop`, export using an
absolute output path whose parent directory already exists:

```sh
godot --headless --path project --export-release "Windows Desktop" C:/games/starcatcher/StarCatcher.exe
```

Substitute your selected engine executable, preset name, and output path. Godot
requires the preset and matching templates; these are not installed by gdzig.
See [Godot's export guide](https://docs.godotengine.org/en/stable/tutorials/export/exporting_projects.html)
and [command-line export reference](https://docs.godotengine.org/en/stable/tutorials/editor/command_line_tutorial.html).

Run the exported game outside the editor and check movement, collection, timeout,
and restart. Keep the exported native library and resource pack alongside the
executable as emitted by Godot. Export is a manual exercise here, not part of the
headless test: CI does not install export templates.

For another platform, compile the extension for that target before exporting and
check the generated descriptor's library selector. Changing only the Godot preset
does not turn a Windows DLL into a Linux or macOS library.

Next exercises: add a pickup sound using an owning resource handle, connect a
second score listener, or replace the drawn circles with scene-instantiated sprites.
