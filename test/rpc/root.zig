//! `@rpc(...)` as an option on `addMethod`.
//!
//! `Node.rpcConfig` configures an instance, not a class, so the config has to
//! be applied per node from `_ready`. These check that it is -- read back from
//! `getNodeRpcConfig`, which is the engine's own view, rather than from
//! gdzig's table.

const std = @import("std");
const testing = std.testing;

pub fn register(r: *gdzig.extension.Registry) void {
    const class = r.createClass(Peer, {}, .auto);
    class.addMethod("shoot", .{ .rpc = .{ .mode = .any_peer, .call_local = true } });
    class.addMethod("nudge", .{ .rpc = .{ .transfer = .unreliable, .channel = 3 } });
    // No `.rpc`, so Godot should not know it as an RPC at all.
    class.addMethod("local_only", .auto);
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

/// Declares no `_ready`. The config still has to be applied, which is the whole
/// reason the wrapper is synthesised unconditionally.
const Peer = struct {
    base: *Node,

    pub fn create() !*Peer {
        const self = try allocator.create(Peer);
        self.* = .{ .base = Node.init() };
        self.base.setInstance(Peer, self);
        return self;
    }
    pub fn destroy(self: *Peer) void {
        allocator.destroy(self);
    }
    pub fn shoot(_: *Peer) void {}
    pub fn nudge(_: *Peer) void {}
    pub fn localOnly(_: *Peer) void {}
};

/// One method's config, as the engine reports it.
const Reported = struct {
    rpc_mode: i64,
    transfer_mode: i64,
    call_local: bool,
    channel: i64,
};

fn configOf(obj: *Peer, comptime method: [:0]const u8) ?Reported {
    var all = obj.base.getNodeRpcConfig();
    defer all.deinit();

    var dict = all.as(Dictionary) orelse return null;
    defer dict.deinit();

    var key: StringName = .fromLatin1(method, false);
    defer key.deinit();

    var entry = dict.get(.init(StringName, key), .{});
    defer entry.deinit();

    var cfg = entry.as(Dictionary) orelse return null;
    defer cfg.deinit();

    return .{
        .rpc_mode = intAt(&cfg, "rpc_mode"),
        .transfer_mode = intAt(&cfg, "transfer_mode"),
        .call_local = intAt(&cfg, "call_local") != 0,
        .channel = intAt(&cfg, "channel"),
    };
}

fn intAt(cfg: *Dictionary, comptime key: [:0]const u8) i64 {
    var k: String = .fromLatin1(key);
    defer k.deinit();
    var v = cfg.get(.init(String, k), .{});
    defer v.deinit();
    if (v.as(i64)) |n| return n;
    if (v.as(bool)) |b| return @intFromBool(b);
    return -1;
}

test "the rpc option reaches the engine, applied per instance" {
    ensureRegistered();

    const obj = try Peer.create();
    defer obj.base.destroy();

    // Nothing is configured until the node is ready: `rpcConfig` is an instance
    // call, and the wrapper is what makes it.
    obj.base.notification(Node.NOTIFICATION_READY, .{});

    const shoot = configOf(obj, "shoot") orelse return error.ShootMissing;
    try testing.expectEqual(@as(i64, 1), shoot.rpc_mode); // any_peer
    try testing.expectEqual(true, shoot.call_local);
    try testing.expectEqual(@as(i64, 2), shoot.transfer_mode); // reliable, the default
    try testing.expectEqual(@as(i64, 0), shoot.channel);

    const nudge = configOf(obj, "nudge") orelse return error.NudgeMissing;
    try testing.expectEqual(@as(i64, 2), nudge.rpc_mode); // authority, the default
    try testing.expectEqual(false, nudge.call_local);
    try testing.expectEqual(@as(i64, 0), nudge.transfer_mode); // unreliable
    try testing.expectEqual(@as(i64, 3), nudge.channel);

    // A method registered without `.rpc` stays absent from the table.
    try testing.expect(configOf(obj, "local_only") == null);
}

test "a node that has not been readied has no config yet" {
    ensureRegistered();

    const obj = try Peer.create();
    defer obj.base.destroy();

    try testing.expect(configOf(obj, "shoot") == null);
}

const gdzig = @import("gdzig");
const allocator = gdzig.testing.allocator;
const Dictionary = gdzig.builtin.Dictionary;
const Node = gdzig.class.Node;
const String = gdzig.builtin.String;
const StringName = gdzig.builtin.StringName;
