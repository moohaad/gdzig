# Dodge the Creeps

The [godot-rust demo][upstream] of the same name, ported to gdzig. The Godot
project under `godot/` is the original — same scenes, same art, same MIT
licence — with `rust.gdextension` swapped for `dodge.gdextension`. Only the
extension code changed, so the two ports are directly comparable.

[upstream]: https://github.com/godot-rust/demo-projects/tree/master/dodge-the-creeps

```sh
zig build run
```

The first run needs Godot to import the assets; `zig build run` handles that,
but if you invoke Godot yourself, do an `--import` pass first.

## Layout

| | |
| --- | --- |
| `src/Main.zig` | game loop: spawns mobs, tracks score, ends the round |
| `src/Player.zig` | eight-way movement, clamped to the screen |
| `src/Mob.zig` | an enemy that frees itself once off-screen |
| `src/Hud.zig` | score, messages, start button |
| `src/nodes.zig` | `nodeAs`, the equivalent of `get_node_as::<T>` |

## What differs from the Rust version

Three of these are gdzig gaps rather than stylistic choices, and they are the
interesting part of the comparison.

**Handlers connected from code must still be registered.** godot-rust's
`connect_other(&main, Self::game_over)` needs no `#[func]`. gdzig's
`Callable.fromClosure` finds the handler by scanning the type's *public* decls
and then asks Godot whether the method exists, so every closure-connected
handler has to be both `pub` and passed to `addMethod`. Forgetting either is a
runtime panic, not a compile error.

**No `OnReady`.** godot-rust defers a field's initialiser until the node enters
the tree. gdzig has no equivalent, so `Main` resolves its children in `_ready`
and stores them as `Weak` handles — they belong to the scene tree, and a plain
pointer would not say so.

**No typed signal accessors.** `self.signals().hit().emit()` becomes
`self.base.emit(Hit, .{})`, where `Hit` is a struct type. Type-checked, but the
connection side is a closure rather than a named signal object.

**No methods on your own type.** `self` is a plain Zig struct, so signals and
engine calls go through `self.base`: `self.base.emit(Hit, .{})` rather than
godot-rust's `self.signals().hit().emit()`. gdzig does not inject anything into
your struct, which is why the `base` field is spelled out everywhere.

You do *not* need to upcast to reach an inherited method, though -- see below.

Two smaller notes, both places where the port initially went wrong:

* `StringName.fromComptimeLatin1` returns a cached **static** name. Deiniting it
  drops a shared refcount, and Godot reports `Unreferenced static string to 0`
  once per frame. `fromLatin1` is the owned one that does need releasing.
* Engine classes downcast with `T.downcast(node)`; a class defined here is a
  plain struct reached through `asInstance(T)` on its base. `nodeAs` picks
  between them with `comptime isStructClass`.
* **Upcasting to call an inherited method is unnecessary.** bindgen flattens
  every inherited method onto every class, so `Area2d` already has `hide`,
  `getNode` and `setGlobalPosition`, and `CollisionShape2d` already has
  `setDeferred`. The first draft of this port wrote
  `CanvasItem.upcast(self.base).hide()` out of C++ habit; `self.base.hide()` is
  the same call. Upcasts are still needed to *pass* a value where a base type is
  expected, which is why `addChild(Node.upcast(mob.base), .{})` keeps one.

## Known issues

**The first editor run segfaults on exit.** The run that imports assets --
`--import`, or the first `--editor` on a fresh checkout -- finishes its work
correctly and then crashes at shutdown. Import output is valid and every run
afterwards is clean, so in practice you import once and forget it.

This is gdzig, not the demo, and not the port:

| | result |
| --- | --- |
| no `.gdextension` at all | clean |
| extension registering **zero** classes | clean |
| extension registering **one trivial** class | segfault, 3/3 |
| gdzig's own `example/` project | segfault |
| second editor run, assets already imported | clean |

gdzig's own lifecycle completes before the crash. Tracing it shows one load
cycle -- entrypoint, `enter` 0..3, the editor instantiating and freeing the
class once, `exit` 3..0 -- with no reload, and the crash lands after the final
`exit(0)` returns. Skipping `registry.deinit()`, skipping the instance-binding
pool cleanup, and skipping `unregister` each leave it unchanged.

So the fault is in Godot's teardown after gdzig has handed control back, and it
needs both a registered class and a fresh import to appear. Localising it
further wants a native debugger, which is where this stopped.

**Quitting while a sound is playing leaks the stream.** Godot reports
`AudioStreamWAV` and `AudioStreamPlaybackWAV` leaked, each with one reference,
plus `res://art/gameover.wav still in use`. It is the engine's shutdown path,
not this port:

| quit after | leaks |
| ---: | ---: |
| 20 frames (before playback starts) | none |
| 40 frames (mid-playback) | 2 |
| 600 frames (playback finished) | none |

The same code plays the same sound in all three; only whether audio is still
running at exit changes. Mobs were ruled out first -- instrumenting `_ready` and
`destroy` showed six created and six destroyed. Nothing here holds a reference
to a stream, and removing the two `play` calls removes the leak entirely.

Not cross-checked against the Rust original, so "engine, not gdzig" rests on
that timing correlation rather than on a side-by-side run.

## What using gdzig for real turned up

Porting this found a bug in gdzig's own `Weak(T)`, which is the point of doing it
rather than writing another synthetic example. `Main` stores its children as
`Weak` handles; `Weak.init` cast the pointer straight to a Godot object, which is
right for an engine class and wrong for a class defined in an extension, where
the object is the `base` field. Every handle here was dead on arrival, `get()`
returned null, and because the connect calls sat behind `if (h.get()) |live|`
they were skipped in silence -- no music, no player, no game. The fix and a
regression test are in `src/weak.zig` and `test/weak`.

Two things made that harder to find than it should have been, both worth
avoiding in your own code: `catch {}` on `connect`, copied from `example/`, threw
away the only error that would have pointed at it; and a `Weak` handle that is
non-null but dead reads as "present" at a glance. The connect calls here log
their errors now.
