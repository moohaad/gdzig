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

**4. Registration lifecycle. Handled.** Unregistering was the extension's job, and an
extension with no `unregister` at all is legal. Anything missed stayed in Godot's ClassDB with
its callbacks in a library about to go, and its rpc table pointing into an arena about to be
freed -- invisible on a plain shutdown, because the process ends, and fatal on a reload.

`Registry.deinit` now sweeps what is left: for each class it registered, in reverse so an
inheritor goes before its parent, it asks ClassDB whether the class is still there and tears
it down if so. Asking rather than tracking a flag, because the same answer covers "the
extension already removed it" and cannot fall out of step.

Measured by leaving one class deliberately unregistered. With the sweep it fires once per exit
cycle and the harness passes 23 checks. Without it, Godot answers `Attempt to register
extension class 'ConfigNode', which appears to be already registered` and the harness collapses
to 4 checks and a failure.

gdext records that Godot "erases all GDExtension instance bindings, effectively changing them
to the base classes" during a reload, and separately that a class changing base type across a
reload (`RefCounted` -> `Node`) is a case to detect rather than crash on -- the latter is
stage 5.

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

**Reloading *changed* code, which is the actual feature.** Everything above reloads the same
binary. That proves the machinery, not the workflow, so the harness now also stages a second
build and swaps it in: `ConfigNode.buildTag` returns a value the code decides, unlike an
exported property, which Godot serialises and replays and which would therefore survive a
stale library.

It works. The tag reads 1, the file is replaced, the reload reports OK, and a fresh instance
answers 2.

The swap succeeding on Windows is worth understanding rather than being surprised by. A
loaded DLL cannot be overwritten -- but by then the loaded module is `~example.dll`, because
Godot renamed it on the first reload, so `example.dll` on disk is a file nobody holds open.
The rename that looked like a hazard in stage 2 is the thing that makes the workflow possible.

Staging a second build cannot be done from inside the driver, so that half skips with a
message when `lib/next.dll` is absent, and the recipe is in the driver's header. The install
step reinstalls the first build before every run, so the check is idempotent.

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

### 4. The Linux `dlclose` problem, closed without code

Not implemented, deliberately. The reasoning, so nobody has to rederive it:

**What gdext's workaround does.** It overrides `__cxa_thread_atexit_impl` in the extension.
glibc pins a library that registers a TLS destructor -- `dlclose` becomes a silent no-op --
and Rust's std registers them, so a gdext library would otherwise never unload. The override
intercepts the registration so the pin never happens.

**gdzig does not trigger it.** No `threadlocal` anywhere in hand-written `src/`, and nothing
registering `atexit` or `__cxa_thread_atexit_impl`. Zig has no destructors, so there is
nothing wanting a TLS destructor in the first place.

**And it no longer matters either way.** The workaround exists so that statics reset, because
gdext's correctness depends on the unload happening. gdzig's no longer does: the audit above
classified every static and the exit path now handles each explicitly -- interned names
released and returned to untouched, coroutines cancelled, the registry swept and deinited,
`raw` and `version` reassigned on the next init, the binding pool deliberately left alone
because Godot owns it. Nothing waits for an unload to clean up after it.

**That case is already tested, on Windows.** A loaded DLL cannot be deleted, so Godot renames
it and the old module stays mapped -- which is precisely the "library did not unload" scenario
this stage is about. Four reload cycles in `example/` and four in the game pass with it
resident, and stage 1's changed-code check shows the new build is still what answers.

**What is not established.** No Linux machine here, so none of this is measured on the
platform in question, and Zig's std or libc could in principle register a TLS destructor
indirectly in a way a source grep does not see. If Linux reload is ever taken up seriously,
the thing to measure first is whether the library actually unloads -- and if it does not, the
Windows evidence says that is survivable rather than fatal.

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

Every stage is closed: 1, 2, 3 and 5 with code and a check that fails without it, 4 with a
decision recorded above.

### The editor's own watcher: measured, and not automatable

The harness reloads by calling `GDExtensionManager.reload_extension`. A developer does not:
they rebuild and look at the editor. That trigger was the last coverage gap, and it turns out
to be unreachable from a headless process.

Measured, not assumed. With a headless editor running and the library genuinely replaced
underneath it -- `example.dll` verified to change from one build to another -- the editor ran
3000 further frames and logged nothing but its initial `Verifying GDExtensions...`. Asking for
a rescan explicitly does not help either: `EditorInterface.get_resource_filesystem().scan()`
is reachable in `--editor --script` mode, and 600 frames of polling afterwards still see the
old build answering.

So the reload is not filesystem-scan driven. It is driven by something headless never
receives, and application focus is the obvious candidate -- the editor rescans when you
alt-tab back to it. That makes this path unautomatable here rather than broken: the mechanism
underneath it is the same `reload_extension` the harness exercises from every angle.

Checking it by hand, which is the only way:

1. Open `example/project` in a real editor.
2. Edit `ConfigNode.buildTag` to return something else, and `zig build`.
3. Switch away from the editor and back.
4. The reload should be visible in the editor's output, and a new instance should answer with
   the new value.

### Also still open

Windows only. And hazard 3 -- the utility function-pointer caches in the generated
`general.zig` -- remains "probably fine" for the reason it always was: they point into Godot,
which does not reload. Nothing has contradicted that, and nothing has confirmed it.
