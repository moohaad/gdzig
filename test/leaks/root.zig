pub fn register(r: *gdzig.extension.Registry) void {
    const class = r.createClass(RefReturnNode, {}, .auto);
    class.addMethod("get_borrowed_resource", .auto);
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

test "Variant return from bound method holds a reference to borrowed RefCounted" {
    ensureRegistered();

    const node = try RefReturnNode.create();
    defer node.base.destroy();

    try testing.expectEqual(@as(i32, 1), node.resource.getReferenceCount());

    var result = Object.call(.upcast(node), .fromComptimeLatin1("get_borrowed_resource"), .{});
    try testing.expectEqual(node.resource, result.as(*Resource).?);
    try testing.expectEqual(@as(i32, 2), node.resource.getReferenceCount());

    result.deinit();
    try testing.expectEqual(@as(i32, 1), node.resource.getReferenceCount());
}

test "engine object survives a temporary Ref taken by an engine call" {
    const resource = Resource.init();
    try testing.expectEqual(@as(i32, 1), resource.getReferenceCount());

    // ResourceSaver.getRecognizedExtensions takes its `Resource` argument by
    // `const Ref<Resource> &` on the engine side. Godot constructs a temporary
    // Ref<Resource> around our raw pointer for the duration of this call, and
    // releases it before returning. If init() left the object's "pending"
    // ref uninitialized, this temporary Ref is treated as the first-ever
    // wrap, and releasing it drops the refcount to zero and frees the object
    // out from under us.
    var extensions = ResourceSaver.getRecognizedExtensions(resource);
    defer extensions.deinit();

    try testing.expectEqual(@as(i32, 1), resource.getReferenceCount());

    try testing.expect(resource.unreference());
    resource.destroy();
}

test "variant reference counting" {
    const object = RefCounted.init();
    try testing.expectEqual(@as(i32, 1), object.getReferenceCount());

    const variant = Variant.init(*RefCounted, object);
    try testing.expectEqual(@as(i32, 2), object.getReferenceCount());

    for (0..10) |_| {
        general.print(variant, .{ object, variant });
    }

    try testing.expectEqual(@as(i32, 2), object.getReferenceCount());
    variant.deinit();
    try testing.expectEqual(@as(i32, 1), object.getReferenceCount());
    try testing.expect(object.unreference());
    object.destroy();
}

test "Gd.adopt takes over the existing reference without adding one" {
    const resource = Resource.init();
    try testing.expectEqual(@as(i32, 1), resource.getReferenceCount());

    var handle: Gd(Resource) = .adopt(resource);
    try testing.expectEqual(@as(i32, 1), resource.getReferenceCount());
    try testing.expectEqual(resource, handle.get());

    // Releases the reference adopted above; the object is freed here.
    handle.deinit();
}

test "Gd.borrow adds a reference, leaving the original owner intact" {
    const resource = Resource.init();
    defer {
        if (!resource.unreference()) @panic("resource still has external references");
        resource.destroy();
    }
    try testing.expectEqual(@as(i32, 1), resource.getReferenceCount());

    var handle: Gd(Resource) = .borrow(resource);
    try testing.expectEqual(@as(i32, 2), resource.getReferenceCount());

    handle.deinit();
    try testing.expectEqual(@as(i32, 1), resource.getReferenceCount());
}

test "Gd.clone yields an independently releasable handle" {
    const resource = Resource.init();

    var first: Gd(Resource) = .adopt(resource);
    var second = first.clone();
    try testing.expectEqual(@as(i32, 2), resource.getReferenceCount());

    first.deinit();
    try testing.expectEqual(@as(i32, 1), resource.getReferenceCount());

    // Last handle standing; frees the object.
    second.deinit();
}

test "Gd.release hands ownership back to the caller" {
    const resource = Resource.init();

    var handle: Gd(Resource) = .adopt(resource);
    const raw = handle.release();
    try testing.expectEqual(resource, raw);

    // `release` did not touch the refcount, so the caller still owes exactly
    // the one reference that `adopt` took over.
    try testing.expectEqual(@as(i32, 1), raw.getReferenceCount());
    try testing.expect(raw.unreference());
    raw.destroy();
}

test "Gd.upcast preserves the reference across the type change" {
    const resource = Resource.init();

    var derived: Gd(Resource) = .adopt(resource);
    var base = derived.upcast(RefCounted);

    // Ownership moved to `base`; no reference was gained or lost.
    try testing.expectEqual(@as(i32, 1), resource.getReferenceCount());
    try testing.expectEqual(RefCounted.upcast(resource), base.get());

    base.deinit();
}

test "a generated method returning a refcounted class hands back an owned reference" {
    const resource = Resource.init();
    defer {
        if (!resource.unreference()) @panic("resource still has external references");
        resource.destroy();
    }

    // `duplicate` is generated as `?Gd(Resource)`. The engine already took the
    // reference on our behalf, so the handle adopts it rather than taking a
    // second one -- a count of 1 here is what says `adopt` and not `borrow` is
    // the right conversion. A 2 would mean we over-referenced and the object
    // can never be freed; a 0 would mean the pointer was borrowed and adopting
    // it frees an object we do not own.
    var copy = resource.duplicate(.{}).?;
    try testing.expectEqual(@as(i32, 1), copy.get().getReferenceCount());

    // Sole owner, so this is the release that frees it.
    copy.deinit();
}

test "an absent refcounted return is null rather than a handle to nothing" {
    // A fresh MeshInstance3D has no mesh, so the engine writes a null object
    // pointer. The optional has to absorb that: adopting null would hand back a
    // handle whose `deinit` dereferences it.
    const instance = MeshInstance3d.init();
    defer instance.destroy();

    try testing.expectEqual(@as(?Gd(Mesh), null), instance.getMesh());
}

const RefReturnNode = struct {
    base: *Node,
    resource: *Resource,

    pub fn create() !*RefReturnNode {
        const self: *RefReturnNode = allocator.create(RefReturnNode) catch @panic("out of memory");
        self.* = .{
            .base = Node.init(),
            .resource = Resource.init(),
        };
        self.base.setInstance(RefReturnNode, self);
        return self;
    }

    pub fn destroy(self: *RefReturnNode) void {
        if (!self.resource.unreference()) @panic("resource still has external references");
        self.resource.destroy();
        allocator.destroy(self);
    }

    pub fn getBorrowedResource(self: *RefReturnNode) *Resource {
        return self.resource;
    }
};

const std = @import("std");
const testing = std.testing;

const gdzig = @import("gdzig");
const general = gdzig.general;
const Gd = gdzig.Gd;
const allocator = gdzig.testing.allocator;
const Mesh = gdzig.class.Mesh;
const MeshInstance3d = gdzig.class.MeshInstance3d;
const Node = gdzig.class.Node;
const Object = gdzig.class.Object;
const RefCounted = gdzig.class.RefCounted;
const Resource = gdzig.class.Resource;
const ResourceSaver = gdzig.class.ResourceSaver;
const Variant = gdzig.builtin.Variant;
