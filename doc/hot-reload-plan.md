# Plan: hot reload

Reloading an extension without restarting the editor. godot-rust has this and gdzig does
not, which is the largest daily-workflow gap between them.

The starting position is not zero, and not obviously safe either:

* `addExtension` already emits `reloadable = true`, so **Godot is already attempting to
  reload gdzig extensions today**.
* `.recreate` is already wired (`src/extension/class.zig:295`), and every class in `example/`
  and the demos implements it.
* Nothing has ever tested a reload, and several module-level caches hold engine handles
  across the boundary.

So this is not "build hot reload". It is "something already happens; find out what, make it
correct, and prove it". The ordering below follows that.

## What already works, and what it means

`recreate` allocates a fresh instance, points it at the surviving base object, and rebinds:

```zig
pub fn recreate(allocator: *Allocator, obj: *Object) *ConfigNode {
    const self = allocator.create(ConfigNode) catch @panic("OOM");
    self.* = .{ .allocator = allocator.*, .base = @ptrCast(obj) };
    self.base.setInstance(ConfigNode, self);
    return self;
}
```

It restores no field values, and that is correct rather than a bug. Godot serialises
*exported properties* across a reload and replays them through the setters, so a registered
property survives; a plain field returns to its default. Worth stating outright, because it
inverts what people expect: the thing that looks unhandled is handled, and the thing that
looks like ordinary state is not.

## The hazards, with evidence

**1. The comptime `StringName` cache. Fixed, and not what this said.** The entry was
interned *static*, and `p_is_static` does not mean "long-lived": per the interface header it
means the engine **reuses the caller's buffer instead of copying it**, and the caller must
"guarantee that the buffer remains valid for the duration of the application". That buffer is
`str.ptr`, in this library's rodata, which a reload unmaps while the engine goes on pointing
at it. The header calls the flag "purely an optimization" that "can easily introduce undefined
behavior if used wrong".

So the hazard ran the other way from how it is described below: not our cache holding stale
engine handles, but the engine holding pointers into our unloaded library. And the drain
proposed in stage 2 would itself have been a bug, because a static name must never be
destroyed -- that is the `Unreferenced static string to 0` failure this cache already carries
a comment about.

Interning is now a copy, which costs one short memcpy per literal, once, and makes the cache
releasable. `releaseInterned` walks an intrusive list and returns each entry to untouched.
Measured at 37 names released per reload cycle, which is what used to leak each time.

**2. Parked coroutines.** `src/coro.zig` holds `current`, `main_fiber` and `live_count` at
module scope. A parked coroutine owns a stack whose return addresses point into the library
about to be unloaded. Reloading with one live is unrecoverable, and silent.

**3. Utility function-pointer caches.** `src/general.zig` caches `weakref_ptr`, `typeof_ptr`
and `typeConvert_ptr` in atomics. These point into Godot, which does not reload, so they are
*probably* fine — but "probably" is the reason they are on this list.

**4. Registration lifecycle.** Classes must unregister on `deinitialize` and re-register on
`initialize`. gdext records that Godot "erases all GDExtension instance bindings, effectively
changing them to the base classes" during a reload, and separately that a class changing base
type across a reload (`RefCounted` -> `Node`) is a case to detect rather than crash on.

**5. Levels are not symmetric.** From gdext: with editor plugins, "Godot may unload all levels
but only reload from Scene upward". An entrypoint that assumes `initialize` and `deinitialize`
pair up per level will be wrong.

## Stages

### 1. Make a reload observable, done

`zig build reload-test`, in `example/`. Six checks, currently all passing.

Two constraints found by trying, both of which shaped the harness:

* **Reload is editor-only.** Outside the editor, `GDExtensionManager.reload_extension`
  answers `LOAD_STATUS_FAILED` and logs "GDExtension reloading is disabled". That removes the
  option of calling the reload path from an ordinary test.
* **The driver cannot live in the extension.** Reloading unloads the library, so a Zig
  assertion is unloaded mid-assertion.

Both are satisfied by a `@tool extends SceneTree` script run as
`--headless --editor --script res://demo/reload_driver.gd`, which reloads cleanly
(`LOAD_STATUS_OK`) and outlives the library because GDScript is not in it.

What the reload gets right, measured rather than assumed: the instance survives, keeps its
own class rather than degrading to the base, and its exported property still holds the value
set before the reload. The `recreate` path works.

What it gets wrong is stage 2's first item.

### 2. Audit and reset module state

**Freeing a reloaded instance panicked. Fixed.** `DestroyInstanceBinding.cleanup()` ran at
`exit()` and did `pool.deinit(allocator)`, bulk-freeing every instance binding. Godot owns
those: it asks for one through `create_callback` and hands it back through `free_callback`,
on its own schedule, which for a surviving object is long after the extension has exited.
Freeing the pool left Godot pointing at reclaimed memory, and the next read of a survivor's
binding took `dispatch_depth` out of it.

The tell was that the depth was not a plausible count and not even stable: 110, then 896,
then 47 across three runs. A real free-inside-a-method reads 1. The guard now prints the
number, which is what made that visible.

Double ownership, not a reload bug as such -- the same free was always wrong, and only looked
harmless because a normal shutdown ends the process immediately afterwards. There is now no
bulk teardown, and `free_callback` is left to do its job. The harness asserts a survivor can
be freed.

Then enumerate every module-level `var` under `src/` (excluding generated `src/class/`), and
classify each: must reset, must persist, must be empty. Then give the entrypoint a teardown
that enforces the classification at `deinitialize`.

The `StringName` cache is done -- see hazard 1, which had the danger backwards. The cost of
being releasable landed smaller than feared: the list node lives inside the per-literal
static, so interning still allocates nothing and pays one push the first time each literal is
used.

Worth recording beside it: the panic's backtrace named `~example.dll`. Windows cannot delete
a loaded library, so Godot renames the old one and the old module stays mapped. Hazard 1's
"not unloaded" branch is filed above as a Linux glibc problem that gdext works around. It
happens on Windows too, by design.

### 3. Refuse to reload with coroutines parked

`liveCount() != 0` at `deinitialize` must be loud rather than fatal-later. Two defensible
answers: refuse the reload with an error naming the count, or cancel every parked coroutine.
Cancellation is already modelled — `finish()` handles `.cancelled` and wakes joiners — so the
machinery exists; the decision is policy.

### 4. The Linux `dlclose` problem

Only after 1–3, and only if Linux reload is in scope. gdext's workaround is a known-good
reference; the failure it prevents is hazard 1's second branch.

### 5. Detect incompatible class changes

A class whose base type changed across a reload should say so. Last because it is a quality
improvement on a path that must first work at all.

## Non-goals

* Reloading with a changed `extension_api.json`. A Godot upgrade is a restart.
* Preserving plain (unexported) field values. That is not the GDExtension model, and
  pretending otherwise would hide the property/field distinction that stage 1 asserts.

## Open

Stage 1 is done, so the hazards are no longer all inference: the free-after-reload panic and
the still-mapped old module are reproductions. Hazards 1 (the `StringName` cache), 2 (parked
coroutines) and 5 (level asymmetry) are still read off the source, and the harness is now the
place to settle each of them, as a check that fails before the fix and passes after.
