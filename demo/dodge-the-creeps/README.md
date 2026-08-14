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

Two smaller notes, both places where the port initially went wrong:

* `StringName.fromComptimeLatin1` returns a cached **static** name. Deiniting it
  drops a shared refcount, and Godot reports `Unreferenced static string to 0`
  once per frame. `fromLatin1` is the owned one that does need releasing.
* Engine classes downcast with `T.downcast(node)`; a class defined here is a
  plain struct reached through `asInstance(T)` on its base. `nodeAs` picks
  between them with `comptime isStructClass`.

## Known issues

**Eight `invalid UID ... using text path instead` warnings.** Upstream's scenes
reference UIDs absent from this checkout. Printed before any Zig code runs, and
the copy is not missing files -- it has more than upstream, since Godot writes
`.import` sidecars on first run.

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
