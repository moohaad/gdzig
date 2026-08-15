# Threading

Godot is a partly thread-safe engine. gdzig's job is to not be the thing that
breaks first, and until now it was: a worker thread that followed every one of
Godot's rules still raced gdzig's own internals, because *any* engine call
touches a lazily initialised cache.

That is fixed. This document says what gdzig now guarantees, what Godot
guarantees, and what is left to you.

## What gdzig guarantees

Calling into the engine from a non-main thread does not race **gdzig's own
state**. Everything gdzig initialises lazily on first use is atomic:

| state | ordering |
| --- | --- |
| method-bind, builtin-method, operator, constructor, destructor and utility-function caches | monotonic load/store |
| singleton pointers (`Engine.instance` and friends) | monotonic load/store |
| the per-literal `StringName` cache | acquire/release once |
| the instance-binding pool and its allocator | spin lock |
| the per-instance dispatch-depth counter | monotonic add/sub |

Monotonic is the right ordering for the caches because the race is
value-benign: two threads that both miss compute the *same* pointer, so all
that is required is that the load and store are neither torn nor reordered
into undefined behaviour. On x86-64 the emitted instructions are identical to
the plain load and store this replaced — no lock prefix, no fence.

`StringName` needed the stronger pair. There the failure is a half-written
value published to a second thread, which is a crash rather than a duplicated
lookup.

**Registration is not on this list.** `createClass`, `addMethod`, `addSignal`
and friends mutate a registry with no locking. Godot calls your
`initialize`/`deinitialize` hooks on the main thread at each initialisation
level, and gdzig assumes that; do not register from a worker.

## What Godot guarantees

gdzig does not change any of this, and it is the part that actually constrains
your program. In outline, and as of Godot 4.7:

* The **servers** — Rendering, Physics, Navigation — are thread-safe. They take
  commands from any thread and queue them.
* The **scene tree is not**. `Node` and anything reached through it belongs to
  the main thread.
* **Resource loading** has its own threaded API (`ResourceLoader`'s threaded
  request/status/get trio) rather than being safe to call concurrently.

See [Using multiple threads][godot-threads] for the authoritative version. When
gdzig's guarantee and Godot's disagree, Godot's wins: gdzig makes the *binding*
safe to call, not the engine method behind it.

[godot-threads]: https://docs.godotengine.org/en/stable/tutorials/performance/using_multiple_threads.html

## What is still yours

**Two threads touching one extension instance.** gdzig has no borrow cell and
does not serialise access to your struct's fields. If you share an instance,
you synchronise it. This is where C++ leaves it too, and where godot-rust
leaves it unless you opt into `experimental-threads`.

**Cross-thread aliasing is not detected.** gdzig panics if you free an object
while a dispatch into it is on the stack, because that is never correct. It
deliberately does *not* flag two threads dispatching into one object, because
that one has legitimate uses and a detector would cry wolf.

## The pattern

Compute on the worker, apply on the main thread. `Callable.callDeferred` is the
seam:

```zig
/// Runs on a WorkerThreadPool thread.
fn work(self: *Sim) void {
    self.result = expensive(self.input); // no scene tree here
    const apply: Callable = .fromClosure(self, &onWorkDone);
    apply.callDeferred(.{});
}

/// Runs on the main thread, at idle time.
pub fn onWorkDone(self: *Sim) void {
    if (self.label.get()) |live| live.setText(self.result);
}
```

`onWorkDone` has to be `pub` and registered with `addMethod`, for the same
reason any `fromClosure` handler does — the lookup is by function address over
public declarations, and Godot has to know the method by name to invoke it.

To get onto a worker in the first place, `WorkerThreadPool` is bound with a
native-function overload that skips the `Callable` round trip:

```zig
pool.addNativeTaskWithUserdata(Sim, &work, self, false, null);
```

## Where this stops

gdzig is safe to *call* from a worker thread. It does not make extension
instances safe to *share*, and there is no plan to port godot-rust's blocking
cell.

Verification is honest about its limits. The pool lock and the `StringName`
once are small enough to argue from the code. The atomic caches are not
verifiable here in any strong sense — there is no ThreadSanitizer on this
platform, and a stress test can show a crash but never the absence of a race.
The argument for that change is the language rule, not a test.
