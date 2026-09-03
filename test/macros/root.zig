//! The convenience layer: `array`, `dict`, `print`, `callable`, the persistence
//! helpers, and the generic containers.
//!
//! None of it had a test, and in Zig that means none of it had been *compiled*
//! either: an unreferenced declaration is never analysed, so a helper can sit in
//! the tree for months and still not build. Half the value here is simply
//! naming every one of them so the compiler has to look.

pub fn register(r: *gdzig.extension.Registry) void {
    r.autoRegister(PersistNode);
    r.autoRegister(MigratingNode);
    r.autoRegister(BindNode);
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

test "array builds a Godot Array from a tuple" {
    var arr = gdzig.array(.{ @as(i64, 1), @as(i64, 2), @as(i64, 3) });
    defer arr.deinit();

    try testing.expectEqual(@as(i64, 3), arr.size());

    var first = arr.get(0);
    defer first.deinit();
    try testing.expectEqual(@as(i64, 1), first.as(i64).?);

    var last = arr.get(2);
    defer last.deinit();
    try testing.expectEqual(@as(i64, 3), last.as(i64).?);
}

test "dict builds a Godot Dictionary from a struct" {
    var d = gdzig.dict(.{ .health = @as(i64, 42), .armour = @as(i64, 7) });
    defer d.deinit();

    try testing.expectEqual(@as(i64, 2), d.size());

    var key: StringName = .fromLatin1("health", false);
    defer key.deinit();
    var got = d.get(.init(StringName, key), .{});
    defer got.deinit();
    try testing.expectEqual(@as(i64, 42), got.as(i64).?);
}

test "print formats without crashing, including past its buffer" {
    // The output goes to Godot's console, which cannot be read back from here.
    // What is worth pinning is that it survives both the ordinary case and the
    // one the implementation has a branch for: a message too long to fit.
    gdzig.print("macros test: {d} and {s}", .{ 42, "text" });

    const long = "x" ** 40_000;
    gdzig.print("{s}", .{long});
}

test "callable wraps a Zig function and passes arguments through" {
    var total: i64 = 0;

    var cb = gdzig.callable(allocator, &total, addTo);
    defer cb.deinit();

    var args = gdzig.array(.{@as(i64, 5)});
    defer args.deinit();

    var result = cb.callv(args);
    defer result.deinit();

    try testing.expectEqual(@as(i64, 5), total);
    try testing.expectEqual(@as(i64, 5), result.as(i64).?);
}

fn addTo(ctx: *i64, value: i64) i64 {
    ctx.* += value;
    return ctx.*;
}

test "autoPersist writes fields to metadata and autoRestore reads them back" {
    ensureRegistered();

    const node = try PersistNode.create();
    defer node.destroy();

    node.health = 77;
    node.speed = 3.5;
    gdzig.autoPersist(node);

    // Cleared, so a restore that does nothing is distinguishable from one that
    // works.
    node.health = 0;
    node.speed = 0;

    gdzig.autoRestore(node);

    try testing.expectEqual(@as(i64, 77), node.health);
    try testing.expectEqual(@as(f64, 3.5), node.speed);
}

test "autoRestore releases an owning value before replacing it" {
    ensureRegistered();

    var persisted = Resource.init();
    defer persisted.deinit();
    var displaced = Resource.init();
    defer displaced.deinit();

    const persisted_counted = RefCounted.upcast(persisted.get());
    const displaced_counted = RefCounted.upcast(displaced.get());
    const persisted_before = persisted_counted.getReferenceCount();
    const displaced_before = displaced_counted.getReferenceCount();

    {
        const node = try PersistNode.create();
        defer node.destroy();

        node.resource = Gd(Resource).borrow(persisted.get());
        gdzig.autoPersist(node);

        if (node.resource) |*resource| resource.deinit();
        node.resource = Gd(Resource).borrow(displaced.get());
        try testing.expectEqual(displaced_before + 1, displaced_counted.getReferenceCount());

        gdzig.autoRestore(node);

        try testing.expectEqual(displaced_before, displaced_counted.getReferenceCount());
        try testing.expectEqual(persisted_before + 1, persisted_counted.getReferenceCount());
        try testing.expect(node.resource != null);
        try testing.expectEqual(persisted.get(), node.resource.?.get());
    }

    try testing.expectEqual(persisted_before, persisted_counted.getReferenceCount());
    try testing.expectEqual(displaced_before, displaced_counted.getReferenceCount());
}

test "autoRestore preserves metadata that cannot be decoded" {
    ensureRegistered();

    const node = try PersistNode.create();
    defer node.destroy();

    const key = StringName.fromComptimeLatin1("gdzig_persist_speed");
    var incompatible: Variant = .init(i64, 42);
    defer incompatible.deinit();
    node.base.setMeta(key.*, incompatible);
    node.speed = 3.5;

    gdzig.autoRestore(node);

    try testing.expectEqual(@as(f64, 3.5), node.speed);
    try testing.expect(node.base.hasMeta(key.*));
    var remaining = node.base.getMeta(key.*, .{});
    defer remaining.deinit();
    try testing.expectEqual(@as(i64, 42), remaining.as(i64).?);
}

test "versioned persistence records and consumes the current schema version" {
    ensureRegistered();

    const node = try MigratingNode.create();
    defer node.destroy();

    node.health = 9;
    gdzig.autoPersist(node);

    const version_key = StringName.fromComptimeLatin1("gdzig_persist__version");
    try testing.expect(node.base.hasMeta(version_key.*));
    var version = node.base.getMeta(version_key.*, .{});
    defer version.deinit();
    try testing.expectEqual(@as(i64, 2), version.as(i64).?);

    node.health = 0;
    gdzig.autoRestore(node);

    try testing.expectEqual(@as(i64, 9), node.health);
    try testing.expect(!node.base.hasMeta(version_key.*));
}

test "autoRestore applies every missing persistence migration in order" {
    ensureRegistered();

    const node = try MigratingNode.create();
    defer node.destroy();

    const old_key = StringName.fromComptimeLatin1("gdzig_persist_hit_points");
    const new_key = StringName.fromComptimeLatin1("gdzig_persist_health");
    var old_value: Variant = .init(i64, 21);
    defer old_value.deinit();
    node.base.setMeta(old_key.*, old_value);

    gdzig.autoRestore(node);

    try testing.expectEqual(@as(i64, 42), node.health);
    try testing.expect(!node.base.hasMeta(old_key.*));
    try testing.expect(!node.base.hasMeta(new_key.*));
}

test "a failed persistence migration retains the original metadata atomically" {
    ensureRegistered();

    const node = try MigratingNode.create();
    defer node.destroy();

    const old_key = StringName.fromComptimeLatin1("gdzig_persist_hit_points");
    const new_key = StringName.fromComptimeLatin1("gdzig_persist_health");
    var old_value: Variant = .init(i64, 13);
    defer old_value.deinit();
    node.base.setMeta(old_key.*, old_value);
    node.health = 7;

    gdzig.autoRestore(node);

    try testing.expectEqual(@as(i64, 7), node.health);
    try testing.expect(node.base.hasMeta(old_key.*));
    try testing.expect(!node.base.hasMeta(new_key.*));
    var retained = node.base.getMeta(old_key.*, .{});
    defer retained.deinit();
    try testing.expectEqual(@as(i64, 13), retained.as(i64).?);

    // A later destroy/reload must not replace the recovery copy with state
    // from the instance whose restore failed.
    node.health = 99;
    gdzig.autoPersist(node);
    try testing.expect(node.base.hasMeta(old_key.*));
    try testing.expect(!node.base.hasMeta(new_key.*));
}

test "an incompatible migrated value rolls the migration back" {
    ensureRegistered();

    const node = try MigratingNode.create();
    defer node.destroy();

    const old_key = StringName.fromComptimeLatin1("gdzig_persist_hit_points");
    const new_key = StringName.fromComptimeLatin1("gdzig_persist_health");
    var old_value: Variant = .init(f64, 3.5);
    defer old_value.deinit();
    node.base.setMeta(old_key.*, old_value);
    node.health = 7;

    gdzig.autoRestore(node);

    try testing.expectEqual(@as(i64, 7), node.health);
    try testing.expect(node.base.hasMeta(old_key.*));
    try testing.expect(!node.base.hasMeta(new_key.*));
}

test "a future persistence version is retained instead of downgraded" {
    ensureRegistered();

    const node = try MigratingNode.create();
    defer node.destroy();

    const health_key = StringName.fromComptimeLatin1("gdzig_persist_health");
    const version_key = StringName.fromComptimeLatin1("gdzig_persist__version");
    var health: Variant = .init(i64, 99);
    defer health.deinit();
    var version: Variant = .init(i64, 3);
    defer version.deinit();
    node.base.setMeta(health_key.*, health);
    node.base.setMeta(version_key.*, version);
    node.health = 7;

    gdzig.autoRestore(node);

    try testing.expectEqual(@as(i64, 7), node.health);
    try testing.expect(node.base.hasMeta(health_key.*));
    try testing.expect(node.base.hasMeta(version_key.*));
}

test "Pool destroys what it holds when it is deinitialised" {
    var pool = try gdzig.Pool(Node).init(allocator, 3);

    // The pool builds its objects up front, so these are the three it owns.
    // Ids rather than pointers: after a correct `deinit` the pointers dangle,
    // and an id can be asked about safely.
    try testing.expectEqual(@as(usize, 3), pool.available.items.len);
    var ids: [3]i64 = undefined;
    for (pool.available.items, 0..) |node, i| {
        ids[i] = @intCast(Object.upcast(node).getInstanceId());
        try testing.expect(gdzig.general.isInstanceIdValid(ids[i]));
    }

    pool.deinit();

    // Freeing the list is not freeing what was in it. Without this, a pool of
    // a hundred nodes leaks a hundred nodes at teardown.
    for (ids) |id| {
        try testing.expect(!gdzig.general.isInstanceIdValid(id));
    }
}

test "inEditor and inGame agree with the engine, and with each other" {
    // Asserted against `isEditorHint` rather than against a hard-coded true or
    // false, so this says the same thing whether it runs under the editor or
    // not -- and still catches either one being inverted.
    try testing.expectEqual(Engine.isEditorHint(), gdzig.inEditor());
    try testing.expectEqual(!Engine.isEditorHint(), gdzig.inGame());
    try testing.expect(gdzig.inEditor() != gdzig.inGame());
}

test "bind_nodes fields are filled before _ready, without calling bindNodes" {
    ensureRegistered();

    const owner = try BindNode.create();
    defer owner.destroy();

    const marker = Node.init();
    marker.setName(StringName.fromComptimeLatin1("Marker").*);
    owner.base.addChild(marker, .{});

    // The notification Godot sends to invoke `_ready`. Nothing here calls
    // `bindNodes`: the point is that the class machinery does, in the same
    // place it resolves `Child` fields, so the two ways of naming a child
    // behave alike.
    owner.base.notification(Node.NOTIFICATION_READY, .{});

    try testing.expectEqual(marker, owner.marker.?);
    try testing.expectEqual(@as(?*Node, null), owner.missing);
}

test "bindNodes fills the fields its declaration names" {
    const owner = try BindNode.create();
    defer owner.destroy();

    const marker = Node.init();
    marker.setName(StringName.fromComptimeLatin1("Marker").*);
    owner.base.addChild(marker, .{});

    gdzig.bindNodes(owner);

    try testing.expectEqual(marker, owner.marker.?);

    // A path the scene does not have leaves the field alone rather than
    // binding something wrong.
    try testing.expectEqual(@as(?*Node, null), owner.missing);
}

test "bindNodes on a class that declares nothing is a no-op" {
    // `bindNodes` returns early when there is no `bind_nodes`, which is also
    // what happens when the declaration is misspelled. Worth pinning that it at
    // least does not fault.
    const plain = try PersistNode.create();
    defer plain.destroy();

    gdzig.bindNodes(plain);
}

// Names the helpers a test cannot drive without a live scene tree, so the
// compiler still has to analyse them. Unreferenced, they are never built.
test "the scene-tree helpers compile" {
    _ = &gdzig.getNodesInGroupAs;
    _ = &gdzig.tween;
    _ = gdzig.Pool(Node);
    _ = &gdzig.Pool(Node).init;
    _ = &gdzig.Pool(Node).acquire;
    _ = &gdzig.Pool(Node).release;
    _ = &gdzig.Pool(Node).deinit;
    _ = gdzig.EventBus(.{});
    _ = &gdzig.EventBus(.{}).create;
    _ = &gdzig.EventBus(.{}).destroy;
    _ = gdzig.TweenBuilder;
}

const BindNode = struct {
    base: *Node,

    marker: ?*Node = null,
    missing: ?*Node = null,

    /// What `bindNodes` reads: a field name and the path to fill it from.
    pub const bind_nodes = .{
        .{ "marker", "Marker" },
        .{ "missing", "NoSuchChild" },
    };

    pub fn create() !*BindNode {
        const self = try allocator.create(BindNode);
        self.* = .{ .base = Node.init() };
        self.base.setInstance(BindNode, self);
        return self;
    }

    pub fn destroy(self: *BindNode) void {
        self.base.destroy();
        allocator.destroy(self);
    }
};

const PersistNode = struct {
    base: *Node,

    health: i64 = 0,
    speed: f64 = 0,
    resource: ?Gd(Resource) = null,

    pub fn create() !*PersistNode {
        const self = try allocator.create(PersistNode);
        self.* = .{ .base = Node.init() };
        self.base.setInstance(PersistNode, self);
        return self;
    }

    pub fn destroy(self: *PersistNode) void {
        self.base.destroy();
        allocator.destroy(self);
    }
};

const MigratingNode = struct {
    base: *Node,
    health: i64 = 0,

    pub const persist_version: u32 = 2;

    pub fn migratePersisted(from_version: u32, state: *gdzig.persist.Migration) !void {
        switch (from_version) {
            0 => _ = try state.rename("hit_points", "health"),
            1 => if (state.get(i64, "health")) |health| {
                if (health == 13) return error.DeliberateMigrationFailure;
                try state.set("health", health * 2);
            },
            else => return error.UnsupportedPersistVersion,
        }
    }

    pub fn create() !*MigratingNode {
        const self = try allocator.create(MigratingNode);
        self.* = .{ .base = Node.init() };
        self.base.setInstance(MigratingNode, self);
        return self;
    }

    pub fn destroy(self: *MigratingNode) void {
        self.base.destroy();
        allocator.destroy(self);
    }
};

const std = @import("std");
const testing = std.testing;

const gdzig = @import("gdzig");
const allocator = gdzig.testing.allocator;
const Gd = gdzig.Gd;
const Node = gdzig.class.Node;
const Object = gdzig.class.Object;
const Engine = gdzig.class.Engine;
const Resource = gdzig.class.Resource;
const RefCounted = gdzig.class.RefCounted;
const StringName = gdzig.builtin.StringName;
const Variant = gdzig.builtin.Variant;
