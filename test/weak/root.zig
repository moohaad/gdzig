//! `Weak(T)` against a live engine.
//!
//! The hazard is a pointer to a freed object. `Node` has no refcount to lean
//! on, so a `*Node` kept across frames is exactly the thing that goes stale
//! without warning, and these tests are about it being observable afterwards
//! rather than fatal.

const std = @import("std");
const testing = std.testing;

test "a handle to a live node resolves to the same pointer" {
    const node = Node.init();
    defer node.destroy();

    const handle: Weak(Node) = .init(node);
    try testing.expect(handle.isValid());
    try testing.expectEqual(node, handle.get().?);
    try testing.expectEqual(node, handle.expect());
}

test "a handle to a freed node reports dead instead of dangling" {
    const node = Node.init();
    const handle: Weak(Node) = .init(node);
    try testing.expect(handle.isValid());

    node.destroy();

    // The whole point: this is a null to branch on, where a bare `*Node` would
    // have been a dangling pointer with nothing to test.
    try testing.expect(!handle.isValid());
    try testing.expectEqual(@as(?*Node, null), handle.get());
}

test "the instance id outlives the object" {
    const node = Node.init();
    const handle: Weak(Node) = .init(node);
    const id = handle.instanceId();
    try testing.expect(id != 0);

    node.destroy();

    // Still readable, which is what makes it usable as a key or in a log line
    // after the fact.
    try testing.expectEqual(id, handle.instanceId());
    try testing.expect(!handle.isValid());
}

test "a weak handle to a refcounted object keeps nothing alive" {
    var owner = Resource.init();
    const handle: Weak(Resource) = .init(owner.get());

    try testing.expect(handle.isValid());
    // Weak, so the count is unchanged by its existence -- no cycle, no leak.
    try testing.expectEqual(@as(i32, 1), RefCounted.upcast(owner.get()).getReferenceCount());

    // Last owner releases; the object goes with it.
    owner.deinit();
    try testing.expect(!handle.isValid());
}

test "upcast keeps the identity of the object" {
    const node = Node2d.init();
    defer node.destroy();

    const derived: Weak(Node2d) = .init(node);
    const base = derived.upcast(Node);

    try testing.expectEqual(derived.instanceId(), base.instanceId());
    try testing.expectEqual(Node.upcast(node), base.get().?);
}

const gdzig = @import("gdzig");
const Weak = gdzig.Weak;

const Node = gdzig.class.Node;
const Node2d = gdzig.class.Node2d;
const RefCounted = gdzig.class.RefCounted;
const Resource = gdzig.class.Resource;
