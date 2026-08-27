pub fn register(r: *gdzig.extension.Registry) void {
    const class = r.createClass(RefReturnNode, {}, .auto);
    class.addMethod("get_borrowed_resource", .auto);

    const probe_class = r.createClass(LeakProbeResource, r.allocator, .auto);
    probe_class.addMethod("ping", .auto);
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

    var result = gdzig.call(node, "get_borrowed_resource", .{});
    try testing.expectEqual(node.resource, result.as(*Resource).?);
    try testing.expectEqual(@as(i32, 2), node.resource.getReferenceCount());

    result.deinit();
    try testing.expectEqual(@as(i32, 1), node.resource.getReferenceCount());
}

test "a constructor hands back a handle owning the initial reference" {
    var resource = Resource.init();
    try testing.expectEqual(@as(i32, 1), resource.get().getReferenceCount());

    // Sole owner, so this frees it.
    resource.deinit();
}

test "engine object survives a temporary Ref taken by an engine call" {
    const resource = rawResource();
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
    var owned = RefCounted.init();
    const object = owned.release();
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
    const resource = rawResource();
    try testing.expectEqual(@as(i32, 1), resource.getReferenceCount());

    var handle: Gd(Resource) = .adopt(resource);
    try testing.expectEqual(@as(i32, 1), resource.getReferenceCount());
    try testing.expectEqual(resource, handle.get());

    // Releases the reference adopted above; the object is freed here.
    handle.deinit();
}

test "Gd.borrow adds a reference, leaving the original owner intact" {
    const resource = rawResource();
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
    const resource = rawResource();

    var first: Gd(Resource) = .adopt(resource);
    var second = first.clone();
    try testing.expectEqual(@as(i32, 2), resource.getReferenceCount());

    first.deinit();
    try testing.expectEqual(@as(i32, 1), resource.getReferenceCount());

    // Last handle standing; frees the object.
    second.deinit();
}

test "Gd.release hands ownership back to the caller" {
    const resource = rawResource();

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
    const resource = rawResource();

    var derived: Gd(Resource) = .adopt(resource);
    var base = derived.upcast(RefCounted);

    // Ownership moved to `base`; no reference was gained or lost.
    try testing.expectEqual(@as(i32, 1), resource.getReferenceCount());
    try testing.expectEqual(RefCounted.upcast(resource), base.get());

    base.deinit();
}

test "a generated method returning a refcounted class hands back an owned reference" {
    const resource = rawResource();
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

test "the vararg return shape takes its own reference before releasing the Variant" {
    const resource = rawResource();
    defer {
        if (!resource.unreference()) @panic("resource still has external references");
        resource.destroy();
    }

    // Written out the way codegen emits it for a vararg function returning a
    // refcounted class. No such function exists in 4.7 -- every vararg method
    // returns void, Variant, Error, String or Callable -- so this stands in for
    // generated code that cannot be called yet, and pins the semantics for when
    // some future Godot adds one.
    var result: Variant = .init(*Resource, resource);
    try testing.expectEqual(@as(i32, 2), resource.getReferenceCount());

    var handle = blk: {
        defer result.deinit();
        // `borrow`, not `adopt`: the reference is the Variant's and the defer
        // above drops it. Adopting would leave the handle owning a count that
        // just went away.
        break :blk if (result.as(*Resource)) |ptr| Gd(Resource).borrow(ptr) else null;
    };

    // The Variant is gone and the handle holds a reference of its own, so we
    // are back to two owners: this handle and the caller's `resource`.
    try testing.expectEqual(@as(i32, 2), resource.getReferenceCount());

    handle.?.deinit();
    try testing.expectEqual(@as(i32, 1), resource.getReferenceCount());
}

/// A bare owned `*Resource`, which is what the refcount-mechanics tests below
/// want to start from. `init` returns a handle now, and `release` is the
/// supported way back to a raw pointer the caller is responsible for.
fn rawResource() *Resource {
    var owned = Resource.init();
    return owned.release();
}

/// A registered class whose *base* is reference counted, which is the shape
/// this repo did not have. `RefReturnNode` below looks similar and is not: its
/// base is a plain `Node` and the refcounted object is a field it owns and
/// releases itself. The difference is who constructs the refcounted object --
/// there, we do; here, the engine does, through the class create callback.
///
/// That gap is why a reference leaked on every such instance for as long as it
/// did: nothing instantiated one, so nothing noticed it was never freed.
const LeakProbeResource = struct {
    allocator: std.mem.Allocator,
    base: *Resource,

    /// Counts frees. The engine calls this when the last reference goes, so a
    /// zero after dropping the only handle means the object outlived it.
    var destroyed: usize = 0;

    /// `create` is deliberately left to gdzig -- it is the code under test.
    /// This overrides only the free half, and matches what the synthesized one
    /// does for a counted base: no `base.destroy()`, because the engine is
    /// already freeing the object that called this.
    /// Exists only so this class can be the receiver of a connection.
    pub fn ping(_: *LeakProbeResource) void {}

    pub fn destroy(self: *LeakProbeResource, alloc: *std.mem.Allocator) void {
        destroyed += 1;
        alloc.destroy(self);
    }
};

test "a class over a refcounted base is freed when the engine drops it" {
    ensureRegistered();
    LeakProbeResource.destroyed = 0;

    // Through ClassDB rather than by calling `create` directly: the leak was in
    // the handover, so the engine has to be the one constructing it.
    var instance = ClassDb.instantiate(StringName.fromComptimeLatin1("LeakProbeResource").*);
    try testing.expect(instance.as(*Resource) != null);

    // The only reference. Dropping it should take the object to zero and run
    // `destroy`; with one reference too many it stays alive and nothing runs.
    instance.deinit();

    try testing.expectEqual(@as(usize, 1), LeakProbeResource.destroyed);
}

const RefReturnNode = struct {
    base: *Node,
    resource: *Resource,

    pub fn create() !*RefReturnNode {
        const self: *RefReturnNode = allocator.create(RefReturnNode) catch @panic("out of memory");
        // `Node.init()` is a bare pointer -- Node is not refcounted -- while
        // `Resource.init()` is a handle, so its pointer has to be taken out
        // before it can live in a `*Resource` field. This is the same shape a
        // class extending a refcounted type hits with its `base` field.
        var resource = Resource.init();
        self.* = .{
            .base = Node.init(),
            .resource = resource.release(),
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
const Callable = gdzig.builtin.Callable;
const Gd = gdzig.Gd;
const allocator = gdzig.testing.allocator;
const ArrayMesh = gdzig.class.ArrayMesh;
const Mesh = gdzig.class.Mesh;
const MeshInstance3d = gdzig.class.MeshInstance3d;
const Node = gdzig.class.Node;
const ClassDb = gdzig.class.ClassDb;
const Object = gdzig.class.Object;
const RefCounted = gdzig.class.RefCounted;
const Resource = gdzig.class.Resource;
const ResourceSaver = gdzig.class.ResourceSaver;
const Variant = gdzig.builtin.Variant;
const StringName = gdzig.builtin.StringName;

test "an owning handle passes where a class pointer is wanted, and keeps its reference" {
    var mesh = ArrayMesh.init();
    defer mesh.deinit();

    const instance = MeshInstance3d.init();
    defer instance.destroy();

    const before = RefCounted.upcast(mesh.get()).getReferenceCount();

    // The handle itself, with no `get()`. The parameter is `anytype` and
    // `class.upcast` unwraps it.
    instance.setMesh(mesh);

    // Borrowed, not moved: this handle still owns its reference and still owes
    // a `deinit`. The engine took its own, so the count went up by one rather
    // than changing hands.
    try testing.expectEqual(before + 1, RefCounted.upcast(mesh.get()).getReferenceCount());

    var read_back = instance.getMesh() orelse return error.MeshMissing;
    defer read_back.deinit();
    try testing.expectEqual(@intFromPtr(mesh.get()), @intFromPtr(read_back.get()));
}

test "an owning handle can be the receiver of a connection" {
    ensureRegistered();

    var instance = ClassDb.instantiate(StringName.fromComptimeLatin1("LeakProbeResource").*);
    defer instance.deinit();
    const ptr = instance.as(*LeakProbeResource) orelse return error.NoInstance;

    var handle: Gd(LeakProbeResource) = .borrow(ptr);
    defer handle.deinit();

    // Compile-only, via `@TypeOf`: `Callable.fromClosure` resolves the
    // receiver's class with `std.meta.Child` before anything unwraps, so a
    // handle used to fail here rather than at the upcast further down. The
    // runtime half needs a live emitter and is not what regressed.
    try testing.expectEqual(Callable, @TypeOf(Callable.fromClosure(handle, &LeakProbeResource.ping)));
}

test "Gd.upcast finds the engine object, not the Zig struct" {
    ensureRegistered();

    var instance = ClassDb.instantiate(StringName.fromComptimeLatin1("LeakProbeResource").*);
    defer instance.deinit();
    const ptr = instance.as(*LeakProbeResource) orelse return error.NoInstance;

    // A user class is a Zig struct holding the engine object at `base`, so its
    // own address is not the object's. `oopz.upcast` knows that and reads the
    // field; a bare `@ptrCast` does not, and hands back the struct address --
    // which a later `unreference` would then apply to the wrong memory.
    var handle: Gd(LeakProbeResource) = .borrow(ptr);
    var base = handle.upcast(Resource);

    const want = @intFromPtr(gdzig.class.upcast(*Resource, ptr));
    try testing.expectEqual(want, @intFromPtr(base.ptr));

    base.deinit();
}
