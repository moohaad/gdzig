//! `Child(T, path)` — scene children declared as fields.
//!
//! The point is that resolution happens without the user writing the lookup,
//! and without necessarily writing a `_ready` at all.

const std = @import("std");
const testing = std.testing;

pub fn register(r: *gdzig.extension.Registry) void {
    _ = r.createClass(WithReady, {}, .auto);
    _ = r.createClass(WithoutReady, {}, .auto);
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

/// Declares `_ready` itself, so the generated wrapper has to resolve the fields
/// *and* still call it.
const WithReady = struct {
    base: *Node,
    marker: Child(Node, "Marker") = .pending,
    missing: Child(Node, "NoSuchNode") = .pending,
    ready_ran: bool = false,

    pub fn create() !*WithReady {
        const self = try allocator.create(WithReady);
        self.* = .{ .base = Node.init() };
        self.base.setInstance(WithReady, self);
        return self;
    }
    pub fn destroy(self: *WithReady) void {
        allocator.destroy(self);
    }
    pub fn _ready(self: *WithReady) void {
        self.ready_ran = true;
    }
};

/// Declares no `_ready`. The fields must still be filled in, which is the whole
/// reason the vtable synthesises one.
const WithoutReady = struct {
    base: *Node,
    marker: Child(Node, "Marker") = .pending,

    pub fn create() !*WithoutReady {
        const self = try allocator.create(WithoutReady);
        self.* = .{ .base = Node.init() };
        self.base.setInstance(WithoutReady, self);
        return self;
    }
    pub fn destroy(self: *WithoutReady) void {
        allocator.destroy(self);
    }
};

/// Gives `owner` a child called "Marker" and sends the notification Godot uses
/// to invoke `_ready`. The test harness has no SceneTree, so the node cannot be
/// staged the way a game would do it; the notification reaches the same virtual.
fn stage(owner: *Node) !*Node {
    const marker = Node.init();
    marker.setName(StringName.fromComptimeLatin1("Marker").*);
    owner.addChild(marker, .{});
    owner.notification(Node.NOTIFICATION_READY, .{});
    return marker;
}

test "fields resolve before the user's _ready, which still runs" {
    ensureRegistered();

    const obj = try WithReady.create();
    const marker = try stage(obj.base);

    try testing.expect(obj.ready_ran);
    try testing.expectEqual(marker, obj.marker.get().?);

    // A path the scene does not have is a null to branch on, not a crash.
    try testing.expectEqual(@as(?*Node, null), obj.missing.get());

    obj.base.queueFree();
}

test "fields resolve for a class that declares no _ready" {
    ensureRegistered();

    const obj = try WithoutReady.create();
    const marker = try stage(obj.base);

    try testing.expectEqual(marker, obj.marker.get().?);

    obj.base.queueFree();
}

test "a resolved child goes dead when the node is freed" {
    ensureRegistered();

    const obj = try WithoutReady.create();
    const marker = try stage(obj.base);
    try testing.expect(obj.marker.get() != null);

    // `Child` holds a Weak, so it stays honest after resolution.
    marker.destroy();
    try testing.expectEqual(@as(?*Node, null), obj.marker.get());

    obj.base.queueFree();
}

const gdzig = @import("gdzig");
const Child = gdzig.Child;
const allocator = gdzig.testing.allocator;
const Node = gdzig.class.Node;
const Node3d = gdzig.class.Node3d;
const StringName = gdzig.builtin.StringName;

test "getNodeAs narrows to the asked-for type, and nulls rather than complaining" {
    ensureRegistered();

    const obj = try WithReady.create();
    const marker = try stage(obj.base);

    // Found, and it is what was asked for. A plain string for the path: the
    // parameter coerces, so there is no NodePath to build and free.
    try testing.expectEqual(marker, obj.base.getNodeAs(Node, "Marker").?);

    // Found, but a plain Node is not a Node3D. The answer is null, not a
    // pointer typed as a class the object is not -- which is the whole reason
    // this exists rather than a cast at the call site.
    try testing.expectEqual(@as(?*Node3d, null), obj.base.getNodeAs(Node3d, "Marker"));

    // Nothing at that path. `get_node_or_null` underneath, so an absent node is
    // a case to branch on and not an engine error in the log.
    try testing.expectEqual(@as(?*Node, null), obj.base.getNodeAs(Node, "Nope"));

    obj.base.queueFree();
}

test "childrenAs yields the children of that type and skips the rest" {
    ensureRegistered();

    const owner = Node.init();
    // Freeing a node frees its children, so the two below need no cleanup.
    defer owner.destroy();

    const plain = Node.init();
    owner.addChild(plain, .{});
    const spatial = Node3d.init();
    owner.addChild(spatial, .{});

    // A mixed set of children is the normal case: the plain Node is skipped
    // rather than reported, and the Node3D comes back as itself.
    var spatials = owner.childrenAs(Node3d);
    try testing.expectEqual(spatial, spatials.next().?);
    try testing.expectEqual(@as(?*Node3d, null), spatials.next());

    // Asking for the wider type gets both -- the filter is "is a T", not
    // "is exactly a T".
    var nodes = owner.childrenAs(Node);
    var count: usize = 0;
    while (nodes.next()) |_| count += 1;
    try testing.expectEqual(@as(usize, 2), count);
}
