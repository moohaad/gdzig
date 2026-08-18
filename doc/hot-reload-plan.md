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

**1. The comptime `StringName` cache.** `src/builtin/string_name.zig:2958` keeps one
`var value: StringName` per literal, published through an atomic state machine. Every entry
holds an engine handle, and there are hundreds of them. Behaviour splits on whether the OS
actually unloads the library:

* *Unloaded* — statics reset to zero, the cache rebuilds, and every previously interned
  `StringName` leaks, since nothing ran `deinit` on them.
* *Not unloaded* — the statics survive, holding handles minted before the reload.

The second is the dangerous one and it is not hypothetical: it is precisely what gdext works
around on Linux (`sys::linux_reload_workaround::default_set_hot_reload()`), where glibc's
`thread_atexit` can make `dlclose` a no-op.

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

### 1. Make a reload observable

Everything else is unfalsifiable without this, and it is the expensive stage, so it goes
first rather than last.

Reload is editor-driven, which the existing `--headless` test harness cannot express. Options,
cheapest first: drive the editor with `--editor --headless` and touch the library on disk;
failing that, call the reload path directly through the extension API from a test; failing
that, a documented manual procedure with a checklist, which is worth having even after an
automated version exists.

The assertion that matters is not "it did not crash" but "an instance kept its exported
property, its plain field reset, and the object count returned to where it started".

### 2. Audit and reset module state

Enumerate every module-level `var` under `src/` (excluding generated `src/class/`), and
classify each: must reset, must persist, must be empty. Then give the entrypoint a teardown
that enforces the classification at `deinitialize`.

The `StringName` cache is the centrepiece and needs a structural change: today an entry is
unreachable once written, so draining it means threading every entry onto a registry as it is
created. That cost is paid on every extension, reload or not, which is worth weighing.

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

Nothing here has been tested against a running reload — the hazards are read off the source
and off gdext's handling of the same problems, not off a reproduction. Stage 1 exists to
replace that inference with measurement, and may reorder everything after it.
