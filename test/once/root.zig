//! `once` — connect for a single emission.
//!
//! GDExtension has no `await`; a one-shot connection is what GDScript's `await`
//! compiles down to for the single-wait case, and what the engine's own C++ uses
//! throughout. These check the "once" actually holds.

const std = @import("std");
const testing = std.testing;

pub fn register(r: *gdzig.extension.Registry) void {
    const class = r.createClass(Beeper, {}, .auto);
    class.addSignal(Beeped);
    class.addMethod("on_beeped", .auto);
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

pub const Beeped = struct {};

const Beeper = struct {
    base: *Node,
    heard: u32 = 0,

    pub fn create() !*Beeper {
        const self = try allocator.create(Beeper);
        self.* = .{ .base = Node.init() };
        self.base.setInstance(Beeper, self);
        return self;
    }
    pub fn destroy(self: *Beeper) void {
        allocator.destroy(self);
    }
    pub fn onBeeped(self: *Beeper) void {
        self.heard += 1;
    }
};

test "once fires for a single emission and then disconnects" {
    ensureRegistered();

    const beeper = try Beeper.create();
    defer beeper.base.destroy();

    try beeper.base.once(Beeped, .fromClosure(beeper, &Beeper.onBeeped));

    try beeper.base.emit(Beeped, .{});
    try testing.expectEqual(@as(u32, 1), beeper.heard);

    // The connection is gone, so further emissions are not delivered. With a
    // plain `connect` this would read 3.
    try beeper.base.emit(Beeped, .{});
    try beeper.base.emit(Beeped, .{});
    try testing.expectEqual(@as(u32, 1), beeper.heard);
}

test "connect still delivers every emission" {
    ensureRegistered();

    const beeper = try Beeper.create();
    defer beeper.base.destroy();

    try beeper.base.connect(Beeped, .fromClosure(beeper, &Beeper.onBeeped));

    try beeper.base.emit(Beeped, .{});
    try beeper.base.emit(Beeped, .{});
    try testing.expectEqual(@as(u32, 2), beeper.heard);
}

const gdzig = @import("gdzig");
const allocator = gdzig.testing.allocator;
const Node = gdzig.class.Node;
