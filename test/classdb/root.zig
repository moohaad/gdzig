pub fn register(r: *gdzig.extension.Registry) void {
    const class = r.createClass(TestNode, {}, .auto);
    class.addMethod("increment", .auto);
    class.addMethod("get_counter", .auto);
    class.addMethod("add_value", .auto);
    class.addMethod("get_my_property", .auto);
    class.addMethod("set_my_property", .auto);
    class.addMethod("get_indexed_value", .auto);
    class.addMethod("set_indexed_value", .auto);
    class.addMethod("take_optional_node", .auto);

    registerWide(r);
}

/// As wide, as deeply derived, and as virtual-heavy as a real game entity.
///
/// Registering it spends the default comptime branch quota, and all three
/// traits are needed to get there -- dropping any one of them puts it back
/// under the ceiling. Width alone on a class extending `Object` directly does
/// not reach it, and neither does width plus depth without the `_`-prefixed
/// virtuals, which are the only decls compared against every callback name.
///
/// Never instantiated: the point is that registering it compiles.
const WideNode = struct {
    base: *CharacterBody2d,

    p00: i64 = 0,
    p01: i64 = 1,
    p02: i64 = 2,
    p03: i64 = 3,
    p04: i64 = 4,
    p05: i64 = 5,
    p06: i64 = 6,
    p07: i64 = 7,
    p08: i64 = 8,
    p09: i64 = 9,
    p10: i64 = 10,
    p11: i64 = 11,
    p12: i64 = 12,
    p13: i64 = 13,
    p14: i64 = 14,

    pub const S0 = struct { a: i64 };
    pub const S1 = struct { b: f64 };
    pub const S2 = struct {};
    pub const S3 = struct { c: bool };
    pub const S4 = struct { d: i64, e: i64 };

    pub fn create() !*WideNode {
        const self = try allocator.create(WideNode);
        self.* = .{ .base = CharacterBody2d.init() };
        self.base.setInstance(WideNode, self);
        return self;
    }

    pub fn destroy(self: *WideNode) void {
        allocator.destroy(self);
    }

    pub fn _ready(self: *WideNode) void {
        _ = self;
    }

    pub fn _physics_process(self: *WideNode, delta: f64) void {
        self.p00 = @intFromFloat(delta);
    }

    pub fn m00(self: *WideNode) i64 {
        return self.p00;
    }
    pub fn m01(self: *WideNode) i64 {
        return self.p01;
    }
    pub fn m02(self: *WideNode) i64 {
        return self.p02;
    }
    pub fn m03(self: *WideNode) i64 {
        return self.p03;
    }
    pub fn m04(self: *WideNode) i64 {
        return self.p04;
    }
    pub fn m05(self: *WideNode) i64 {
        return self.p05;
    }
    pub fn m06(self: *WideNode) i64 {
        return self.p06;
    }
    pub fn m07(self: *WideNode) i64 {
        return self.p07;
    }
    pub fn m08(self: *WideNode) i64 {
        return self.p08;
    }
    pub fn m09(self: *WideNode) i64 {
        return self.p09;
    }
    pub fn m10(self: *WideNode) i64 {
        return self.p10;
    }
    pub fn m11(self: *WideNode) i64 {
        return self.p11;
    }
    pub fn m12(self: *WideNode) i64 {
        return self.p12;
    }
    pub fn m13(self: *WideNode) i64 {
        return self.p13;
    }
    pub fn m14(self: *WideNode) i64 {
        return self.p14;
    }
    pub fn m15(self: *WideNode) i64 {
        return self.p00;
    }
    pub fn m16(self: *WideNode) i64 {
        return self.p01;
    }
    pub fn m17(self: *WideNode) i64 {
        return self.p02;
    }
};

fn registerWide(r: *gdzig.extension.Registry) void {
    const wide = r.createClass(WideNode, {}, .auto);
    wide.addProperty("p00", .auto);
    wide.addProperty("p01", .auto);
    wide.addProperty("p02", .auto);
    wide.addProperty("p03", .auto);
    wide.addProperty("p04", .auto);
    wide.addProperty("p05", .auto);
    wide.addProperty("p06", .auto);
    wide.addProperty("p07", .auto);
    wide.addProperty("p08", .auto);
    wide.addProperty("p09", .auto);
    wide.addProperty("p10", .auto);
    wide.addProperty("p11", .auto);
    wide.addProperty("p12", .auto);
    wide.addProperty("p13", .auto);
    wide.addProperty("p14", .auto);
    wide.addMethod("m00", .auto);
    wide.addMethod("m01", .auto);
    wide.addMethod("m02", .auto);
    wide.addMethod("m03", .auto);
    wide.addMethod("m04", .auto);
    wide.addMethod("m05", .auto);
    wide.addMethod("m06", .auto);
    wide.addMethod("m07", .auto);
    wide.addMethod("m08", .auto);
    wide.addMethod("m09", .auto);
    wide.addMethod("m10", .auto);
    wide.addMethod("m11", .auto);
    wide.addMethod("m12", .auto);
    wide.addMethod("m13", .auto);
    wide.addMethod("m14", .auto);
    wide.addMethod("m15", .auto);
    wide.addMethod("m16", .auto);
    wide.addMethod("m17", .auto);
    wide.addSignal(WideNode.S0);
    wide.addSignal(WideNode.S1);
    wide.addSignal(WideNode.S2);
    wide.addSignal(WideNode.S3);
    wide.addSignal(WideNode.S4);
}

/// Never called. Taking its address forces the body to be analysed, which
/// instantiates `Weak(WideNode).init` and makes it walk the `base` chain from a
/// struct class down to the engine type at the bottom -- the comptime work that
/// needs the raised quota. Doing it this way needs no instance.
fn weakenWide(node: *WideNode) gdzig.Weak(WideNode) {
    return .init(node);
}

test "a Weak over a deeply derived class compiles" {
    _ = &weakenWide;
}

test "a class with dozens of registered members still compiles" {
    ensureRegistered();

    // That this file compiled is the assertion; checking ClassDB confirms the
    // registration is real rather than merely well-typed.
    try testing.expect(ClassDb.classExists(StringName.fromComptimeLatin1("WideNode").*));
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

test "create custom class and call methods" {
    ensureRegistered();

    const node = try TestNode.create();
    defer node.base.destroy();

    _ = Object.call(.upcast(node), StringName.fromComptimeLatin1("increment").*, .{});

    var result = Object.call(.upcast(node), StringName.fromComptimeLatin1("get_counter").*, .{});
    try testing.expectEqual(@as(i64, 1), result.as(i64).?);

    result = Object.call(.upcast(node), StringName.fromComptimeLatin1("add_value").*, .{@as(i64, 10)});
    try testing.expectEqual(@as(i64, 11), result.as(i64).?);

    result = Object.call(.upcast(node), StringName.fromComptimeLatin1("get_counter").*, .{});
    try testing.expectEqual(@as(i64, 11), result.as(i64).?);
}

test "custom class properties" {
    ensureRegistered();

    const node = try TestNode.create();
    defer node.base.destroy();

    var result = Object.call(.upcast(node), StringName.fromComptimeLatin1("get_my_property").*, .{});
    try testing.expectEqual(@as(i64, 42), result.as(i64).?);

    _ = Object.call(.upcast(node), StringName.fromComptimeLatin1("set_my_property").*, .{@as(i64, 100)});

    result = Object.call(.upcast(node), StringName.fromComptimeLatin1("get_my_property").*, .{});
    try testing.expectEqual(@as(i64, 100), result.as(i64).?);
}

test "indexed properties" {
    ensureRegistered();

    // Indexed properties require Godot 4.2+
    if (!gdzig.version.gte(.@"4.2")) return;

    const node = try TestNode.create();
    defer node.base.destroy();

    var result = Object.call(.upcast(node), StringName.fromComptimeLatin1("get_indexed_value").*, .{@as(i64, 1)});
    try testing.expectEqual(@as(i64, 200), result.as(i64).?);

    _ = Object.call(.upcast(node), StringName.fromComptimeLatin1("set_indexed_value").*, .{ @as(i64, 1), @as(i64, 999) });

    result = Object.call(.upcast(node), StringName.fromComptimeLatin1("get_indexed_value").*, .{@as(i64, 1)});
    try testing.expectEqual(@as(i64, 999), result.as(i64).?);
}

const TestNode = struct {
    base: *Node,
    counter: i64 = 0,
    my_property: i64 = 42,
    indexed_values: [3]i64 = .{ 100, 200, 300 },

    pub fn create() !*TestNode {
        const self: *TestNode = allocator.create(TestNode) catch @panic("out of memory");
        self.* = .{ .base = Node.init() };
        self.base.setInstance(TestNode, self);
        return self;
    }

    pub fn destroy(self: *TestNode) void {
        allocator.destroy(self);
    }

    pub fn increment(self: *TestNode) void {
        self.counter += 1;
    }

    /// A nullable object parameter, which is ordinary in Godot -- an object
    /// Variant is nullable by nature -- and used to be a compile error to
    /// register.
    pub fn takeOptionalNode(self: *TestNode, node: ?*Node) void {
        self.counter = if (node == null) -1 else 1;
    }

    pub fn getCounter(self: *TestNode) i64 {
        return self.counter;
    }

    pub fn addValue(self: *TestNode, value: i64) i64 {
        self.counter += value;
        return self.counter;
    }

    pub fn getMyProperty(self: *TestNode) i64 {
        return self.my_property;
    }

    pub fn setMyProperty(self: *TestNode, value: i64) void {
        self.my_property = value;
    }

    pub fn getIndexedValue(self: *TestNode, index: i64) i64 {
        if (index >= 0 and index < 3) {
            return self.indexed_values[@intCast(index)];
        }
        return 0;
    }

    pub fn setIndexedValue(self: *TestNode, index: i64, value: i64) void {
        if (index >= 0 and index < 3) {
            self.indexed_values[@intCast(index)] = value;
        }
    }
};

const std = @import("std");
const testing = std.testing;

test "a registered method accepts a nullable object, null included" {
    ensureRegistered();

    const node = try TestNode.create();
    defer node.base.destroy();

    // A real object arrives as itself.
    const other = Node.init();
    defer other.destroy();
    _ = Object.call(.upcast(node), StringName.fromComptimeLatin1("take_optional_node").*, .{other});
    try testing.expectEqual(@as(i64, 1), node.counter);

    // And null arrives as null, rather than being rejected as an unconvertible
    // argument, which is what made this worth fixing.
    var nil: Variant = .nil;
    defer nil.deinit();
    _ = Object.call(.upcast(node), StringName.fromComptimeLatin1("take_optional_node").*, .{nil});
    try testing.expectEqual(@as(i64, -1), node.counter);
}

const gdzig = @import("gdzig");
const allocator = gdzig.testing.allocator;
const CharacterBody2d = gdzig.class.CharacterBody2d;
const ClassDb = gdzig.class.ClassDb;
const Node = gdzig.class.Node;
const Object = gdzig.class.Object;
const StringName = gdzig.builtin.StringName;
const Variant = gdzig.builtin.Variant;
