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

**The audit, done.** Scanning hand-written `src/` for `var` declarations with no enclosing
`fn` gives 35 candidates, of which 26 are false positives -- slots inside `test` blocks in
`class/vtable.zig` and accumulators inside `comptime` blocks, neither of which is runtime
state. The nine that are:

| Static | Classification | Enforced by |
|---|---|---|
| `StringName.interned` | must reset | `releaseInterned` at exit |
| `coro.live_count` | must be empty | `cancelAll` at exit |
| `coro.current` | must be empty | implied by the above, non-null only mid-resume |
| `coro.main_fiber` | may persist | `spawn` re-derives it via `IsThreadAFiber` |
| `class.gpa`, `pool`, `pool_lock` | must persist | no teardown, deliberately -- Godot owns them |
| `entrypoint.registry` | must reset | `registry.deinit()` at exit |
| `gdzig.raw` | repopulated | `enter` assigns it every init |
| `gdzig.version`, `Version.current` | repopulated | same |
| `testing.allocator_instance`, `registry` | not shipped | test builds only |

Two of these were already right without anyone having planned it. `main_fiber` re-derives
correctly on a reloaded library because `spawn` checks `IsThreadAFiber()` before converting,
and `raw`/`version` are reassigned by the entrypoint on every initialize rather than only the
first.

The only thing the audit found unenforced was the coroutine count, which now reports at
teardown. It reports rather than refusing or cancelling, because that choice is stage 3.

The `StringName` cache is done -- see hazard 1, which had the danger backwards. The cost of
being releasable landed smaller than feared: the list node lives inside the per-literal
static, so interning still allocates nothing and pays one push the first time each literal is
used.

Worth recording beside it: the panic's backtrace named `~example.dll`. Windows cannot delete
a loaded library, so Godot renames the old one and the old module stays mapped. Hazard 1's
"not unloaded" branch is filed above as a Linux glibc problem that gdext works around. It
happens on Windows too, by design.

### 3. Coroutines parked at teardown, done

The stage was written as a policy choice -- refuse the reload, or cancel every parked
coroutine. It is not a choice: `deinitialize` returns `void`. Only *initialize* returns a
`GDExtensionBool`, so an extension has no way to decline being unloaded. Cancelling is the
only answer the interface leaves room for.

`cancelAll` walks a new intrusive list of live coroutines and drops each. Frames are abandoned
where they parked: Zig has no unwinding, so their `defer`s do not run and whatever a body
still held is leaked. That is inherent in killing a fiber, and better than resuming into an
unmapped library. The entrypoint reports the count when it is not zero.

The part that needed real surgery was not the cancelling but the disarming. A parked
coroutine is reachable from a `Waiter` owned by the resume callable, and the link ran only
that way -- so cancelling left the callable pointing at a destroyed coroutine, and the next
emission of that signal would resume it. `Coro` now holds the way back, and `cancelAll`
claims the waiter through it before destroying anything, which is what `Waiter.take` already
existed to do.

Joiners are deliberately not woken. They are in the same list and about to be cancelled too;
resuming one would run its body in the library being unloaded.

Two tests, in `test/fiber`, which is the useful part: none of this needs a reload to
exercise. Removing the waiter claim fails both and takes the test process down with it, which
is what the missing disarm does in production.

### 4. The Linux `dlclose` problem

Only after 1–3, and only if Linux reload is in scope. gdext's workaround is a known-good
reference; the failure it prevents is hazard 1's second branch.

### 5. Detect incompatible class changes, done

`recreate` is now wrapped rather than handed to the engine raw, and the wrapper checks that
the live object really is an instance of the base the class declares.

Only a reload can fail this, and only a reload makes it meaningful: the class is the one the
*new* library declares while the object was built by the old one. Change a class from `Node`
to `Control` and every `recreate` reinterprets the old object as the new base -- the
`@ptrCast` each one performs cannot notice, because that is what a cast is.

Reported, not fatal. A panic here takes the editor down in the middle of a reload, which is a
worse answer to "you edited a base class" than an error naming the class and the base it now
expects. The names are shortened to the ones Godot shows, since `@typeName` gives
`class.node.Node`.

Verified by inverting the condition for one run: it fires `ConfigNode declares a base of
Node`, so the wrapper is reached during a reload and resolves the declared base correctly.
With the condition the right way round, the harness's four reload cycles produce none.

## Non-goals

* Reloading with a changed `extension_api.json`. A Godot upgrade is a restart.
* Preserving plain (unexported) field values. That is not the GDExtension model, and
  pretending otherwise would hide the property/field distinction that stage 1 asserts.

## Open

Stage 4 is the only stage left, and its framing needs revisiting before it is worth doing:
stage 1 found that the library staying mapped is not a Linux glibc quirk but the ordinary
case on Windows, where a loaded DLL cannot be deleted and Godot renames it instead. What
gdext works around on one platform may want handling on both, or may want nothing now that
the interned cache no longer hands the engine pointers into our rodata.

Stage 1 is done, so the hazards are no longer all inference: the free-after-reload panic and
the still-mapped old module are reproductions. Hazards 1 (the `StringName` cache), 2 (parked
coroutines) and 5 (level asymmetry) are still read off the source, and the harness is now the
place to settle each of them, as a check that fails before the fix and passes after.
