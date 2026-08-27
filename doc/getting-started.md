# Getting started

A walkthrough from an empty Godot project to a character you can drive with WASD,
with a camera that trails it. No assets: the mesh is Godot's built-in capsule.

The README's [Starting a project](../README.md#starting-a-project) section is the
reference version of the same setup. This is the hands-on one, and it covers the two
failures that are silent — the extension that never loads, and the smoothing that
never runs.

## Before you start

```sh
zig version     # 0.16.0
godot --version # 4.7
```

gdzig targets Godot 4.7 only, and stable Zig only.

## Two layouts

The README and [example/](../example/) put the Godot project in a `project/`
subdirectory, with `build.zig` above it. That is the better shape for a repository
whose reason to exist is the extension.

This tutorial uses the flat layout instead, because the usual situation is the other
way round: you have a Godot project already and you are adding Zig to it.

```
mygame/
├── project.godot          ← already yours
├── mygame.gdextension     ← new
├── build.zig              ← new
├── build.zig.zon          ← new
├── src/
│   ├── mygame.zig         ← new: entry point
│   ├── PlayerNode.zig     ← new
│   └── FollowCameraNode.zig
└── lib/                   ← `zig build` puts the library here
```

Only the install path differs between the two. Nothing else in this tutorial changes.

## 1. Depend on gdzig

```sh
zig fetch --save git+https://github.com/moohaad/gdzig
```

Or point at a local checkout in `build.zig.zon`:

```zig
.gdzig = .{ .path = "../gdzig" },
```

## 2. The four scaffolding files

**`build.zig.zon`.** Leave the fingerprint at `0x0` — Zig will tell you the real one.

```zig
.{
    .name = .mygame,
    .version = "0.0.0",
    .fingerprint = 0x0,
    .minimum_zig_version = "0.16.0",
    .dependencies = .{
        .gdzig = .{ .path = "../gdzig" },
    },
    .paths = .{ "build.zig", "build.zig.zon", "src" },
}
```

**`build.zig`.** Take the dependency, make a module that imports it as `godot`, hand
that module to `addExtension`, install the result where the `.gdextension` says to
look.

```zig
pub fn build(b: *Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const gdzig_dep = b.dependency("gdzig", .{ .target = target, .optimize = optimize });

    const mod = b.createModule(.{
        .root_source_file = b.path("src/mygame.zig"),
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
        // Flat layout, so the Godot project *is* the build root. Worth setting:
        // it names every `.tscn` for `Scene(@embedFile(...))`, and it lets the
        // build warn about step 4 below instead of leaving you to guess.
        .godot_project = ".",
    }) orelse return;

    // `../lib` escapes zig-out and lands beside project.godot, which is where
    // the .gdextension says to look. In the nested layout this is
    // `../project/lib` instead.
    const install = b.addInstallFileWithDir(extension.output, .{ .custom = "../lib" }, extension.filename);
    b.default_step.dependOn(&install.step);
}

const std = @import("std");
const Build = std.Build;
const gdzig = @import("gdzig");
```

**`mygame.gdextension`.** Hand-written. `entry_symbol` has to match `build.zig`
exactly; a mismatch reports as "extension failed to load" rather than as a missing
symbol.

```ini
[configuration]

entry_symbol = "mygame_init"
compatibility_minimum = "4.7"
reloadable = true

[libraries]

windows.debug.x86_64 = "lib/mygame.dll"
windows.release.x86_64 = "lib/mygame.dll"
linux.debug.x86_64 = "lib/libmygame.so"
linux.release.x86_64 = "lib/libmygame.so"
macos.debug = "lib/libmygame.dylib"
macos.release = "lib/libmygame.dylib"
```

`compatibility_minimum` is the engine gdzig itself requires. Claiming an older one
does not buy compatibility — Godot loads the extension and gdzig then refuses it,
which is a worse error than Godot declining up front.

**`src/mygame.zig`.** gdzig supplies the entry point; your root module only registers.
A class that is not reachable from here does not exist, and nothing warns you.

```zig
pub fn register(r: *Registry) void {
    r.addModule(PlayerNode);
    r.addModule(FollowCameraNode);
}

pub fn unregister(r: *Registry) void {
    r.removeModule(FollowCameraNode);
    r.removeModule(PlayerNode);
}

const godot = @import("godot");
const Registry = godot.extension.Registry;
const PlayerNode = @import("PlayerNode.zig");
const FollowCameraNode = @import("FollowCameraNode.zig");
```

`addModule` defers to a `register` function on the file itself, which keeps each node's
registration next to the node. `r.autoRegister(PlayerNode)` works here directly too, if
you would rather keep it all in one place.

## 3. Build

```sh
zig build
```

The first run fails on purpose:

```
build.zig.zon:1:2: error: invalid fingerprint: 0x0; if this is a new or forked
package, use this value: 0xf305d10960ee2873
```

The value is derived from the package name and path, so yours will differ. Paste the
one Zig prints and run again. You get `lib/mygame.dll` (or `.so` / `.dylib`).

## 4. Let Godot discover the extension

**This step used to fail silently.** Godot does not scan for `.gdextension` files at
startup; it reads `.godot/extension_list.cfg`, which is written during an import pass.
A project that has never been opened has no such file, so no extension loads,
`ClassDB.class_exists("PlayerNode")` is `false`, and the engine says nothing at all.

With `godot_project` set, `zig build` now checks for you and prints the fix:

```
warning: gdzig: '.' has no .godot/extension_list.cfg, so Godot will load no extension
at all and your classes will be missing with no error. Open the project in the editor
once, or run: godot --path . --headless --import
```

It says the same when the file exists but does not name your `.gdextension`, which is
what you get after adding one to a project that was imported earlier.

Opening the project in the editor once writes it. Headless equivalent:

```sh
godot --path . --headless --import
```

Then check:

```sh
cat .godot/extension_list.cfg     # res://mygame.gdextension
```

That first pass can exit noisily — it is importing scenes that may reference classes
the engine does not know yet. What matters is the file's contents. Re-run it if in
doubt.

## 5. A node

Every gdzig node is a struct with two required fields:

- `allocator: Allocator` — gdzig hands you one per instance
- `base: *SomeEngineClass` — the engine object, and what your class extends

Methods named after Godot virtuals (`_ready`, `_process`, `_physicsProcess`,
`_input`, …) are wired up automatically.

`src/PlayerNode.zig`:

```zig
const PlayerNode = @This();

/// The actions this node reads. `godot.input` takes variants rather than
/// strings, so each name is spelled once and the set is visible in one place.
const Actions = enum { forward, backward, left, right, jump };

pub fn register(r: *Registry) void {
    r.autoRegister(PlayerNode);
}

pub fn unregister(r: *Registry) void {
    r.removeClass(PlayerNode);
}

allocator: Allocator,
base: *CharacterBody3d,

/// Exported: tunable in the inspector without a rebuild.
speed: f64 = 5.0,
jump_velocity: f64 = 4.5,
gravity: f64 = 9.8,

/// Physics, not `_process`: `moveAndSlide` resolves against the physics state, and
/// running it off the render tick makes movement depend on frame rate.
pub fn _physicsProcess(self: *PlayerNode, delta: f64) void {
    // The editor instantiates nodes too, and a character that walks around the
    // editor viewport is not what anyone wants.
    if (Engine.isEditorHint()) return;

    var velocity = self.base.getVelocity();

    if (self.base.isOnFloor()) {
        if (godot.input.isActionJustPressed(Actions.jump)) {
            velocity.y = @floatCast(self.jump_velocity);
        }
    } else {
        velocity.y -= @floatCast(self.gravity * delta);
    }

    const input = godot.input.getVector(
        Actions.left,
        Actions.right,
        Actions.forward,
        Actions.backward,
        .{},
    );

    const direction = self.relativeTo(cameraBasis(self.base), input);
    velocity.x = direction.x * @as(f32, @floatCast(self.speed));
    velocity.z = direction.z * @as(f32, @floatCast(self.speed));

    self.base.setVelocity(velocity);
    _ = self.base.moveAndSlide();
}
```

`autoRegister` binds the class and everything it can find on it: every Variant-typed
field becomes a property, and every `pub fn` taking `*PlayerNode` becomes a method.
`allocator`, `base` and any `_`-prefixed field are skipped, which is how you keep a
field internal.

Being a property is also what makes a field survive hot reload — plain fields are reset.

Declare a `properties` tuple only when a property needs non-default options; a plain
field already binds without being listed:

```zig
pub const properties = .{
    .{ "speed", .{ .setter = .none } },   // read-only in the inspector
};
```

When `autoRegister` is not enough — `.{ .level = .editor }`, or hand-written
`addMethod` / `addProperty` / `addSignal` — use the long form it wraps:

```zig
const class = r.createClass(PlayerNode, r.allocator, .auto);
class.autoBind();
```

Two things worth noticing in that code, because they are not obvious from the Zig side:

**No upcasting to call inherited methods.** `getVelocity`, `isOnFloor`, `moveAndSlide`
and `getViewport` are declared on different ancestors, but the bindgen re-emits every
inherited method onto each generated class with the concrete receiver type. So
`self.base.getViewport()` resolves even though `getViewport` is a `Node` method.
`Node.upcast(self.base).getViewport()` also works and does the same thing — it is just
noise. You *do* need `upcast` for your own classes: a user class is a plain Zig struct,
so nothing is flattened onto it, and `Object.upcast(self).destroy()` is the only way in.

**Actions are enum variants, not strings.** `godot.input` rejects anything else at
comptime, which keeps the set of actions a node reads in one declaration instead of
spelled out at each call site. Each variant interns its `StringName` at comptime, so
nothing is allocated per tick.

The raw `godot.class.Input` bindings are still there and take a `StringName` — or any
Zig string, since the parameter is `anytype`. Prefer the enum module: a plain `"jump"`
goes through `StringName.fromUtf8` on every call, which is not what you want inside
`_physicsProcess`. Note also that a decl literal — `.interned("jump")` — does *not*
work in argument position, because an `anytype` parameter gives it no type to resolve
against.

## 6. Camera-relative movement

Forward should mean "away from the camera", not "along -Z". Rotate the input by the
camera's basis, flatten it, then renormalise:

```zig
/// Flatten *then* normalise, and only when there is something to normalise:
/// `Vector3.normalized` on a zero vector is not zero, so a released key would
/// leave the character drifting.
fn relativeTo(_: *PlayerNode, basis: ?Basis, input: Vector2) Vector3 {
    const local: Vector3 = .initXYZ(input.x, 0, input.y);
    const b = basis orelse return local;

    var world = b.mulVector3(local);
    world.y = 0;
    if (world.length() < 0.0001) return .zero;
    return world.normalized();
}

/// The viewport's current camera, asked per tick rather than cached, so switching
/// cameras just works. Falls back to world-relative when there is no camera.
fn cameraBasis(node: *CharacterBody3d) ?Basis {
    const viewport = node.getViewport() orelse return null;
    const camera = viewport.getCamera3d() orelse return null;
    return camera.getGlobalTransform().basis;
}

const std = @import("std");
const Allocator = std.mem.Allocator;

const godot = @import("godot");
const Registry = godot.extension.Registry;
const CharacterBody3d = godot.class.CharacterBody3d;
const Engine = godot.class.Engine;
const Basis = godot.builtin.Basis;
const Vector2 = godot.builtin.Vector2;
const Vector3 = godot.builtin.Vector3;
```

Without flattening, a camera angled downward pushes the character into the floor.
Without renormalising, movement slows the steeper the camera angle, because the
horizontal part of a tilted basis vector is shorter.

## 7. A camera that follows

`src/FollowCameraNode.zig`:

```zig
const FollowCameraNode = @This();

pub fn register(r: *Registry) void {
    r.autoRegister(FollowCameraNode);
}

pub fn unregister(r: *Registry) void {
    r.removeClass(FollowCameraNode);
}

allocator: Allocator,
base: *Camera3d,

/// What this camera follows. Declaring the type here is what removes the
/// `getParent()` + cast that every use would otherwise need.
target: Parent(Node3d) = .pending,

/// Where the camera sits relative to the target: back along +Z and up.
offset: Vector3 = .initXYZ(0, 4, 7),

/// How quickly the camera closes the gap, per second. Higher is tighter.
smoothing: f64 = 6.0,

pub fn _ready(self: *FollowCameraNode) void {
    if (Engine.isEditorHint()) return;

    // See below -- without this the easing has nothing left to do.
    self.base.setAsTopLevel(true);

    // Start where it belongs rather than easing in from wherever the scene put it.
    if (self.target.get()) |node| {
        const target = node.getGlobalPosition();
        self.base.setGlobalPosition(target.add(self.offset));
        self.base.lookAt(target, .{});
    }
}

pub fn _physicsProcess(self: *FollowCameraNode, delta: f64) void {
    if (Engine.isEditorHint()) return;

    const target = (self.target.get() orelse return).getGlobalPosition();
    const wanted = target.add(self.offset);

    // Frame-rate independent easing: the fraction of the remaining distance
    // covered this tick, not a fixed fraction per tick. A plain `lerp(0.1)`
    // moves twice as far at 120 Hz as at 60.
    const weight = 1.0 - @exp(-self.smoothing * delta);
    self.base.setGlobalPosition(self.base.getGlobalPosition().lerp(wanted, weight));

    // Aim at the target, not at where the camera is heading, so the subject stays
    // centred while the position catches up.
    self.base.lookAt(target, .{});
}

const std = @import("std");
const Allocator = std.mem.Allocator;

const godot = @import("godot");
const Registry = godot.extension.Registry;
const Parent = godot.Parent;
const Camera3d = godot.class.Camera3d;
const Engine = godot.class.Engine;
const Node3d = godot.class.Node3d;
const Vector3 = godot.builtin.Vector3;
```

### Why `setAsTopLevel(true)`

Making the camera a child of the player means its target is just `getParent()`, with
no wiring. But a plain child inherits the parent's transform, and that quietly cancels
the easing: the parent carries the camera rigidly before `_physicsProcess` runs, so
there is never a gap left to close.

The failure is invisible in the final transform. `setGlobalPosition` and `lookAt` are
both world-space, so the camera ends up pointing the right way either way. Only the
*lag* differs. Teleporting the player five metres sideways is what shows it:

| | teleport +5 on x | one frame later | one second later |
|---|---|---|---|
| top-level | offset `(0, 4, 7)` | `(-5.00, 4.07, 7.00)` | `(-0.01, 4.00, 7.00)` |
| plain child | offset `(0, 4, 7)` | `(0.00, 4.00, 7.00)` | `(0.00, 4.00, 7.00)` |

The bottom row never moves — the camera was dragged along and `smoothing` is dead code.

**No casts.** `getParent()` returns `?*Node`, and `Node` is not spatial — it has no
`getGlobalPosition` — so reaching the parent as a `Node3D` would normally mean a
`castTo` at every use. `Parent(Node3d)` names the type on the field instead: gdzig
resolves it once before `_ready`, and logs `no child '..' of type Node3d` if the parent
is not one. Same for children (`Child(T, "path")`) and autoloads (`Autoload(T, name)`).

When the path is only known at runtime there is no field to declare, so ask for the
type at the call instead: `self.base.getNodeAs(Marker3d, path)` is null both when
nothing is there and when it is not a `Marker3d`, and prints no engine error either
way.

## 8. The scene and the input map

`Player.tscn` — no assets, just built-in resources:

```ini
[gd_scene load_steps=3 format=3]

[sub_resource type="CapsuleShape3D" id="shape"]
[sub_resource type="CapsuleMesh" id="mesh"]

[node name="Player" type="PlayerNode"]

[node name="Mesh" type="MeshInstance3D" parent="."]
mesh = SubResource("mesh")

[node name="Camera" type="FollowCameraNode" parent="."]
current = true

[node name="CollisionShape3D" type="CollisionShape3D" parent="."]
shape = SubResource("shape")
```

Your classes appear in **Add Node** by name, exactly like built-in ones.

For input, add five actions in **Project Settings → Input Map**, bound to physical
keys so the layout does not matter:

| action | key |
|---|---|
| `forward` | W |
| `backward` | S |
| `left` | A |
| `right` | D |
| `jump` | Space |

## Checking it

In the editor, drop `Player.tscn` into a scene with a floor, press play and hold W.
The character moves away from the camera, and the camera trails slightly behind rather
than staying pinned to it. That visible lag is the tell that the smoothing is running
and not being cancelled by the parent transform.

For a check that does not need eyes, save this as `check.gd` in the project root:

```gdscript
extends SceneTree

var t := 0.0
var player
var cam
var phase := 0

func _initialize() -> void:
    var floor_body := StaticBody3D.new()
    var shape := CollisionShape3D.new()
    var box := BoxShape3D.new()
    box.size = Vector3(50, 1, 50)
    shape.shape = box
    floor_body.add_child(shape)
    floor_body.position = Vector3(0, -1.5, 0)
    root.add_child(floor_body)

    print("registered: PlayerNode=%s FollowCameraNode=%s" % [
        ClassDB.class_exists("PlayerNode"), ClassDB.class_exists("FollowCameraNode")])

    player = load("res://Player.tscn").instantiate()
    root.add_child(player)
    cam = player.get_node("Camera")

func offset() -> String:
    var r = cam.global_position - player.global_position
    return "cam_offset=(%.2f, %.2f, %.2f)" % [r.x, r.y, r.z]

func _process(delta: float) -> bool:
    t += delta
    if phase == 0 and t > 0.5:
        phase = 1
        print("  settled   player_z=%.2f  %s  top_level=%s" % [player.global_position.z, offset(), cam.top_level])
        Input.action_press("forward")
    elif phase == 1 and t > 1.5:
        phase = 2
        print("  W held 1s player_z=%.2f  %s" % [player.global_position.z, offset()])
        Input.action_release("forward")
        Input.action_press("right")
    elif phase == 2 and t > 2.5:
        print("  D held 1s player_x=%.2f  %s" % [player.global_position.x, offset()])
        quit(0)
    return false
```

```sh
godot --path . --headless --script res://check.gd
```

A correct setup produces:

```
registered: PlayerNode=true FollowCameraNode=true
  settled   player_z=0.00  cam_offset=(0.00, 4.00, 7.00)  top_level=true
  W held 1s player_z=-5.00  cam_offset=(0.00, 4.00, 7.79)
  D held 1s player_x=4.98  cam_offset=(-0.79, 4.00, 6.91)
```

`speed` is 5.0, so one second of W is five metres. The offset growing from 7.00 to
7.79 while moving is the steady-state easing lag; if it stays at exactly 7.00 the
camera is being carried by its parent and `setAsTopLevel` is not in effect.

## Gotchas

Each of these fails quietly rather than loudly, which is what makes them worth listing.

**The extension never loads.** No `.godot/extension_list.cfg` — see step 4. The
symptom is `class_exists` returning false with no error anywhere.

**`entry_symbol` mismatch** between `build.zig` and the `.gdextension` reports as
"extension failed to load", not as a missing symbol.

**A stale `lib/~mygame.dll`.** Godot writes `~`-prefixed copies while hot-reloading,
and one left by a killed editor blocks the next load — with an error that says nothing
about the file. With `godot_project` set the build clears its own and tells you:
`gdzig: removed stale reload artifact lib/~mygame.dll`. Without it, `rm lib/~*` before
looking anywhere else.

**Forgetting `r.addModule`.** The build succeeds, the class is simply absent.

**Restart Godot after the first build.** `reloadable = true` only helps once the
extension is already known to the editor.

**Reading a property right after `add_child`.** `_ready` has not run yet, so you read
the pre-`_ready` value and conclude your setter did not work. Read one frame later.

## Next

- [what-gdzig-gives-you.md](what-gdzig-gives-you.md) — short, and worth reading before
  you write much. It exists because a real port hand-wrote five things already in the
  box.
- [threading.md](threading.md) — engine calls are safe from any thread; the scene tree
  is not.
- [example/](../example/) — signals, GUI, editor plugins, and a hot-reload harness
  (`zig build reload-test`).
- Pass `.godot_project = "."` to `addExtension` and every `.tscn` becomes importable,
  so `children: Scene(@embedFile("Player.tscn")) = .{}` can reach one.
