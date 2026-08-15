//! `Scene(tscn)` — scene children as fields, derived from the file.
//!
//! `src/scene.zig` unit-tests the parser and the shape of the struct it builds.
//! What only shows up here is the runtime half: the vtable has to synthesise a
//! `_ready` for a class whose only children are inside a `Scene` field, and
//! `resolveAll` has to descend into that field rather than skipping it as an
//! ordinary struct.
//!
//! The fixture is a real `.tscn` covering the cases that differ: a direct
//! child, a nested one, a typed node, an instanced sub-scene with no type of
//! its own, and a node the tree deliberately will not have.

const std = @import("std");
const testing = std.testing;

pub fn register(r: *gdzig.extension.Registry) void {
    _ = r.createClass(Staged, {}, .auto);
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

const Fixture = Scene(@embedFile("fixture.tscn"));

/// Declares no `_ready` and no `Child` field -- only the `Scene`. If the vtable
/// does not look inside it, this class gets no `_ready` at all and every field
/// below stays null.
const Staged = struct {
    base: *Node,
    children: Fixture = .{},

    pub fn create() !*Staged {
        const self = try allocator.create(Staged);
        self.* = .{ .base = Node.init() };
        self.base.setInstance(Staged, self);
        return self;
    }
    pub fn destroy(self: *Staged) void {
        allocator.destroy(self);
    }
};

fn named(comptime T: type, comptime name: [:0]const u8) *Node {
    const node = Node.upcast(T.init());
    node.setName(StringName.fromComptimeLatin1(name).*);
    return node;
}

/// Builds the tree the fixture describes, minus "Absent", then sends the
/// notification Godot uses to invoke `_ready`. The harness has no SceneTree, so
/// the node cannot be staged the way a game would; the notification reaches the
/// same virtual.
fn stage(owner: *Node) void {
    owner.addChild(named(Node, "Marker"), .{});
    owner.addChild(named(Sprite2d, "Sprite"), .{});
    owner.addChild(named(Node, "Instanced"), .{});
    // Typed `Timer` in the fixture, staged as a plain Node on purpose.
    owner.addChild(named(Node, "Mismatch"), .{});

    const branch = named(Node, "Branch");
    owner.addChild(branch, .{});
    branch.addChild(named(Node, "Leaf"), .{});

    owner.notification(Node.NOTIFICATION_READY, .{});
}

test "the struct has one field per child, and none for the root" {
    const fields = @typeInfo(Fixture).@"struct".fields;
    try testing.expectEqual(@as(usize, 7), fields.len);

    // "Root" is the class itself, so it is not among them.
    inline for (fields) |field| {
        try testing.expect(!std.mem.eql(u8, "Root", field.name));
    }
}

test "children resolve even though the class declares no _ready" {
    ensureRegistered();

    const obj = try Staged.create();
    defer obj.base.destroy();
    stage(obj.base);

    try testing.expect(obj.children.Marker.get() != null);
    try testing.expect(obj.children.Sprite.get() != null);
}

test "a nested node resolves through its parent's path" {
    ensureRegistered();

    const obj = try Staged.create();
    defer obj.base.destroy();
    stage(obj.base);

    // The field is "Leaf" but the path the fixture gives is "Branch/Leaf".
    try testing.expect(obj.children.Branch.get() != null);
    try testing.expect(obj.children.Leaf.get() != null);
}

test "a missing node leaves its field null rather than failing the rest" {
    ensureRegistered();

    const obj = try Staged.create();
    defer obj.base.destroy();
    stage(obj.base);

    // "Absent" is in the fixture and deliberately not in the tree. It logs and
    // returns null; the siblings around it still resolved.
    try testing.expect(obj.children.Absent.get() == null);
    try testing.expect(obj.children.Marker.get() != null);
}

test "the declared type is enforced, both ways" {
    ensureRegistered();

    const obj = try Staged.create();
    defer obj.base.destroy();
    stage(obj.base);

    // "Sprite" is typed Sprite2D in the fixture and staged as one, so the field
    // is a *Sprite2d and not merely a node that happens to be there.
    const sprite = obj.children.Sprite.get();
    try testing.expect(sprite != null);
    try testing.expectEqual(*gdzig.class.Sprite2d, @TypeOf(sprite.?));

    // "Mismatch" is typed Timer and staged as a plain Node. The cast fails, so
    // it reads as absent rather than handing back the wrong type.
    try testing.expect(obj.children.Mismatch.get() == null);

    // An instanced sub-scene has no type of its own, so it falls back to Node
    // and matches whatever is there.
    try testing.expect(obj.children.Instanced.get() != null);
}

const gdzig = @import("gdzig");
const allocator = gdzig.testing.allocator;
const Scene = gdzig.Scene;
const Node = gdzig.class.Node;
const Sprite2d = gdzig.class.Sprite2d;
const StringName = gdzig.builtin.StringName;
