# Plan: thread safety

gdzig has never said what it supports across threads, and does not currently
support much. This is what is broken, in what order it should be fixed, and
where the line should be drawn.

---

## The framing that matters

godot-rust's answer to threading is a second implementation of its borrow cell:
`godot-cell/src/blocking_cell.rs` wraps the same borrow tracker in a mutex and
condvar so a cross-thread borrow blocks instead of panicking. It is gated behind
a feature named `experimental-threads`.

Two things follow from that, and they set the order of work here.

**It does not make Godot thread-safe.** It serializes access to *your object's
data*. Godot's own rules are unchanged: the servers (Rendering, Physics,
Navigation) are thread-safe, the scene tree is not, and touching a node from a
worker thread needs `call_deferred`.

**gdzig has no borrow cell to make blocking.** Porting `blocking_cell` is not
the first move, because gdzig's problem is one layer down: its own globals are
not thread-safe, and they are reached by code that is following Godot's rules
perfectly.

That last point is the whole argument for this plan. A disciplined gdzig program
— compute on a `WorkerThreadPool` thread, marshal results back with
`call_deferred`, never touch a node off the main thread — still races gdzig's
internals, because *any* engine call from the worker thread touches a lazily
initialised method-bind cache, and any string literal touches the `StringName`
cache. You do not have to share an object to hit this.

---

## What is actually unsafe

Measured against the current tree.

| | count | consequence |
| --- | ---: | --- |
| lazy method-bind caches | 161,127 | data race; same value written |
| lazy builtin-method caches | 999 | same |
| lazy operator caches | 501 | same |
| lazy constructor caches | 106 | same |
| lazy destructor caches | 17 | same |
| `StringName.fromComptimeLatin1` cache | per literal | data race; **torn value** |
| `DestroyInstanceBinding` pool + GPA | 1 | **heap corruption** |
| `dispatch_depth` | per instance | torn counter, false panics |
| `raw`, `version`, `registry` | 3 | safe — written once during init |

`engine_allocator` is fine: it delegates to Godot's `mem_alloc`, which the engine
guarantees is thread-safe. gdzig's own `heap/GeneralPurposeAllocator.zig` has no
locking at all, which is what makes the binding pool dangerous.

### The three shapes

**Benign-in-value races (162,750 sites).** Every generated call does:

```zig
if (getName_ptr == null) {
    getName_ptr = raw.classdbGetMethodBind(...);
}
```

Two threads racing this compute the *same* pointer and store it to the same
word. Harmless in practice on every architecture gdzig targets, and still a data
race by the language's rules — undefined behaviour the optimiser is entitled to
act on, and something a sanitizer would flag 162,750 times, drowning any real
finding.

**A genuinely torn value.** `StringName.fromComptimeLatin1` is not benign:

```zig
var value: StringName = undefined;
var init: bool = false;
...
func(@ptrCast(&S.value), @ptrCast(str.ptr), 1);
S.init = true;
```

A second thread can observe `init == true` next to a half-written `StringName`,
and there is no ordering to prevent the store to `init` being visible first.

**Outright corruption.** `DestroyInstanceBinding` keeps a process-wide
`MemoryPool` and a non-locking GPA. Godot calls the instance-binding free
callback from whichever thread drops the object, so two concurrent frees corrupt
the pool's free list. This is the one that loses data rather than tripping a
sanitizer.

---

## Status

Phase 1 and phase 2 are done. The contract now lives in
[`threading.md`](threading.md); this file keeps the reasoning and records where
the work diverged from the plan.

Four things turned out differently:

* **The plan undercounted.** It named five emission sites and 162,750 caches.
  There were eight sites and **162,905** caches: the five, plus the vararg
  wrapper, plus the non-vararg module utility function (114), plus the
  singleton pointers (41). Singletons are the same lazy-init shape and race the
  same way, so they are in.
* **Each site keeps its own C type** inside `std.atomic.Value`, rather than the
  `?*anyopaque` the plan suggested. They are distinct optional function-pointer
  types and collapsing them would need a cast at every call.
* **The load is hoisted into a local.** Rewriting each use as
  `x_ptr.load(.monotonic)` costs a redundant reload the optimiser is not
  allowed to elide — two atomic loads must each observe memory. Reading once
  into `_bind` restores instruction-for-instruction parity with the code this
  replaced, measured on x86-64 `-OReleaseFast`.
* **Zig 0.16 has no io-free blocking mutex.** `std.once` is gone,
  `std.Thread` has no `Mutex`, `std.Io.Mutex` wants an `Io` a shared library
  with no `main` cannot supply, and `std.atomic.Mutex` is try-only. So 1.2 is a
  hand-rolled three-state once and 1.3 is a spin lock. Both critical sections
  are a single engine call or a pool slot, so spinning is the right trade.

## Steps

### 1.1 Atomic method-bind caches — done

Change the five emission sites in `pkg/bindgen/codegen.zig` (lines 192, 213,
229, 258 and 541, plus 829 for the vararg wrapper) to emit
`std.atomic.Value(?*anyopaque)` with monotonic load and store.

Monotonic is enough precisely *because* the race is value-benign: both threads
compute the same pointer, so the only requirement is that the load and store are
not torn and not reordered into UB. No lock, no acquire/release pair, and on
x86-64 and aarch64 the generated code is the same load and store it is today.

One change covers all 162,750 sites, and it is the largest item only by count.

### 1.2 Once-init for `StringName.fromComptimeLatin1` — done

Replace the `value`/`init` pair with a real once, so the string is published
after it is fully constructed. `std.once` is the obvious tool; the per-literal
`struct` that holds the cache already gives each string its own state.

This one is not optional in the way 1.1 is: the failure mode is a `StringName`
read while half-written, which is a crash rather than a sanitizer complaint.

### 1.3 Lock the instance-binding pool — done

`DestroyInstanceBinding.create` and `free` are called by the engine from
arbitrary threads. Either put a `std.Thread.Mutex` around the pool, or drop the
pool for the `engine_allocator`, which is thread-safe because Godot's allocator
is.

Preferring the second is tempting — it deletes code and the GPA-leak assert with
it — but the pool exists because these are small, frequent, uniform allocations.
Measure before trading it away.

### 1.4 Atomic `dispatch_depth` — done

The free-while-dispatching guard added in `d529321` increments a plain `u16`.
Under threads it can tear, which turns a debugging aid into a source of false
panics. `std.atomic.Value(u16)` with monotonic add and sub.

### 2 State the contract — done

gdzig currently says nothing about threads, so users cannot tell what is
supported. Document the same rules Godot documents, because they are the rules:

* engine calls from any thread are fine once 1.1–1.3 land
* the scene tree is main-thread-only; use `call_deferred`
* two threads touching one extension instance is the user's problem, exactly as
  it is in C++

### 3 Cross-thread aliasing detection — probably not

The dispatch guard already tracks depth per instance; recording the thread as
well would flag two threads dispatching into one object.

Deliberately not planned. Unlike free-while-dispatching, which is never correct,
this one has legitimate uses — an object designed for concurrent access, guarded
by the user's own mutex — so the detector would have false positives, and a
detector that cries wolf is worse than none. Revisit only with a real report.

---

## How this will be verified, and how it will not

Steps 1.2 and 1.3 are small enough to argue from the code, and that is the
intended standard of proof for them.

Step 1.1 is not verifiable here in any strong sense. There is no convenient
ThreadSanitizer on this platform, and a stress test — N threads hammering engine
calls — can show a crash but cannot show absence of races. The honest position
is that 1.1 removes UB that is currently unobservable, and the argument is the
language rule, not a test.

A stress test is still worth adding for 1.3, where the failure is a corrupted
free list and therefore *does* surface as a crash under load.

---

## Where this stops

Phase 1 and 2. That makes gdzig safe to *call* from a worker thread, which is
what Godot's own threading model asks for, and says so out loud.

It does not make extension instances safe to share, and does not attempt
godot-rust's blocking cell. Sharing an instance across threads stays the user's
responsibility, which is where C++ leaves it too.
