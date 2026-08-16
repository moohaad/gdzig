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
//! Windows only for now, on Win32 fibers, which provide context switching
//! without assembly. The other targets need hand-written switching per
//! architecture; the Godot-side design above is what had to be proven first.

const std = @import("std");
const builtin = @import("builtin");

const c = @import("gdextension");
const gdzig = @import("gdzig");
const Callable = gdzig.builtin.Callable;
const Object = gdzig.class.Object;
const StringName = gdzig.builtin.StringName;
const Variant = gdzig.builtin.Variant;

pub const supported = builtin.os.tag == .windows;

extern "kernel32" fn ConvertThreadToFiber(lpParameter: ?*anyopaque) callconv(.winapi) ?*anyopaque;
/// `CreateFiberEx` rather than `CreateFiber`, which takes only a commit size
/// and reserves whatever the *host executable's* PE header says -- Godot's
/// number, not ours, and megabytes of address space per parked coroutine.
extern "kernel32" fn CreateFiberEx(
    dwStackCommitSize: usize,
    dwStackReserveSize: usize,
    dwFlags: u32,
    lpStartAddress: *const fn (?*anyopaque) callconv(.winapi) void,
    lpParameter: ?*anyopaque,
) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn SwitchToFiber(lpFiber: *anyopaque) callconv(.winapi) void;
extern "kernel32" fn DeleteFiber(lpFiber: *anyopaque) callconv(.winapi) void;
extern "kernel32" fn IsThreadAFiber() callconv(.winapi) i32;

/// `GetCurrentFiber` is a TEB macro rather than an exported symbol; on x86-64
/// the fiber pointer lives at GS:[0x20].
fn currentFiber() ?*anyopaque {
    return asm volatile ("movq %%gs:0x20, %[ret]"
        : [ret] "=r" (-> ?*anyopaque),
    );
}

/// The coroutine currently executing, or null on the plain stack.
///
/// A plain global rather than thread-local: coroutines are main-thread only,
/// because that is where Godot dispatches signals. Awaiting from a worker
/// thread is not supported and would need the whole scheduler to be
/// thread-aware, not just this pointer.
var current: ?*Coro = null;

/// The fiber for the main thread's stack. A thread must be converted to a
/// fiber before it can switch to one, so this is filled in the first time a
/// coroutine starts. Where a coroutine parks *to* is `Coro.caller`, not this.
var main_fiber: ?*anyopaque = null;

/// Physical memory a coroutine's stack starts with. The rest is faulted in on
/// demand at the guard page, exactly as a thread stack grows, so this is a
/// floor and not a budget.
pub const default_stack_commit = 4 * 1024;

/// Address space a coroutine's stack may grow into, and the hard ceiling on how
/// deep it can recurse -- past this is a stack overflow.
///
/// Generous on purpose: reserving costs address space rather than memory, and
/// these stacks run Godot's C++, whose depth is not ours to predict. Trimming
/// it saves nothing that `default_stack_commit` does not already save.
pub const default_stack_reserve = 1024 * 1024;

var live_count: usize = 0;

/// How many coroutines are alive, parked or running.
///
/// Each holds a stack until it finishes, so this is the number to watch when
/// coroutines are spawned from something recurring -- a count that climbs is
/// stacks that are never coming back.
pub fn liveCount() usize {
    return live_count;
}

pub const Coro = struct {
    fiber: ?*anyopaque = null,
    /// The fiber that most recently entered this one, and so the one parking
    /// returns to. Usually the main stack, but another coroutine when one
    /// spawns or resumes another.
    caller: ?*anyopaque = null,
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
        live_count -= 1;
        if (self.fiber) |f| DeleteFiber(f);
        self.free_frame(self.allocator, self.frame);
        self.allocator.destroy(self);
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

        SwitchToFiber(coro.caller.?);
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
        "gdzig coroutines are Windows-only for now: they need stackful context " ++
            "switching, which Win32 fibers provide and other targets need hand-written " ++
            "assembly for. Use an explicit state machine, or `gdzig.coro.supported` to " ++
            "pick at comptime.",
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

    const coro = try allocator.create(Coro);
    coro.* = .{
        .allocator = allocator,
        .frame = @ptrCast(frame),
        .run = Frame.run,
        .free_frame = Frame.free,
        .owners_alive = Frame.ownersAlive,
    };

    if (main_fiber == null) {
        main_fiber = if (IsThreadAFiber() != 0) currentFiber() else ConvertThreadToFiber(null);
    }

    coro.fiber = CreateFiberEx(default_stack_commit, default_stack_reserve, 0, &entry, @ptrCast(coro)) orelse {
        allocator.destroy(frame);
        allocator.destroy(coro);
        return error.FiberCreationFailed;
    };

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
    current = coro;
    coro.state = .running;
    coro.caller = currentFiber().?;

    SwitchToFiber(coro.fiber.?);

    current = previous;
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

fn entry(param: ?*anyopaque) callconv(.winapi) void {
    const coro: *Coro = @ptrCast(@alignCast(param.?));
    coro.run(coro.frame);
    coro.state = .done;

    // Read before switching away: `enter` frees the struct once control lands
    // back, and this local lives on a stack nothing ever returns to.
    const back = coro.caller.?;

    // A fiber procedure must never return -- doing so ends the thread. The
    // loop is unreachable in practice: `enter` deletes this fiber as soon as
    // control is back with the caller.
    while (true) SwitchToFiber(back);
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
    if (comptime SignalResult(S) == void) {
        var discard: S = undefined;
        park(obj, S, &discard);
    } else {
        var result: S = undefined;
        park(obj, S, &result);
        return result;
    }
}

fn park(obj: anytype, comptime S: type, result: *S) void {
    const coro = current orelse @panic(
        "gdzig.coro.awaitSignal called outside a coroutine; start one with gdzig.coro.spawn",
    );

    const waiter = coro.allocator.create(Waiter) catch @panic(
        "gdzig.coro: out of memory while parking on a signal",
    );
    waiter.* = .{ .allocator = coro.allocator, .coro = coro, .result = @ptrCast(result) };

    var callable = resumeCallable(S, waiter);

    // Marked suspended *before* connecting: `is_valid_func` answers from this
    // state, and Godot asks while connecting. Setting it afterwards means the
    // callable declares itself dead at the moment it is being registered.
    coro.state = .suspended;

    const target = gdzig.class.upcast(*Object, obj);
    target.onceCallable(S, callable) catch |e| {
        // Unlink before releasing: dropping the last reference runs the free
        // hook, which reclaims a coroutine it finds parked, and this one is
        // still running on its own stack.
        _ = waiter.take();
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
    SwitchToFiber(coro.caller.?);
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
