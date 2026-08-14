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

test "a child freed by its parent is reported dead" {
    // The case that motivates storing a handle rather than a pointer: you never
    // freed the node, its owner did. `example/src/ExampleNode.zig` keeps exactly
    // this shape -- a child handed to a container that outlives the reference.
    const parent = Node.init();
    const child = Node.init();
    parent.addChild(child, .{});

    const handle: Weak(Node) = .init(child);
    try testing.expect(handle.isValid());

    // Frees the subtree, child included; nothing here touches `child` directly.
    parent.destroy();

    try testing.expect(!handle.isValid());
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

test "queueFree does not trip the free-while-dispatching guard" {
    // The guard exists to catch an object freed out from under a running
    // method. `queueFree` defers to the end of the frame, so it must not fire
    // -- a detector that flagged the *recommended* way to free a node would be
    // worse than none. Nothing here is in a dispatch, but the same holds
    // inside one, which is the case the guard is aimed at.
    const node = Node.init();
    const handle: Weak(Node) = .init(node);

    node.queueFree();
    // Still alive: the free is queued, not done.
    try testing.expect(handle.isValid());

    // No scene tree here to flush the queue, so free it properly.
    node.destroy();
    try testing.expect(!handle.isValid());
}

const gdzig = @import("gdzig");
const Weak = gdzig.Weak;

const Node = gdzig.class.Node;
const Node2d = gdzig.class.Node2d;
const RefCounted = gdzig.class.RefCounted;
const Resource = gdzig.class.Resource;
