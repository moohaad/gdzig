//! `gdzig.coro` -- straight-line code that waits on Godot signals.
//!
//! The prototype these grew from proved the basic question: a registered method
//! can park mid-execution, hand control back to Godot, and resume from inside a
//! later emission. These cover what it did not -- several coroutines at once,
//! one awaiting inside another, the awaited object dying while parked, the
//! coroutine's *own* object dying while parked, a frame larger than the
//! committed stack, signal arguments, and `join`.
//!
//! Windows-only, like `coro` itself.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

pub fn register(r: *gdzig.extension.Registry) void {
    const class = r.createClass(Emitter, {}, .auto);
    _ = r.createClass(Orphan, {}, .auto);
    class.addSignal(Ping);
    class.addSignal(Pong);
    class.addSignal(Hit);
}

fn ensureRegistered() void {
    const S = struct {
        var done: bool = false;
    };
    if (!S.done) {
        S.done = true;
        gdzig.testing.loadModule(@This());
    }
}

pub const Ping = struct {};
pub const Pong = struct {};

/// A signal that carries something, which is the whole point here: `damage`
/// exercises a scalar and `label` a value the decode has to construct.
pub const Hit = struct {
    damage: i64,
    label: String,
};

const Emitter = struct {
    base: *Object,

    pub fn create() !*Emitter {
        const self = try allocator.create(Emitter);
        self.* = .{ .base = Object.init() };
        self.base.setInstance(Emitter, self);
        return self;
    }
    pub fn destroy(self: *Emitter) void {
        self.base.destroy();
        allocator.destroy(self);
    }
};

/// A `Node`, because `wait` needs one, and deliberately never added to a
/// tree: `getTree` returns null, which is the branch under test.
const Orphan = struct {
    base: *Node,

    pub fn create() !*Orphan {
        const self = try allocator.create(Orphan);
        self.* = .{ .base = Node.init() };
        self.base.setInstance(Orphan, self);
        return self;
    }
    pub fn destroy(self: *Orphan) void {
        self.base.destroy();
        allocator.destroy(self);
    }
};

/// Where each coroutine records its progress, so a test can see how far one
/// got without depending on ordering between them.
const Trace = struct {
    a: u8 = 0,
    b: u8 = 0,
    nested_outer: u8 = 0,
    nested_inner: u8 = 0,
};

var trace: Trace = .{};

fn waitOnce(emitter: *Emitter, slot: *u8) void {
    slot.* = 1;
    coro.awaitSignal(emitter.base, Ping);
    slot.* = 2;
}

test "a coroutine parks and resumes" {
    if (comptime !coro.supported) return error.SkipZigTest;
    ensureRegistered();

    const emitter = try Emitter.create();
    defer emitter.destroy();
    trace = .{};

    try coro.spawn(allocator, waitOnce, .{ emitter, &trace.a });
    try testing.expectEqual(@as(u8, 1), trace.a);

    try emitter.base.emit(Ping, .{});
    try testing.expectEqual(@as(u8, 2), trace.a);

    // A coroutine that ran to the end is reclaimed. Also catches the reverse
    // mistake: reclaiming it twice underflows the count rather than hitting 0.
    try testing.expectEqual(@as(usize, 0), coro.liveCount());
}

test "two coroutines park on the same signal and both resume" {
    if (comptime !coro.supported) return error.SkipZigTest;
    ensureRegistered();

    const emitter = try Emitter.create();
    defer emitter.destroy();
    trace = .{};

    // Each needs its own stack; the second must not disturb the first.
    try coro.spawn(allocator, waitOnce, .{ emitter, &trace.a });
    try coro.spawn(allocator, waitOnce, .{ emitter, &trace.b });
    try testing.expectEqual(@as(u8, 1), trace.a);
    try testing.expectEqual(@as(u8, 1), trace.b);

    try emitter.base.emit(Ping, .{});
    try testing.expectEqual(@as(u8, 2), trace.a);
    try testing.expectEqual(@as(u8, 2), trace.b);
    try testing.expectEqual(@as(usize, 0), coro.liveCount());
}

fn outer(emitter: *Emitter) void {
    trace.nested_outer = 1;
    // Spawning from inside a coroutine: the inner one runs to its own park,
    // then control comes back here and this one parks too.
    coro.spawn(allocator, inner, .{emitter}) catch return;
    coro.awaitSignal(emitter.base, Ping);
    trace.nested_outer = 2;
}

fn inner(emitter: *Emitter) void {
    trace.nested_inner = 1;
    coro.awaitSignal(emitter.base, Pong);
    trace.nested_inner = 2;
}

test "a coroutine spawned inside another parks independently" {
    if (comptime !coro.supported) return error.SkipZigTest;
    ensureRegistered();

    const emitter = try Emitter.create();
    defer emitter.destroy();
    trace = .{};

    try coro.spawn(allocator, outer, .{emitter});
    try testing.expectEqual(@as(u8, 1), trace.nested_outer);
    try testing.expectEqual(@as(u8, 1), trace.nested_inner);

    // They wait on different signals, so each resumes on its own.
    try emitter.base.emit(Pong, .{});
    try testing.expectEqual(@as(u8, 2), trace.nested_inner);
    try testing.expectEqual(@as(u8, 1), trace.nested_outer);

    try emitter.base.emit(Ping, .{});
    try testing.expectEqual(@as(u8, 2), trace.nested_outer);
    try testing.expectEqual(@as(usize, 0), coro.liveCount());
}

/// The GDScript this ports from writes `await _fade_to(1.0)` -- awaiting a call
/// rather than a signal. Nothing here says `await`: `fadeStep` parks the
/// coroutine it is running on, which is this one, and the plain call resumes
/// where it left off. Stackless languages need `await` at every level because
/// each function is its own state machine; a stack does not.
fn fadeStep(emitter: *Emitter, slot: *u8) void {
    slot.* = 1;
    coro.awaitSignal(emitter.base, Ping);
    slot.* = 2;
}

fn fadeSequence(emitter: *Emitter) void {
    fadeStep(emitter, &trace.nested_inner);
    trace.nested_outer = 1;
    fadeStep(emitter, &trace.nested_inner);
    trace.nested_outer = 2;
}

test "awaiting a call needs no primitive: the callee parks its caller" {
    if (comptime !coro.supported) return error.SkipZigTest;
    ensureRegistered();

    const emitter = try Emitter.create();
    defer emitter.destroy();
    trace = .{};

    try coro.spawn(allocator, fadeSequence, .{emitter});
    try testing.expectEqual(@as(u8, 1), trace.nested_inner);
    try testing.expectEqual(@as(u8, 0), trace.nested_outer);

    // First call returns, the sequence advances, the second call parks again.
    try emitter.base.emit(Ping, .{});
    try testing.expectEqual(@as(u8, 1), trace.nested_outer);

    try emitter.base.emit(Ping, .{});
    try testing.expectEqual(@as(u8, 2), trace.nested_outer);
    try testing.expectEqual(@as(usize, 0), coro.liveCount());
}

/// Uses far more stack than `default_stack_commit`, and reads it back after
/// parking. A frame this size also drags in `__chkstk`, which probes each page
/// against the TEB's stack limit -- so this covers the bookkeeping a hand-rolled
/// context switch would have to get right, not just the growth itself.
fn deepFrame(emitter: *Emitter, slot: *u8) void {
    var scratch: [128 * 1024]u8 = undefined;
    for (&scratch, 0..) |*b, i| b.* = @truncate(i);
    slot.* = 1;

    coro.awaitSignal(emitter.base, Ping);

    for (scratch, 0..) |b, i| {
        if (b != @as(u8, @truncate(i))) return;
    }
    slot.* = 2;
}

test "a coroutine can use more stack than it commits" {
    if (comptime !coro.supported) return error.SkipZigTest;
    ensureRegistered();

    const emitter = try Emitter.create();
    defer emitter.destroy();
    trace = .{};

    try coro.spawn(allocator, deepFrame, .{ emitter, &trace.a });
    try testing.expectEqual(@as(u8, 1), trace.a);

    // 2 rather than 1 means the 128 KiB came back byte-for-byte across the park.
    try emitter.base.emit(Ping, .{});
    try testing.expectEqual(@as(u8, 2), trace.a);
    try testing.expectEqual(@as(usize, 0), coro.liveCount());
}

/// The other shape: work started to run *alongside*, collected later. A plain
/// call cannot express this -- it would run to its first park before the
/// caller got to do anything else.
fn joiner(handle: coro.Handle, slot: *u8) void {
    slot.* = 1;
    handle.join();
    slot.* = 2;
}

test "join parks until the joined coroutine finishes" {
    if (comptime !coro.supported) return error.SkipZigTest;
    ensureRegistered();

    const emitter = try Emitter.create();
    defer emitter.destroy();
    trace = .{};

    const work = try coro.spawnJoinable(allocator, waitOnce, .{ emitter, &trace.a });
    defer work.deinit();
    try testing.expectEqual(@as(u8, 1), trace.a);
    try testing.expect(!work.isDone());

    // Started while the first is still parked, which is the point.
    try coro.spawn(allocator, joiner, .{ work, &trace.b });
    try testing.expectEqual(@as(u8, 1), trace.b);

    try emitter.base.emit(Ping, .{});
    try testing.expectEqual(@as(u8, 2), trace.a);
    try testing.expectEqual(@as(u8, 2), trace.b);
    try testing.expect(work.isDone());
    try testing.expectEqual(@as(usize, 0), coro.liveCount());
}

test "joining an already finished coroutine returns immediately" {
    if (comptime !coro.supported) return error.SkipZigTest;
    ensureRegistered();

    const emitter = try Emitter.create();
    defer emitter.destroy();
    trace = .{};

    const work = try coro.spawnJoinable(allocator, waitOnce, .{ emitter, &trace.a });
    defer work.deinit();
    try emitter.base.emit(Ping, .{});
    try testing.expect(work.isDone());

    // The handle outlives the coroutine: reading it here must not touch freed
    // memory, and joining must not park on something that will never wake.
    try coro.spawn(allocator, joiner, .{ work, &trace.b });
    try testing.expectEqual(@as(u8, 2), trace.b);
    try testing.expectEqual(@as(usize, 0), coro.liveCount());
}

test "several coroutines join one handle and all resume" {
    if (comptime !coro.supported) return error.SkipZigTest;
    ensureRegistered();

    const emitter = try Emitter.create();
    defer emitter.destroy();
    trace = .{};

    const work = try coro.spawnJoinable(allocator, waitOnce, .{ emitter, &trace.a });
    defer work.deinit();

    try coro.spawn(allocator, joiner, .{ work, &trace.b });
    try coro.spawn(allocator, joiner, .{ work, &trace.nested_inner });
    try coro.spawn(allocator, joiner, .{ work, &trace.nested_outer });

    try emitter.base.emit(Ping, .{});
    try testing.expectEqual(@as(u8, 2), trace.b);
    try testing.expectEqual(@as(u8, 2), trace.nested_inner);
    try testing.expectEqual(@as(u8, 2), trace.nested_outer);
    try testing.expectEqual(@as(usize, 0), coro.liveCount());
}

test "a joiner wakes when the joined coroutine is cancelled, not just finished" {
    if (comptime !coro.supported) return error.SkipZigTest;
    ensureRegistered();

    const emitter = try Emitter.create();
    trace = .{};

    const work = try coro.spawnJoinable(allocator, waitOnce, .{ emitter, &trace.a });
    defer work.deinit();
    try coro.spawn(allocator, joiner, .{ work, &trace.b });
    try testing.expectEqual(@as(u8, 1), trace.b);

    // `waitOnce` never resumes -- its signal dies with the emitter. The joiner
    // still has to come back, or it waits forever on something already gone.
    emitter.destroy();
    try testing.expectEqual(@as(u8, 1), trace.a);
    try testing.expectEqual(@as(u8, 2), trace.b);
    try testing.expect(work.isDone());
    try testing.expectEqual(@as(usize, 0), coro.liveCount());
}

/// `owner` is the object the body belongs to -- the `self` of a node method.
/// It is a different object from the one being awaited, so the signal still
/// fires normally; the question is whether the body runs against a corpse.
fn ownedWait(owner: *Emitter, emitter: *Emitter, slot: *u8) void {
    _ = owner.base.getInstanceId();
    slot.* = 1;
    coro.awaitSignal(emitter.base, Ping);
    slot.* = 2;
}

test "a coroutine is not resumed into a frame whose object was freed" {
    if (comptime !coro.supported) return error.SkipZigTest;
    ensureRegistered();

    const owner = try Emitter.create();
    const emitter = try Emitter.create();
    defer emitter.destroy();
    trace = .{};

    try coro.spawn(allocator, ownedWait, .{ owner, emitter, &trace.a });
    try testing.expectEqual(@as(u8, 1), trace.a);

    owner.destroy();

    // The emitter is alive and the signal fires as normal. Staying at 1 is the
    // point: the rest of the body would have been touching freed memory.
    try emitter.base.emit(Ping, .{});
    try testing.expectEqual(@as(u8, 1), trace.a);
    try testing.expectEqual(@as(usize, 0), coro.liveCount());
}

test "a live object argument does not stop a coroutine resuming" {
    if (comptime !coro.supported) return error.SkipZigTest;
    ensureRegistered();

    const owner = try Emitter.create();
    defer owner.destroy();
    const emitter = try Emitter.create();
    defer emitter.destroy();
    trace = .{};

    // The guard must not be so eager that it cancels a healthy coroutine --
    // without this, "never resume anything" would pass the test above.
    try coro.spawn(allocator, ownedWait, .{ owner, emitter, &trace.a });
    try emitter.base.emit(Ping, .{});
    try testing.expectEqual(@as(u8, 2), trace.a);
    try testing.expectEqual(@as(usize, 0), coro.liveCount());
}

fn awaitHit(emitter: *Emitter, slot: *u8) void {
    slot.* = 1;

    var hit = coro.awaitSignal(emitter.base, Hit);
    // Decoding constructs `label`, so this frame owns it now.
    defer hit.label.deinit();

    if (hit.damage == 7 and hit.label.length() == 4) slot.* = 2;
}

test "awaiting a signal yields the arguments it carried" {
    if (comptime !coro.supported) return error.SkipZigTest;
    ensureRegistered();

    const emitter = try Emitter.create();
    defer emitter.destroy();
    trace = .{};

    try coro.spawn(allocator, awaitHit, .{ emitter, &trace.a });
    try testing.expectEqual(@as(u8, 1), trace.a);

    var label: String = .fromLatin1("crit");
    defer label.deinit();
    try emitter.base.emit(Hit, .{ .damage = 7, .label = label });

    // 2 only if both arguments arrived intact -- a zeroed struct gives 1.
    try testing.expectEqual(@as(u8, 2), trace.a);
    try testing.expectEqual(@as(usize, 0), coro.liveCount());
}

test "a coroutine whose awaited object dies is reclaimed, not leaked" {
    if (comptime !coro.supported) return error.SkipZigTest;
    ensureRegistered();

    const emitter = try Emitter.create();
    trace = .{};

    try coro.spawn(allocator, waitOnce, .{ emitter, &trace.a });
    try testing.expectEqual(@as(u8, 1), trace.a);

    // The signal will never fire. Destroying the emitter drops the connection,
    // which frees the resume callable, which is where the parked coroutine's
    // fiber and stack get reclaimed.
    //
    // `liveCount` is the assertion, not `trace`: the body stays at 1 whether it
    // was reclaimed or leaked, so checking only that would pass on a leak.
    const before = coro.liveCount();
    emitter.destroy();
    try testing.expectEqual(@as(u8, 1), trace.a);
    try testing.expectEqual(before - 1, coro.liveCount());
}

const gdzig = @import("gdzig");
const coro = gdzig.coro;
const allocator = gdzig.testing.allocator;
const Node = gdzig.class.Node;
const Object = gdzig.class.Object;
const String = gdzig.builtin.String;

fn waitDetached(orphan: *Orphan, step: *u8) void {
    step.* = 1;
    // Sixty seconds, so a regression that actually parks hangs the suite
    // rather than passing slowly.
    coro.wait(orphan.base, 60.0, .{});
    step.* = 2;
}

test "waiting outside the tree returns instead of parking forever" {
    if (comptime !coro.supported) return error.SkipZigTest;
    ensureRegistered();

    const orphan = try Orphan.create();
    defer orphan.destroy();
    trace = .{};

    // Runs straight through inside `spawn`: no tree, so no timer to park on.
    try coro.spawn(allocator, waitDetached, .{ orphan, &trace.a });
    try testing.expectEqual(@as(u8, 2), trace.a);
    try testing.expectEqual(@as(usize, 0), coro.liveCount());
}

test "cancelAll drops parked coroutines and disarms what would resume them" {
    if (comptime !coro.supported) return error.SkipZigTest;
    ensureRegistered();

    const emitter = try Emitter.create();
    defer emitter.destroy();
    trace = .{};

    try coro.spawn(allocator, waitOnce, .{ emitter, &trace.a });
    try testing.expectEqual(@as(u8, 1), trace.a);
    try testing.expectEqual(@as(usize, 1), coro.liveCount());

    try testing.expectEqual(@as(usize, 1), coro.cancelAll());
    try testing.expectEqual(@as(usize, 0), coro.liveCount());

    // The body stopped where it parked rather than running on.
    try testing.expectEqual(@as(u8, 1), trace.a);

    // The point of the exercise: the signal it waited on now reaches nothing.
    // Without the waiter being claimed, this emission would resume a coroutine
    // that has been destroyed.
    try emitter.base.emit(Ping, .{});
    try testing.expectEqual(@as(u8, 1), trace.a);
    try testing.expectEqual(@as(usize, 0), coro.liveCount());
}

test "cancelAll wakes nothing, including joiners" {
    if (comptime !coro.supported) return error.SkipZigTest;
    ensureRegistered();

    const emitter = try Emitter.create();
    defer emitter.destroy();
    trace = .{};

    const work = try coro.spawnJoinable(allocator, waitOnce, .{ emitter, &trace.a });
    defer work.deinit();
    try coro.spawn(allocator, joiner, .{ work, &trace.b });

    // Both parked: one on the signal, one on the join.
    try testing.expectEqual(@as(usize, 2), coro.liveCount());

    try testing.expectEqual(@as(usize, 2), coro.cancelAll());
    try testing.expectEqual(@as(usize, 0), coro.liveCount());

    // Neither ran on. A joiner resumed here would execute in a library that is
    // being unloaded, which is exactly what cancelling avoids.
    try testing.expectEqual(@as(u8, 1), trace.a);
    try testing.expectEqual(@as(u8, 1), trace.b);
}
