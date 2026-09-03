//! Coroutines: straight-line code that waits on Godot signals.
//!
//! ```zig
//! fn goto(self: *Main, path: String) void {
//!     self.fadeTo(1.0);
//!     coro.awaitSignal(tween, Tween.Finished);
//!     tree.changeSceneToFile(path);
//!     coro.awaitSignal(tree, SceneTree.ProcessFrame);
//!     self.fadeTo(0.0);
//!     coro.awaitSignal(tween, Tween.Finished);
//!     self.busy = false;
//! }
//! ```
//!
//! This is what GDScript spells `await`, and what a hand-written chain of
//! `onFadeOutDone` / `onFrameElapsed` / `onFadeInDone` replaces it with when
//! the language has no coroutines.
//!
//! A signal that carries arguments hands them back, as the signal struct:
//!
//! ```zig
//! var hit = coro.awaitSignal(enemy, Enemy.Hit);
//! defer hit.label.deinit();
//! if (hit.damage > 0) self.flinch();
//! ```
//!
//! ## Why stackful
//!
//! Rust and C# get `await` from their compilers, which rewrite the function
//! into a state machine; godot-rust's whole async layer is then just a
//! scheduler that polls those futures on the engine's loop. Zig removed
//! compiler-generated async in 0.11, and `std.Io.async` blocks the calling
//! thread on the `Threaded` implementation -- fatal here, since blocking
//! Godot's main thread means the awaited signal can never fire.
//!
//! So each coroutine gets a real stack, against a heap struct sized to its
//! locals in Rust, or an interpreter frame in GDScript. Measured over 200
//! fibers, one costs about 19 KiB of commit charge and reserves
//! `default_stack_reserve` of address space. Fine for a handful of
//! transitions; think before giving one to every entity in a crowd.
//!
//! ## Awaiting a call
//!
//! GDScript also writes `await` in front of calls -- `await fade_to(1.0)` --
//! and that shape needs nothing here. Call the function. If it parks, it parks
//! the coroutine it is running on, which is the caller's, and the call returns
//! where it left off. Stackless languages need `await` at every level because
//! each function compiles to its own state machine; a stack composes for free.
//!
//! `spawnJoinable` and `Handle.join` are for the shape GDScript cannot write:
//! starting work that runs *alongside* the caller, and collecting it later. A
//! plain call would run to its first park before the caller did anything else.
//!
//! ## When the object dies first
//!
//! A parked coroutine holds its arguments across the park, and a node can be
//! freed while it waits -- `queue_free` halfway through its own animation is
//! ordinary. Resuming would run the rest of the body against freed memory.
//!
//! So the object arguments are noted at `spawn` (their instance IDs, read while
//! they are certainly alive) and checked before every resume. If any has been
//! freed the coroutine is dropped instead of resumed, quietly: an entity dying
//! mid-wait is normal, and an error per death would be noise. `liveCount` still
//! accounts for it, and anything joined to it still wakes.
//!
//! The guard sees arguments, so it covers the `self` a method was called on and
//! anything else passed in. It cannot see an object a body fetches *after* it
//! starts -- a `getNode` result held in a local across a park is still yours to
//! reason about. Pass objects in rather than fetching them mid-body and the
//! guard covers you.
//!
//! ## Why the dispatch guard survives
//!
//! Suspending switches stacks, so Godot's dispatch frame unwinds normally --
//! only the coroutine's own frame is parked. `DispatchGuard.enter`/`leave` stay
//! balanced, and an object suspended in a coroutine can still be freed without
//! tripping the free-while-dispatching check.
//!
//! ## Resuming
//!
//! A resume is a *custom callable* -- a native function plus userdata, created
//! through `callable_custom_create2` -- rather than a registered method. That
//! keeps coroutines out of every class's registration, and gives a `free_func`
//! hook for the case that matters: the awaited object dying while a coroutine
//! is parked on its signal.
//!
//! ## Platform
//!
//! Native targets use `zio.coro` for context switching and guarded,
//! grow-on-demand stacks. Godot still owns the event loop: gdzig only steps a
//! coroutine when it starts or when the signal it parked on is emitted.
//!
//! WebAssembly remains unsupported: wasm32 has no native stack switcher and
//! browser stack switching requires Asyncify or JSPI rather than a native CPU
//! context. Check `supported` at comptime when one source also targets Web.

const std = @import("std");
const builtin = @import("builtin");

const c = @import("gdextension");
const oopz = @import("oopz");
const gdzig = @import("gdzig");
const Callable = gdzig.builtin.Callable;
const Node = gdzig.class.Node;
const Object = gdzig.class.Object;
const RefCounted = gdzig.class.RefCounted;
const SceneTreeTimer = gdzig.class.SceneTreeTimer;
const StringName = gdzig.builtin.StringName;
const Variant = gdzig.builtin.Variant;

const supported_os = switch (builtin.os.tag) {
    .windows,
    .linux,
    .macos,
    .ios,
    .tvos,
    .watchos,
    .visionos,
    .freebsd,
    .netbsd,
    .openbsd,
    .dragonfly,
    .illumos,
    => true,
    else => false,
};
const supported_arch = switch (builtin.cpu.arch) {
    .x86_64,
    .x86,
    .aarch64,
    .arm,
    .thumb,
    .riscv64,
    .riscv32,
    .loongarch64,
    .powerpc64,
    .powerpc64le,
    => true,
    else => false,
};
pub const supported = supported_os and supported_arch;

/// Keep zio out of unsupported builds entirely: merely instantiating its
/// context type intentionally rejects CPUs without a switcher.
const zio_coro = if (supported) @import("zio").coro else struct {
    const Context = struct { stack_info: void = {} };
    const Coroutine = struct {
        context: Context = .{},
        parent_context_ptr: *Context,

        fn setup(_: *@This(), _: anytype, _: ?*anyopaque) void {}
        fn step(_: *@This()) void {
            unreachable;
        }
        fn yield(_: *@This()) void {
            unreachable;
        }
        fn deinit(_: *@This()) void {}
        fn clearCurrent() void {}
    };

    fn stackAlloc(_: *void, _: usize, _: usize) !void {}
    fn stackFree(_: void) void {}
    fn setupStackGrowth() !void {}
    fn cleanupStackGrowth() void {}
};

var main_context: zio_coro.Context = undefined;
var stack_growth_ready = false;

/// The coroutine currently executing, or null on the plain stack.
///
/// A plain global rather than thread-local: coroutines are main-thread only,
/// because that is where Godot dispatches signals. Awaiting from a worker
/// thread is not supported and would need the whole scheduler to be
/// thread-aware, not just this pointer.
var current: ?*Coro = null;

/// Physical memory a zio coroutine stack starts with. The rest is committed
/// on demand as the guarded stack grows.
pub const default_stack_commit = 4 * 1024;

/// Address space a coroutine's stack may grow into, and the hard ceiling on how
/// deep it can recurse -- past this is a stack overflow.
///
/// Generous on purpose: reserving address space is cheap, and these stacks run
/// Godot's C++, whose depth is not ours to predict.
pub const default_stack_reserve = 1024 * 1024;

var live_count: usize = 0;

/// Every coroutine that is alive, so teardown can reach them. Kept beside
/// `live_count` rather than replacing it: the count is read per frame by code
/// watching for stacks that never come back, and walking a list for that would
/// be worse.
var live: ?*Coro = null;

fn linkLive(coro: *Coro) void {
    coro.next_live = live;
    live = coro;
}

fn unlinkLive(coro: *Coro) void {
    var it = &live;
    while (it.*) |node| {
        if (node == coro) {
            it.* = node.next_live;
            coro.next_live = null;
            return;
        }
        it = &node.next_live;
    }
}

/// How many coroutines are alive, parked or running.
///
/// Each holds a stack until it finishes, so this is the number to watch when
/// coroutines are spawned from something recurring -- a count that climbs is
/// stacks that are never coming back.
pub fn liveCount() usize {
    return live_count;
}

/// Cancels every live coroutine. For an extension being torn down.
///
/// A parked coroutine owns a stack whose return addresses point into this
/// library. Once the library is gone, resuming one jumps into freed code, so at
/// teardown there is nothing to do but drop them.
///
/// Not a choice between this and refusing the unload: `deinitialize` returns
/// void, so an extension has no way to decline. Cancelling is the only answer
/// the interface leaves room for.
///
/// Frames are abandoned where they parked. Zig has no unwinding, so their
/// `defer`s do not run and whatever a body still held -- a `Gd` handle, an
/// allocation -- is leaked. That is inherent in killing a fiber, and better
/// than resuming into an unmapped library.
///
/// Returns how many were cancelled, so a caller can report it.
pub fn cancelAll() usize {
    var cancelled: usize = 0;
    while (live) |coro| {
        if (coro == current) {
            // Being torn down from inside a coroutine: this fiber is the one
            // executing and cannot delete its own stack. Drop it from the list
            // so the walk finishes; teardown leaks this one mapping rather
            // than returning through code that is being unloaded.
            unlinkLive(coro);
            live_count -= 1;
            cancelled += 1;
            continue;
        }

        // The waiter first: once claimed, the resume callable finds nothing, so
        // a signal firing between here and the unload is a no-op rather than a
        // jump into a coroutine that no longer exists.
        if (coro.waiter) |w| _ = w.take();
        coro.waiter = null;
        coro.state = .cancelled;

        // Joiners are deliberately not woken. They are in this same list and
        // about to be cancelled too, and resuming one would run its body in the
        // library being unloaded -- the thing this exists to prevent.
        const task = coro.task;
        if (task) |t| {
            t.done = true;
            t.joiners = null;
        }

        coro.destroy();
        if (task) |t| t.release();
        cancelled += 1;
    }
    return cancelled;
}

/// Removes zio's per-thread stack-growth support after all coroutines have
/// been cancelled. Extension teardown calls this before unloading gdzig so a
/// POSIX signal handler can never point back into an unmapped library.
pub fn cleanupThread() void {
    if (!stack_growth_ready) return;
    zio_coro.Coroutine.clearCurrent();
    zio_coro.cleanupStackGrowth();
    stack_growth_ready = false;
}

pub const Coro = struct {
    runtime: zio_coro.Coroutine,
    state: State = .ready,
    allocator: std.mem.Allocator,
    /// Type-erased body plus its arguments, freed once the body returns.
    frame: *anyopaque,
    run: *const fn (frame: *anyopaque) void,
    free_frame: *const fn (allocator: std.mem.Allocator, frame: *anyopaque) void,
    /// Whether the object arguments this body was given are still alive.
    owners_alive: *const fn (frame: *anyopaque) bool,
    /// Present only when spawned through `spawnJoinable`; this is what outlives
    /// the coroutine so a later `join` has something to read.
    task: ?*Task = null,
    /// Intrusive list link, threaded through the `Task` this coroutine is
    /// parked on. A coroutine can only wait on one thing at a time, so one
    /// link is enough and no allocation is needed to queue up.
    next_joiner: ?*Coro = null,

    /// The `Waiter` this coroutine is parked on, or null when it is not parked.
    ///
    /// The waiter already points here; this is the way back, and it exists so a
    /// cancellation from outside can `take()` the waiter and leave the callable
    /// with nothing to resume. Cleared on resume, because the waiter is freed
    /// shortly after and this must not outlive it.
    waiter: ?*Waiter = null,

    /// Next in the list of coroutines that are alive. Intrusive so that being
    /// enumerable costs a pointer rather than an allocation.
    next_live: ?*Coro = null,

    /// A reference to the object this coroutine is parked on, when that object
    /// is reference counted, owned for as long as the park lasts.
    ///
    /// It lives here rather than in the frame that awaited, because a frame is
    /// exactly what a dropped coroutine does not come back to. Zig has no
    /// unwinding, so a fiber reclaimed while parked never runs the `defer` that
    /// would have released the handle, and the reference is lost -- measured as
    /// a `SceneTreeTimer` retained at refcount 1 whenever a coroutine was still
    /// waiting on a timer at exit. Held by the coroutine, it is released on
    /// every ending, because every ending goes through `destroy`.
    parked_ref: ?*RefCounted = null,

    pub const State = enum {
        /// Created, not yet started.
        ready,
        /// Executing right now.
        running,
        /// Parked on a signal.
        suspended,
        /// Body returned; the fiber is waiting to be reclaimed.
        done,
        /// Whatever it waited on went away before resuming.
        cancelled,
    };

    fn destroy(self: *Coro) void {
        unlinkLive(self);
        live_count -= 1;
        self.releaseParked();
        self.runtime.deinit();
        zio_coro.stackFree(self.runtime.context.stack_info);
        self.free_frame(self.allocator, self.frame);
        self.allocator.destroy(self);
    }

    /// Drops the reference held across a park, if there is one. Idempotent, so
    /// the resume path can call it and leave nothing for `destroy` to find.
    fn releaseParked(self: *Coro) void {
        const ref = self.parked_ref orelse return;
        self.parked_ref = null;
        // The same two steps `Gd.deinit` takes, spelled out because what is
        // held here is a bare pointer rather than a handle.
        if (ref.unreference()) ref.destroy();
    }
};

/// What a `Handle` points at, and the reason it is not just a `*Coro`: this
/// record outlives the coroutine. A handle held past the body returning has to
/// be able to answer "already finished" rather than read freed memory.
///
/// Referenced by the handle and, while it runs, by the coroutine.
const Task = struct {
    allocator: std.mem.Allocator,
    refs: u8,
    done: bool = false,
    /// Coroutines parked in `join`, waiting for this one to finish.
    joiners: ?*Coro = null,

    fn release(self: *Task) void {
        self.refs -= 1;
        if (self.refs == 0) self.allocator.destroy(self);
    }
};

/// A spawned coroutine that something can wait for.
///
/// Release it exactly once with `deinit`, whether or not it was ever joined --
/// the record behind it is not reclaimed until both the coroutine has finished
/// and the handle is gone.
pub const Handle = struct {
    task: *Task,

    /// Parks the running coroutine until this one finishes, returning at once
    /// if it already has.
    ///
    /// Several coroutines may join the same handle; all of them resume. Does
    /// not release the handle -- `deinit` still has to be called.
    ///
    /// Panics if called outside a coroutine, or on a handle to the coroutine
    /// doing the joining, which would wait on itself forever.
    pub fn join(self: Handle) void {
        const coro = current orelse @panic(
            "gdzig.coro.Handle.join called outside a coroutine; there is no frame to park",
        );
        if (coro.task == self.task) @panic("gdzig.coro: a coroutine cannot join itself");

        if (self.task.done) return;

        coro.next_joiner = self.task.joiners;
        self.task.joiners = coro;
        coro.state = .suspended;

        coro.runtime.yield();
    }

    /// Whether the body has returned. False for a coroutine that is merely
    /// parked; true also for one cancelled by its awaited object dying.
    pub fn isDone(self: Handle) bool {
        return self.task.done;
    }

    pub fn deinit(self: Handle) void {
        self.task.release();
    }
};

/// Starts `func(args...)` as a coroutine and runs it until it finishes or
/// parks. Returns once one of those happens, so the caller -- usually a Godot
/// dispatch -- carries on normally.
///
/// Nothing is handed back: a coroutine that never parks is already gone by the
/// time this returns. Use `spawnJoinable` to wait for one.
///
/// Note that a coroutine does not need this to wait for *a function it calls*.
/// Calling one that parks parks this coroutine, and the call returns where it
/// left off -- that is what a stack buys over a state machine. `spawnJoinable`
/// is for the other shape: starting work that runs alongside, and collecting it
/// later.
pub fn spawn(
    allocator: std.mem.Allocator,
    comptime func: anytype,
    args: std.meta.ArgsTuple(@TypeOf(func)),
) !void {
    enter(try create(allocator, func, args));
}

/// `spawn`, but returns a `Handle` that something can `join`.
pub fn spawnJoinable(
    allocator: std.mem.Allocator,
    comptime func: anytype,
    args: std.meta.ArgsTuple(@TypeOf(func)),
) !Handle {
    const task = try allocator.create(Task);
    // Two references: this handle, and the coroutine itself until it finishes.
    task.* = .{ .allocator = allocator, .refs = 2 };

    const coro = create(allocator, func, args) catch |e| {
        allocator.destroy(task);
        return e;
    };
    coro.task = task;

    enter(coro);
    return .{ .task = task };
}

fn isObjectArg(comptime T: type) bool {
    if (gdzig.class.isClassPtr(T)) return true;
    return switch (@typeInfo(T)) {
        .optional => |o| gdzig.class.isClassPtr(o.child),
        else => false,
    };
}

fn instanceIdOf(value: anytype) u64 {
    if (comptime @typeInfo(@TypeOf(value)) == .optional) {
        return if (value) |v| instanceIdOf(v) else 0;
    }
    return gdzig.class.upcast(*Object, value).getInstanceId();
}

fn create(
    allocator: std.mem.Allocator,
    comptime func: anytype,
    args: std.meta.ArgsTuple(@TypeOf(func)),
) !*Coro {
    if (comptime !supported) @compileError(
        "gdzig coroutines need a native OS and CPU supported by zio.coro. WebAssembly " ++
            "and other targets without native stack switching require an explicit state " ++
            "machine; use `gdzig.coro.supported` to pick at comptime.",
    );

    const Args = @TypeOf(args);

    // Which arguments are Godot objects, and so which ones the body would be
    // touching after a park.
    const owners = comptime blk: {
        var found: []const usize = &.{};
        for (@typeInfo(Args).@"struct".fields, 0..) |field, i| {
            if (isObjectArg(field.type)) found = found ++ [_]usize{i};
        }
        break :blk found;
    };

    const Frame = struct {
        args: Args,
        /// Instance IDs of the object arguments, read once here. Reading them
        /// off the pointers at resume time would be the very use-after-free
        /// this is meant to catch.
        owner_ids: [owners.len]u64,

        fn run(erased: *anyopaque) void {
            const frame: *@This() = @ptrCast(@alignCast(erased));
            @call(.auto, func, frame.args);
        }

        fn free(alloc: std.mem.Allocator, erased: *anyopaque) void {
            const frame: *@This() = @ptrCast(@alignCast(erased));
            alloc.destroy(frame);
        }

        fn ownersAlive(erased: *anyopaque) bool {
            const frame: *@This() = @ptrCast(@alignCast(erased));
            for (frame.owner_ids) |id| {
                // Zero is a null argument, which was never an object to lose.
                if (id != 0 and !gdzig.general.isInstanceIdValid(@intCast(id))) return false;
            }
            return true;
        }
    };

    const frame = try allocator.create(Frame);
    frame.* = .{ .args = args, .owner_ids = undefined };
    inline for (owners, 0..) |arg_index, slot| {
        frame.owner_ids[slot] = instanceIdOf(args[arg_index]);
    }

    const coro = allocator.create(Coro) catch |err| {
        allocator.destroy(frame);
        return err;
    };
    coro.* = .{
        // Zeroing matters on Windows: the initial context includes FiberData,
        // which zio restores into the TEB on the first switch.
        .runtime = .{
            .context = std.mem.zeroes(zio_coro.Context),
            .parent_context_ptr = &main_context,
        },
        .allocator = allocator,
        .frame = @ptrCast(frame),
        .run = Frame.run,
        .free_frame = Frame.free,
        .owners_alive = Frame.ownersAlive,
    };

    if (!stack_growth_ready) {
        zio_coro.setupStackGrowth() catch |err| {
            allocator.destroy(frame);
            allocator.destroy(coro);
            return err;
        };
        stack_growth_ready = true;
    }

    zio_coro.stackAlloc(
        &coro.runtime.context.stack_info,
        default_stack_reserve,
        default_stack_commit,
    ) catch |err| {
        allocator.destroy(frame);
        allocator.destroy(coro);
        return err;
    };
    coro.runtime.setup(&zioEntry, @ptrCast(coro));

    linkLive(coro);
    live_count += 1;
    return coro;
}

/// Switches into `coro` and runs it until it parks or finishes.
fn enter(coro: *Coro) void {
    // A parked coroutine holds its arguments across the park, and a Godot
    // object among them can be freed in the meantime -- a node that gets
    // `queue_free`d halfway through its own animation. Resuming would run the
    // rest of the body against freed memory, so it is dropped instead.
    //
    // Deliberately quiet: an entity dying mid-wait is ordinary in a game, and
    // an error per death would be noise. `liveCount` still accounts for it.
    if (!coro.owners_alive(coro.frame)) {
        coro.state = .cancelled;
        finish(coro);
        return;
    }

    const previous = current;
    const from = if (previous) |parent| &parent.runtime.context else &main_context;
    current = coro;
    coro.state = .running;
    coro.runtime.parent_context_ptr = from;

    coro.runtime.step();

    current = previous;
    if (previous == null) zio_coro.Coroutine.clearCurrent();
    // Reclaimed here rather than inside the fiber: a fiber cannot delete
    // itself while it is the one executing.
    if (coro.state == .done or coro.state == .cancelled) finish(coro);
}

/// Reclaims a coroutine that will not run again, and releases whatever was
/// waiting on it.
///
/// Both endings come through here -- the body returning, and the awaited object
/// dying while parked -- because a joiner has to be woken either way. A join
/// that only handled the first would hang forever on the second.
fn finish(coro: *Coro) void {
    const task = coro.task;
    var joiners: ?*Coro = null;
    if (task) |t| {
        t.done = true;
        joiners = t.joiners;
        t.joiners = null;
    }

    coro.destroy();
    if (task) |t| t.release();

    // After the destroy, so a joiner resuming here sees the coroutine it waited
    // on already gone rather than half-torn-down. Each is unlinked before being
    // entered: it may park again immediately, on something else.
    while (joiners) |j| {
        joiners = j.next_joiner;
        j.next_joiner = null;
        enter(j);
    }
}

fn zioEntry(_: *zio_coro.Coroutine, param: ?*anyopaque) void {
    const coro: *Coro = @ptrCast(@alignCast(param.?));
    runEntry(coro);
}

fn runEntry(coro: *Coro) noreturn {
    coro.run(coro.frame);
    coro.state = .done;

    // A coroutine entry must never return. The loop is unreachable in
    // practice: `enter` reclaims this stack after the first yield lands back
    // with its caller.
    while (true) coro.runtime.yield();
}

/// One parked `awaitSignal`, owned by the callable Godot holds onto.
///
/// Separate from `Coro` because the two do not die together. Godot frees a
/// callable whenever it suits it -- after the resume, or when the object it is
/// connected to goes away -- and that can be well after the coroutine itself is
/// gone. Pointing the callable straight at the `Coro` reads freed memory on
/// every completed await. The link here is cleared the moment the wait is
/// consumed, so a late free finds nothing to reclaim.
const Waiter = struct {
    allocator: std.mem.Allocator,
    coro: ?*Coro,
    /// Where to put the signal's arguments: an `S` on the parked coroutine's
    /// own stack, which is alive for exactly as long as this wait is.
    result: *anyopaque,

    /// Claims the parked coroutine, leaving nothing for a later free to act on.
    fn take(self: *Waiter) ?*Coro {
        defer self.coro = null;
        return self.coro;
    }
};

/// What awaiting `S` yields: its arguments, or nothing when it carries none.
///
/// A signal without arguments stays a statement -- `awaitSignal(t, Timeout);`
/// -- rather than making every call site discard an empty struct. Give a signal
/// a field later and its awaits become compile errors, which is the right way
/// to find out about them.
pub fn SignalResult(comptime S: type) type {
    return if (@typeInfo(S).@"struct".fields.len == 0) void else S;
}

/// Fills `out` from the Variants Godot emitted.
///
/// Both mismatches panic rather than substituting a value. A signal struct is
/// what `addSignal` registers the parameter types from, so disagreeing with the
/// emission means the declaration is wrong -- and a fabricated argument turns
/// that into a puzzle somewhere further along instead.
fn decodeArgs(
    comptime S: type,
    out: *S,
    argv: [*c]const c.GDExtensionConstVariantPtr,
    argc: c.GDExtensionInt,
) void {
    inline for (@typeInfo(S).@"struct".fields, 0..) |field, i| {
        if (i >= argc) std.debug.panic(
            "gdzig.coro: {s} declares {d} argument(s) but the emission carried {d}",
            .{ @typeName(S), @typeInfo(S).@"struct".fields.len, argc },
        );
        const variant: *const Variant = @ptrCast(@alignCast(argv[i]));
        @field(out, field.name) = variant.as(field.type) orelse std.debug.panic(
            "gdzig.coro: {s}.{s} is declared {s}, which the emitted value is not",
            .{ @typeName(S), field.name, @typeName(field.type) },
        );
    }
}

/// Parks the running coroutine until `obj` emits `S`, and hands back what the
/// signal carried.
///
/// Arguments that own heap data -- `String`, `Array`, `Dictionary`, the packed
/// arrays -- come back owned by the caller, because decoding constructs them.
/// Deinit them like any other value you were handed:
///
/// ```zig
/// var hit = coro.awaitSignal(enemy, Enemy.Hit);
/// defer hit.label.deinit();
/// ```
///
/// Panics if called outside a coroutine, which is a programming error rather
/// than a runtime condition: the caller has no frame to park.
pub fn awaitSignal(obj: anytype, comptime S: type) SignalResult(S) {
    // Split so that neither branch has to be valid for the other's return type:
    // the storage is an `S` either way, but only one of them returns it.
    // A refcounted object is held up for the duration of the park by the
    // coroutine, not by the caller. It has to survive to emit the signal, and
    // the caller's own handle is no use for that if the coroutine is dropped.
    const owned = refFor(obj);
    if (comptime SignalResult(S) == void) {
        var discard: S = undefined;
        park(obj, S, &discard, owned);
    } else {
        var result: S = undefined;
        park(obj, S, &result, owned);
        return result;
    }
}

/// One reference to `obj` for the coroutine to own, or null if `obj` is not
/// reference counted and so has nothing to own.
fn refFor(obj: anytype) ?*RefCounted {
    const ptr = gdzig.class.asPtr(obj);
    const T = @typeInfo(@TypeOf(ptr)).pointer.child;
    if (comptime !oopz.isA(RefCounted, T)) return null;
    const ref = RefCounted.upcast(ptr);
    _ = ref.reference();
    return ref;
}

/// Parks the calling coroutine for `seconds`: GDScript's
/// `await get_tree().create_timer(s).timeout`, which is the other half of
/// waiting once you have [`awaitSignal`](#awaitSignal).
///
/// ```zig
/// coro.wait(self.base, 0.4, .{});
/// self.sprite.get().?.play(.{ .name = sname("recover") });
/// ```
///
/// The options are Godot's own rather than a policy of ours: leave
/// `process_always` set and the wait keeps counting while the tree is paused,
/// clear it and a pause suspends it.
///
/// Returns without waiting if `node` is not in a tree, since there is no timer
/// to park on -- a detached node would otherwise hang its coroutine forever.
/// Panics outside a coroutine, like `awaitSignal`.
pub fn wait(node: anytype, seconds: f64, opts: struct {
    process_always: bool = true,
    process_in_physics: bool = false,
    ignore_time_scale: bool = false,
}) void {
    const target: *Node = gdzig.class.upcast(*Node, node);
    const tree = target.getTree() orelse return;

    var timer = tree.createTimer(seconds, .{
        .process_always = opts.process_always,
        .process_in_physics = opts.process_in_physics,
        .ignore_time_scale = opts.ignore_time_scale,
    }) orelse return;

    // Not `defer timer.deinit()`. This frame is on the fiber's stack, and a
    // coroutine dropped while parked never returns to it, so that defer would
    // not run and the timer's reference would be lost. Handing the reference to
    // the coroutine instead puts its release on a path that both endings take.
    var discard: SceneTreeTimer.Timeout = undefined;
    park(timer.get(), SceneTreeTimer.Timeout, &discard, RefCounted.upcast(timer.release()));
}

/// `owned` is a reference the coroutine takes over for the duration of the
/// park, or null when the awaited object is not reference counted. Passing one
/// is how a caller avoids holding a handle across the park itself: a `defer` in
/// the calling frame does not run if the coroutine is dropped, and the
/// reference goes with the fiber.
fn park(obj: anytype, comptime S: type, result: *S, owned: ?*RefCounted) void {
    const coro = current orelse {
        // The reference was handed over on the way in, so it has to go
        // somewhere even on the path that never parks.
        if (owned) |ref| if (ref.unreference()) ref.destroy();
        @panic("gdzig.coro.awaitSignal called outside a coroutine; start one with gdzig.coro.spawn");
    };
    coro.parked_ref = owned;

    const waiter = coro.allocator.create(Waiter) catch @panic(
        "gdzig.coro: out of memory while parking on a signal",
    );
    waiter.* = .{ .allocator = coro.allocator, .coro = coro, .result = @ptrCast(result) };
    coro.waiter = waiter;

    var callable = resumeCallable(S, waiter);

    // Marked suspended *before* connecting: `is_valid_func` answers from this
    // state, and Godot asks while connecting. Setting it afterwards means the
    // callable declares itself dead at the moment it is being registered.
    coro.state = .suspended;

    const target = gdzig.class.upcast(*Object, obj);
    target.tryOnceCallable(S, callable) catch |e| {
        // Unlink before releasing: dropping the last reference runs the free
        // hook, which reclaims a coroutine it finds parked, and this one is
        // still running on its own stack.
        _ = waiter.take();
        coro.waiter = null;
        coro.state = .running;
        callable.deinit();

        // A panic rather than running on. Every await gets a freshly allocated
        // `Waiter`, so no two resume callables are ever the same identity and a
        // duplicate connection cannot happen -- which leaves "this object has
        // no such signal" as the reachable cause. Carrying on would mean
        // inventing the arguments the caller is about to read.
        std.debug.panic(
            "gdzig.coro: cannot await {s} ({s}); does this object have that signal?",
            .{ @typeName(S), @errorName(e) },
        );
    };

    // Released here rather than on scope exit, because scope exit is *after*
    // the resume: a coroutine that never resumes would hold this reference for
    // good, and dropping the last reference is exactly what fires the free hook
    // that reclaims it. The connection owns the callable from here on.
    callable.deinit();

    // Back to whoever entered this coroutine, not to the main stack: when a
    // coroutine spawns or resumes another, the entering fiber is the outer
    // coroutine's, and jumping past it would strand it mid-`enter`.
    coro.runtime.yield();

    // Resumed. The callable that woke this coroutine is on its way out and its
    // `Waiter` goes with it, so the back-pointer must not outlive the park.
    coro.waiter = null;
    // The park is over, so the object no longer needs holding up. On the other
    // ending -- the coroutine dropped while parked -- `destroy` does this
    // instead, which is the whole reason the reference lives on the coroutine.
    coro.releaseParked();
}

/// A callable that resumes the coroutine `waiter` is holding, and cancels it if
/// dropped first -- which is what happens when the object it is connected to
/// dies with the signal still pending.
fn resumeCallable(comptime S: type, waiter: *Waiter) Callable {
    const Hooks = struct {
        fn call(
            userdata: ?*anyopaque,
            argv: [*c]const c.GDExtensionConstVariantPtr,
            argc: c.GDExtensionInt,
            _: c.GDExtensionVariantPtr,
            err: [*c]c.GDExtensionCallError,
        ) callconv(.c) void {
            // Godot hands this in uninitialized and copies it back out
            // afterwards, so leaving it alone reads as whatever was on the
            // stack. Unset, the emission reports ERR_METHOD_NOT_FOUND with an
            // empty reason -- the garbage matched no case in its error-text
            // switch.
            if (err) |e| e.* = .{ .@"error" = c.GDEXTENSION_CALL_OK, .argument = 0, .expected = 0 };

            const w: *Waiter = @ptrCast(@alignCast(userdata.?));
            // Cleared before entering, not after: the coroutine may finish and
            // be destroyed in there, and the free that follows must not find a
            // pointer to it.
            const target = w.take() orelse return;

            // Written before the switch, while still on Godot's stack. The
            // slot lives on the coroutine's stack, which is parked but intact.
            decodeArgs(S, @ptrCast(@alignCast(w.result)), argv, argc);

            enter(target);
        }

        fn isValid(userdata: ?*anyopaque) callconv(.c) c.GDExtensionBool {
            const w: *Waiter = @ptrCast(@alignCast(userdata.?));
            return @intFromBool(w.coro != null);
        }

        fn free(userdata: ?*anyopaque) callconv(.c) void {
            const w: *Waiter = @ptrCast(@alignCast(userdata.?));
            // Still linked, so this callable is being dropped without ever
            // having been called -- the object holding the connection died
            // while the coroutine was parked on it. The body will never resume,
            // so reclaim the fiber and its stack instead of leaking them.
            if (w.take()) |target| {
                target.state = .cancelled;
                // Through `finish`, not `destroy`: anything joined to this
                // coroutine is still waiting, and cancelling is an ending too.
                finish(target);
            }
            w.allocator.destroy(w);
        }
    };

    var info: c.GDExtensionCallableCustomInfo2 = std.mem.zeroes(c.GDExtensionCallableCustomInfo2);
    info.callable_userdata = @ptrCast(waiter);
    info.token = gdzig.raw.library;
    info.call_func = Hooks.call;
    info.is_valid_func = Hooks.isValid;
    info.free_func = Hooks.free;

    var callable: Callable = undefined;
    gdzig.raw.callableCustomCreate2.?(@ptrCast(&callable), &info);
    return callable;
}
