/// Integration test for extending user-defined Zig classes.
///
/// Tests that ClassA extends Object, ClassB extends ClassA, and ClassC extends ClassB.
/// This validates multi-level inheritance of custom extension classes,
/// verifying through Godot's Object.call dispatch.
///
/// Derived user classes embed their parent (e.g. `base: ClassA` not `base: *ClassA`)
/// so that `*ClassB` can be safely cast to `*ClassA` — matching how Godot passes a
/// single extension instance pointer to all method callbacks.
pub fn register(r: *gdzig.extension.Registry) void {
    const class_a = r.createClass(ClassA, {}, .auto);
    class_a.addMethod("get_value_a", .auto);

    const class_b = r.createClass(ClassB, {}, .auto);
    class_b.addMethod("get_value_b", .auto);

    const class_c = r.createClass(ClassC, {}, .auto);
    class_c.addMethod("get_value_c", .auto);
    // A method taking a two-level user class: the Variant unboxing path.
    class_c.addMethod("take_c", .auto);

    // Unrelated to A/B/C on purpose: narrowing an object to this must fail.
    _ = r.createClass(Unrelated, {}, .auto);

    _ = r.createClass(VParent, {}, .auto);
    _ = r.createClass(EmbeddedReload, {}, .auto);
    _ = r.createClass(SynthParent, r.allocator, .auto);
    _ = r.createClass(SynthEmbedded, r.allocator, .auto);
    _ = r.createClass(OwnCreate, {}, .auto);
    _ = r.createClass(VDisplaced, {}, .auto);
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

test "ClassA: call method through Godot dispatch" {
    ensureRegistered();

    const a = try ClassA.create();
    defer a.base.destroy();

    const result = gdzig.call(a, "get_value_a", .{});
    try testing.expectEqual(@as(i64, 1), result.as(i64).?);
}

test "ClassB: call own method through Godot dispatch" {
    ensureRegistered();

    const b = try ClassB.create();
    defer Object.upcast(b).destroy();

    const result = gdzig.call(b, "get_value_b", .{});
    try testing.expectEqual(@as(i64, 2), result.as(i64).?);
}

test "ClassB: call inherited ClassA method through Godot dispatch" {
    ensureRegistered();

    const b = try ClassB.create();
    defer Object.upcast(b).destroy();

    const result = gdzig.call(b, "get_value_a", .{});
    try testing.expectEqual(@as(i64, 1), result.as(i64).?);
}

test "ClassC: call own method through Godot dispatch" {
    ensureRegistered();

    const c_ = try ClassC.create();
    defer Object.upcast(c_).destroy();

    const result = gdzig.call(c_, "get_value_c", .{});
    try testing.expectEqual(@as(i64, 3), result.as(i64).?);
}

test "ClassC: call inherited ClassB method through Godot dispatch" {
    ensureRegistered();

    const c_ = try ClassC.create();
    defer Object.upcast(c_).destroy();

    const result = gdzig.call(c_, "get_value_b", .{});
    try testing.expectEqual(@as(i64, 2), result.as(i64).?);
}

test "ClassC: call inherited ClassA method through Godot dispatch" {
    ensureRegistered();

    const c_ = try ClassC.create();
    defer Object.upcast(c_).destroy();

    const result = gdzig.call(c_, "get_value_a", .{});
    try testing.expectEqual(@as(i64, 1), result.as(i64).?);
}

const ClassA = struct {
    base: *Object,
    value_a: i64 = 1,

    pub fn create() !*ClassA {
        const self: *ClassA = allocator.create(ClassA) catch @panic("out of memory");
        self.* = .{ .base = Object.init() };
        self.base.setInstance(ClassA, self);
        return self;
    }

    pub fn destroy(self: *ClassA) void {
        allocator.destroy(self);
    }

    pub fn getValueA(self: *ClassA) i64 {
        return self.value_a;
    }
};

const ClassB = struct {
    base: ClassA,
    value_b: i64 = 2,

    pub fn create() !*ClassB {
        const self: *ClassB = allocator.create(ClassB) catch @panic("out of memory");
        self.* = .{
            .base = .{ .base = Object.init() },
        };
        self.base.base.setInstance(ClassB, self);
        return self;
    }

    pub fn destroy(self: *ClassB) void {
        allocator.destroy(self);
    }

    pub fn getValueB(self: *ClassB) i64 {
        return self.value_b;
    }
};

const ClassC = struct {
    base: ClassB,
    value_c: i64 = 3,

    pub fn create() !*ClassC {
        const self: *ClassC = allocator.create(ClassC) catch @panic("out of memory");
        self.* = .{
            .base = .{ .base = .{ .base = Object.init() } },
        };
        self.base.base.base.setInstance(ClassC, self);
        return self;
    }

    pub fn destroy(self: *ClassC) void {
        allocator.destroy(self);
    }

    pub fn takeC(_: *ClassC, other: *ClassC) i64 {
        return other.value_c;
    }

    pub fn getValueC(self: *ClassC) i64 {
        return self.value_c;
    }
};

const VParent = struct {
    base: *Node,
    ready_self: usize = 0,

    pub fn _ready(self: *VParent) void {
        self.ready_self = @intFromPtr(self);
    }

    pub fn create() !*VParent {
        const self: *VParent = allocator.create(VParent) catch @panic("out of memory");
        self.* = .{ .base = Node.init() };
        self.base.setInstance(VParent, self);
        return self;
    }

    pub fn destroy(self: *VParent) void {
        allocator.destroy(self);
    }
};

/// Inherits `_ready` and pushes the base off byte 0: Zig orders fields by
/// descending alignment, so a `u128` sorts ahead of the embedded parent.
const VDisplaced = struct {
    base: VParent,
    wide: u128 = 0,

    pub fn create() !*VDisplaced {
        const self: *VDisplaced = allocator.create(VDisplaced) catch @panic("out of memory");
        self.* = .{ .base = .{ .base = Node.init() } };
        self.base.base.setInstance(VDisplaced, self);
        return self;
    }

    pub fn destroy(self: *VDisplaced) void {
        allocator.destroy(self);
    }
};

/// Embedded base plus a hand-written `recreate`: the reload hook. This is the
/// shape that hits `assertBaseUnchanged`.
const EmbeddedReload = struct {
    base: ClassA,

    pub fn create() !*EmbeddedReload {
        const self: *EmbeddedReload = allocator.create(EmbeddedReload) catch @panic("out of memory");
        self.* = .{ .base = .{ .base = Object.init() } };
        self.base.base.setInstance(EmbeddedReload, self);
        return self;
    }

    pub fn recreate(obj: *Object) *EmbeddedReload {
        const self: *EmbeddedReload = allocator.create(EmbeddedReload) catch @panic("out of memory");
        self.* = .{ .base = .{ .base = obj } };
        self.base.base.setInstance(EmbeddedReload, self);
        return self;
    }

    pub fn destroy(self: *EmbeddedReload) void {
        allocator.destroy(self);
    }
};

/// Synthesized lifecycle, pointer base: the shape that already worked.
const SynthParent = struct {
    allocator: std.mem.Allocator,
    base: *Object,
    value_p: i64 = 1,
};

/// Synthesized lifecycle, embedded base.
const SynthEmbedded = struct {
    allocator: std.mem.Allocator,
    base: SynthParent,
    value_e: i64 = 2,
};

/// Has the fields gdzig could synthesize from, but writes its own zero-arg
/// `create`, so there is no allocator to hand a synthesized `recreate`.
const OwnCreate = struct {
    allocator: std.mem.Allocator,
    base: *Object,

    pub fn create() !*OwnCreate {
        const self: *OwnCreate = allocator.create(OwnCreate) catch @panic("out of memory");
        self.* = .{ .allocator = allocator, .base = Object.init() };
        self.base.setInstance(OwnCreate, self);
        return self;
    }

    pub fn destroy(self: *OwnCreate) void {
        self.base.destroy();
        allocator.destroy(self);
    }
};

/// Shares no ancestry with ClassA beyond Object itself.
const Unrelated = struct {
    base: *Object,
    value_u: i64 = 99,

    pub fn create() !*Unrelated {
        const self: *Unrelated = allocator.create(Unrelated) catch @panic("out of memory");
        self.* = .{ .base = Object.init() };
        self.base.setInstance(Unrelated, self);
        return self;
    }

    pub fn destroy(self: *Unrelated) void {
        allocator.destroy(self);
    }
};

const std = @import("std");
const testing = std.testing;

const gdzig = @import("gdzig");
const allocator = gdzig.testing.allocator;
const Node = gdzig.class.Node;
const Object = gdzig.class.Object;
const StringName = gdzig.builtin.StringName;

test "castTo narrows a user class to a user descendant" {
    const c_ = try ClassC.create();
    defer Object.upcast(c_).destroy();

    // The source is a Zig struct, so the engine object is at `base` rather than
    // at `c_` itself. `castTo` goes through `upcast`, which reads it; a
    // `@ptrCast` would hand Godot the struct's own address.
    //
    // The other arm cannot be reached from here: an engine class never derives
    // from a user class, so `castTo(Node2d, c_)` is a compile error rather than
    // a bad pointer.
    const as_b = gdzig.class.castTo(ClassB, c_) orelse return error.CastFailed;
    try testing.expectEqual(@as(i64, 2), as_b.getValueB());
}

test "castTo refuses a class the object is not" {
    const a = try ClassA.create();
    defer Object.upcast(a).destroy();

    // A plain ClassA is not a ClassC. Nothing on the engine side can answer
    // this -- the instance binding takes one token per object, ClassDB has no
    // tag for an extension class, and the object's reported class is `Object`
    // -- so gdzig records what the instance is and checks against that.
    try testing.expect(gdzig.class.castTo(ClassC, a) == null);

    // Starker: a class sharing no ancestry with ClassA at all.
    try testing.expect(gdzig.class.castTo(Unrelated, a) == null);

    // And the cast that should succeed still does.
    const same = gdzig.class.castTo(ClassA, a) orelse return error.CastFailed;
    try testing.expectEqual(@as(i64, 1), same.getValueA());
}

test "a displaced base is not the instance address" {
    ensureRegistered();

    // `VDisplaced` inherits `_ready` from `VParent`, so gdzig builds a vtable
    // wrapper with `Owner = VParent` while Godot hands it a `*VDisplaced`. The
    // wrapper has to narrow, and this is why it cannot just reinterpret:
    // Zig orders fields by descending alignment, so the `u128` sorts ahead of
    // the embedded parent and the base is not at byte 0.
    try testing.expect(@offsetOf(VDisplaced, "base") != 0);

    const d = try VDisplaced.create();
    defer Object.upcast(d).destroy();

    const narrowed = @intFromPtr(gdzig.class.upcast(*VParent, d));
    try testing.expect(narrowed != @intFromPtr(d));
    try testing.expectEqual(@intFromPtr(d) + @offsetOf(VDisplaced, "base"), narrowed);

    // Go through Godot's virtual dispatch, which retains gdzig's cached call
    // data. The inherited wrapper must still narrow the most-derived instance
    // to the displaced owner before invoking `_ready`.
    d.base.base.notification(Node.NOTIFICATION_READY, .{});
    try testing.expectEqual(narrowed, d.base.ready_self);
}
