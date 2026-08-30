# What gdzig gives you

Written because a real port kept reinventing things that were already here. Five, across one
codebase: `anytype` class parameters, `Gd.borrow`, `Child`, `Scene`, and the autoload lookup
that became `Autoload`. Each was a hand-written version of something the binding shipped, and
each was found by accident rather than by looking.

So this is not a reference -- the doc comments are that. It is a list of the questions people
answer by writing code, and where the answer already is.

## "I need to reach a node in my scene"

Not `getNode` plus `castTo` in `_ready`. Put the path on the field:

```zig
sprite: Child(AnimatedSprite2d, "AnimatedSprite2D") = .pending,
```

Resolved before `_ready`, holds a [`Weak`](../src/weak.zig) underneath so `get` stays honest
after a free, and logs the field and path if the scene does not have it.

If the whole struct comes from one scene, let the file say so:

```zig
children: Scene(@embedFile("Player.tscn")) = .{},
```

One `Child` field per node in the file, named after the node, so renaming a node in the editor
breaks the build instead of failing at runtime. Needs `godot_project` set in `addExtension`.

`Child` remains right for what a scene cannot type: an instanced sub-scene, a node added at
runtime, or a node reached before it enters the tree.

Four shapes in all, and which applies depends only on what you know at compile time:

| you know | use |
|---|---|
| the path and the type | `Child(T, "path")` |
| the target is the parent | `Parent(T)` |
| the path only at runtime | `node.getNodeAs(T, path)` |
| only that you want every `T` | `node.childrenAs(T)` |

The first two are fields: resolved once before `_ready`, and the log names the field and path
when the scene disagrees. The last two are calls, and answer with null or with nothing instead
of complaining -- a missing node, or a child of some other type, is the ordinary case there.

None of them ends in a cast, which is the point. `getNode` can only promise `?*Node`.

A fifth spelling, `bind_nodes`, lists the same thing as a declaration rather than as a
field type:

```zig
pub const bind_nodes = .{
    .{ "sprite", "AnimatedSprite2D" },
    .{ "hitbox", "Area2D/Shape" },
};
```

Filled before `_ready`, in the same place `Child` fields are resolved, so it needs no call
of its own. A path the scene does not have leaves the field alone and says so in the log,
rather than binding something wrong.

`Child` still type-checks better -- the field says what it is, and `bind_nodes` infers it
from the field -- so prefer `Child` unless you want the whole set named in one block.
Either way, if you need the field *before* `_ready` -- inside `_enterTree`, say -- call
`godot.bindNodes(self)` yourself at that point; both mechanisms resolve at `_ready` and
neither can help code that runs earlier.

## "I need the autoload"

```zig
bus: Autoload(EventBusNode, "EventBus") = .pending,
```

The name from `project.godot`. It is a `Child` at `/root/Name`, so everything above applies.
Ordering does not matter: every autoload is in the tree before any of their `_ready` run.

## "I need to hold on to an object"

`Gd(T)` owns a reference, `*T` borrows one. That distinction is the whole convention, and it
is what signatures mean:

* a method **returning** a refcounted class gives `?Gd(T)`, and you owe a `deinit`
* a method **taking** one takes `*T`, and you keep ownership
* `Gd.borrow` takes a reference to something you did not own; `Gd.adopt` takes over one that
  is already yours

`Weak(T)` is for a pointer that may outlive its object -- a back-reference, a node someone
else owns. `get` re-asks the engine and answers null once it is gone.

## "I need an exported resource"

Say `Gd`, not a pointer:

```zig
card_scene: ?Gd(PackedScene) = null,
```

gdzig references what it is given and releases it at teardown. A `?*PackedScene` is a borrow,
and the resource can die underneath it -- which shows up later as a scene with no path and no
nodes.

Passing one needs nothing at all -- a class parameter takes the handle and borrows it:

```zig
sprite.setTexture(tex);          // not tex.get()
coro.awaitSignal(tween, Tween.Finished);
```

The handle keeps its reference and still owes a `deinit`. This works in argument
position only: `tex.get().someMethod()` stays, because Zig has no way to forward
a wrapped type's methods -- `usingnamespace` is gone and a comptime-built type
cannot carry declarations.

Read one with `gd.get`, which unwraps the optional and borrows in one step:

```zig
if (gd.get(self.card_scene)) |scene| _ = scene.instantiate(.{});
```

Spelled out that is `if (self.card_scene) |handle| handle.get()`, which says the same thing
twice at every read site.

## "I need to wait"

```zig
coro.wait(self.base, 0.4, .{});
coro.awaitSignal(tween, Tween.Finished);
```

Straight-line, in place of a timer and a second function to receive its timeout. Windows only
for now; `coro.supported` says so at comptime.

## "I need to pass a subclass where a base is wanted"

Nothing. Every generated class parameter is `anytype` and upcasts on the way in, so
`host.addChild(player, .{})` compiles with `player` a `*CharacterBody2d`.

You still write `upcast` where a *declared type* demands it -- a struct field typed `*Node`, a
`const x: *Node =`, or `Variant.init(?*Node, ...)`. Zig has no implicit pointer coercion and a
struct field cannot be `anytype`, so those stay.

## "Do I need `upcast` to call an inherited method?"

No. The bindgen re-emits every inherited method onto each generated class with the concrete
receiver type, so `self.base.getViewport()` resolves even though `getViewport` belongs to
`Node`. `Node.upcast(self.base).getViewport()` compiles and does exactly the same thing; it is
noise, and it is the most common thing to write by mistake.

Where it is not noise:

* **your own classes** -- a plain Zig struct, with nothing flattened onto it. `Object.upcast(self)`
  is the way to the engine object, or `gdzig.call(self, "name", .{})` to skip naming it.
* **generic code** -- an `anytype` may be holding a user struct, which is not the object.
* **a declared type** -- a field typed `*Node`, a `const x: *Node =`, `Variant.init(?*Node, ...)`.

`castTo` is the other direction and can fail, so it is never noise. It answers null when the
object is not a `T`.

## "This handler is given a `Node` and I want my own type"

Declare the type you want:

```zig
pub fn onBodyEntered(self: *Player, body: ?*Area3d) void {
    const area = body orelse return; // not an Area3D; nothing to do
```

Object arguments are narrowed on the way in, engine classes and yours alike. Optional says a
mismatch is a case and gives you null; non-optional says it is an error, and the call is
rejected rather than handing the body a pointer typed as a class the object is not.

## "I need a class"

Just fields and whatever the class actually does. No `register` boilerplate required!

```zig
const MyNode = @This();
allocator: Allocator,
base: *Node,
```

`create`, `recreate` and `destroy` are written for you when the class has those two fields.
Declare one to override it -- a class with something to release writes its own `destroy` and
gets the other two free. A field with no default means writing `create` yourself, because the
synthesized one initialises the struct in one go.

To register your classes, list them in your entry module (`src/main.zig`) using `registerAll`:

```zig
const nodes = .{ MyNode, PlayerNode };

pub fn register(r: *Registry) void {
    r.registerAll(nodes);
}

pub fn unregister(r: *Registry) void {
    r.unregisterAll(nodes);
}
```

If a class needs a custom registration (e.g., an EditorPlugin), simply define `pub fn register(r: *Registry) void` and `pub fn unregister(r: *Registry) void` on the class itself. `registerAll` will detect and call them instead of using `autoRegister`.

## "I need to extend the editor"

```zig
r.addEditorPlugin(ToolPlugin, r.allocator, .auto);
```

Descending from `EditorPlugin` is not enough: Godot has to be told by name, once the class is
in ClassDB. This does that, and forces the editor initialization level, since a plugin
registered at any other level is one the editor never sees.

`example/src/ToolPlugin.zig` is a working one. Note that it is only reachable from an editor
run -- `zig build run` does not register it, which is the point.

## "I need a name Godot understands"

`godot.name("walk")` interns once per literal and hands back a copy you must not destroy.
`godot.path("Player/Camera")` does the same for a `NodePath`. Method names, property names,
groups, animations.

Every parameter that wants a name is `anytype` and will coerce a plain Zig string, so
`node.setName("walk")` compiles and reads better. Know what it costs before putting one in
`_process`: coercing a literal builds a `StringName` and destroys it again, which is two
engine calls that no optimiser can remove.

| | ReleaseFast |
|---|---|
| `godot.name("walk")` | ~0 ns |
| coercing `"walk"` | 77 ns |

Measured over 200k iterations against 4.7.1. Once per `_ready` the literal is fine and
clearer. Per frame, per node, it is the difference worth knowing about.

A decl literal -- `.interned("walk")` -- works only where the target type is known, such as
`const clip: StringName = .interned("walk")`. In argument position there is no type for it to
resolve against, because the parameter is `anytype`.

## "I need to load something"

`godot.res(Texture2d, "res://icon.png")` gives `?Gd(T)`. 

If your `build.zig` defines `godot_project` (which it does if you use the flat layout), `godot.res` uses Zig's compile-time reflection to read the Godot project and statically assert that the asset exists on disk. If you rename or delete `icon.png`, `godot.res` immediately generates a `@compileError` so you never ship a broken game. 

If you are loading dynamic paths (e.g., from player data), use `godot.load(T, path)` which handles it purely at runtime:

```zig
var my_scene = godot.load(PackedScene, dynamic_path) orelse return;
```

## "I need to connect a signal"

```zig
toggle_btn.connect(Button.Toggled, self, &onToggled);
```

gdzig hooks into Zig's compile-time reflection to validate your handler's signature. `Button.Toggled` requires a boolean indicating state, so `onToggled(self: *GuiNode, toggled: ?bool)` is validated before the extension even builds. You will never encounter Godot's runtime `Method expected X arguments, received Y` crash again.

**Connecting to free functions and lambdas:**
If you want to connect a signal to a simple Zig function that isn't attached to a class, use `godot.callable`:

```zig
fn myFreeFunction(self: *GuiNode) void {
    self.clicks += 1;
}

// ...
const cb = godot.callable(self.allocator, self, myFreeFunction);
free_btn.connectCallable(Button.Pressed, cb);
```

`godot.callable` handles all GDExtension boilerplate and dynamically unwraps Godot `Variant` arguments into your Zig parameter types securely at runtime.

## "I need Godot Arrays and Dictionaries"

Godot's native Array and Dictionary APIs are verbose in GDExtension. gdzig provides macros to build them effortlessly from Zig literals:

```zig
var my_array = godot.array(.{ 42, 100, "hello" });
defer my_array.deinit();

var my_dict = godot.dict(.{ .name = "Player", .health = 100 });
defer my_dict.deinit();
```

## "I need to print to the Godot console"

Printing to Godot's built-in console (and ensuring it properly formats variables) usually requires manually constructing `Variant`s and `String`s. gdzig gives you a macro that wraps Zig's native `std.fmt` formatting system:

```zig
godot.print("Player {s} took {d} damage", .{ player_name, damage });
```

This acts as a drop-in replacement for `std.debug.print` but flawlessly outputs to the Godot Editor Output console. Under the hood, it uses a massive static buffer, so it is 100% fast and allocation-free!

## "I need Enums in the Godot Inspector"

If you export a Zig `enum` as a property, gdzig's reflection will automatically detect it and generate a `PROPERTY_HINT_ENUM` metadata string for Godot. This gives you a seamless dropdown in the Godot editor, perfectly mapped to your Zig enum variants without any extra configuration!

```zig
const PlayerState = enum { idle, walking, jumping };
// ...

// Automatically becomes an Inspector dropdown!
state: PlayerState = .idle, 
```

## "I need to iterate without restarting Godot"

Godot supports native hot-reloading for GDExtensions, but managing it can be finicky (especially when a crash leaves behind locked `~name.dll` files).

gdzig gives you `zig build watch`. It recursively watches your `src/` directory, automatically cleans any stale crash artifacts, instantly rebuilds the extension upon save, and can even automatically launch and restart your Godot project if it crashes. Iterate fearlessly!

**Surviving Hot-Reloads:**
When Godot hot-reloads your DLL, it preserves exported properties but destroys any internal state in your Zig structs (like timers or temporary counters). gdzig provides `godot.autoPersist(self)` and `godot.autoRestore(self)` to seamlessly save and restore your struct's private state to Godot's metadata during DLL swaps. Put `autoRestore` in your `recreate` and `autoPersist` in your `destroy`!

```zig
clicks: i32 = 0, // We want this internal state to survive hot-reload!

pub fn recreate(self: *MyNode, allocator: *Allocator) !void {
    // ... basic setup ...
    godot.autoRestore(self); // Restores `clicks` from before the DLL swap
}

pub fn destroy(self: *MyNode, allocator: *Allocator) void {
    godot.autoPersist(self); // Saves `clicks` right before the DLL swap
    // ... teardown ...
}
```

## Also worth knowing

* [memory.md](memory.md) -- allocators, and which side owns what.
* [threading.md](threading.md) -- engine calls are safe from any thread, the scene tree is not.
* [instance-binding-identity.md](instance-binding-identity.md) -- how a cast to one
  of your own classes knows what it is looking at, and three ways that do not work.
