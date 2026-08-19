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

## "I need a class"

Fields, `register`, and whatever the class actually does:

```zig
allocator: Allocator,
base: *Node,

pub fn register(r: *Registry) void {
    r.addClass(MyNode, r.allocator, .auto);
}
```

`create`, `recreate` and `destroy` are written for you when the class has those two fields.
Declare one to override it -- a class with something to release writes its own `destroy` and
gets the other two free. A field with no default means writing `create` yourself, because the
synthesized one initialises the struct in one go.

## "I need a name Godot understands"

`StringName.fromComptimeLatin1("walk")` interns once per literal and hands back a
`*const StringName` you must not destroy. Method names, property names, groups, animations.

## "I need to load something"

`godot.load(Texture2d, "res://icon.png")` gives `?Gd(T)`.

## Also worth knowing

* [memory.md](memory.md) -- allocators, and which side owns what.
* [threading.md](threading.md) -- engine calls are safe from any thread, the scene tree is not.
* [hot-reload-plan.md](hot-reload-plan.md) -- what survives a reload, and what does not.
