//! What `autoRegister` binds — and, as much to the point, what it binds only
//! once.
//!
//! `autoBind` can reach the same property three ways: every Variant-typed
//! field, the `properties` tuple, and each `groups` entry's list. A field named
//! in the tuple or in a group is reachable by two of them at once. Godot
//! refuses the second registration, and the options the tuple existed to carry
//! go with it -- silently, because the refusal is an engine-side error rather
//! than a Zig one.
//!
//! So `set_read_only` existing is the assertion that matters most here: it
//! would mean `.setter = .none` was accepted by the compiler and then dropped
//! on the floor.

pub fn register(r: *gdzig.extension.Registry) void {
    r.autoRegister(AutoBindNode);
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

const AutoBindNode = struct {
    base: *Object,

    /// Bound because it is a field, and nothing names it anywhere else.
    plain_value: i64 = 42,

    /// A field *and* a `properties` entry, so the two loops both reach it.
    read_only: i64 = 7,

    /// A field *and* a `groups` member, likewise.
    grouped_value: i64 = 3,

    /// Underscored, which is how a field stays out of the inspector.
    _internal: i64 = 99,

    /// Has a `getComputed` beside it, which is what a property getter written
    /// by hand looks like. The default is deliberately not what the getter
    /// returns, so a test can tell which of the two was used.
    computed: i64 = 3,

    /// Only what needs options. A bare name here would say nothing that the
    /// field does not already say.
    pub const properties = .{
        .{ "read_only", .{ .setter = .none } },
    };

    pub const groups = .{
        .{ "Grouped", .{}, .{"grouped_value"} },
    };

    /// Named like `read_only`'s setter, and `read_only` is declared
    /// `.setter = .none`. Binding this as an ordinary method would put a
    /// `set_read_only` on the class anyway, so the option would say one thing
    /// and the class surface another.
    pub fn setReadOnly(self: *AutoBindNode, value: i64) void {
        self.read_only = value;
    }

    /// The getter for `computed`, not a method in its own right.
    pub fn getComputed(_: *AutoBindNode) i64 {
        return 99;
    }

    /// Hand-written, like the other suites': gdzig would synthesise one, but a
    /// test needs to reach it by name. `autoBind` ignores it either way.
    pub fn create() !*AutoBindNode {
        const self = try allocator.create(AutoBindNode);
        self.* = .{ .base = Object.init() };
        self.base.setInstance(AutoBindNode, self);
        return self;
    }

    pub fn destroy(self: *AutoBindNode) void {
        self.base.destroy();
        allocator.destroy(self);
    }

    /// Bound as `double_it`.
    pub fn doubleIt(self: *AutoBindNode) i64 {
        return self.plain_value * 2;
    }

    /// Underscored: a class callback, wired by the class machinery rather than
    /// bound as a ClassDB method.
    pub fn _notification(_: *AutoBindNode, _: i32, _: bool) void {}
};

test "a plain field binds with both accessors" {
    ensureRegistered();

    try testing.expect(hasMethod("get_plain_value"));
    try testing.expect(hasMethod("set_plain_value"));
}

test "a field named in `properties` keeps the tuple's options" {
    ensureRegistered();

    // The regression this file exists for. A setter here means `read_only` was
    // bound twice and `.setter = .none` was discarded.
    try testing.expect(hasMethod("get_read_only"));
    try testing.expect(!hasMethod("set_read_only"));
}

test "a field named in a group is still bound, and once" {
    ensureRegistered();

    try testing.expect(hasMethod("get_grouped_value"));
    try testing.expectEqual(@as(usize, 1), countProperty("grouped_value"));
}

test "no property is registered twice" {
    ensureRegistered();

    inline for ([_][:0]const u8{ "plain_value", "read_only", "grouped_value" }) |name| {
        try testing.expectEqual(@as(usize, 1), countProperty(name));
    }
}

test "underscored fields are left alone" {
    ensureRegistered();

    try testing.expectEqual(@as(usize, 0), countProperty("_internal"));
    try testing.expect(!hasMethod("get__internal"));
    try testing.expect(!hasMethod("set__internal"));
}

test "a method binds under its snake_case name" {
    ensureRegistered();

    try testing.expect(hasMethod("double_it"));
}

test "class callbacks are not bound as methods" {
    ensureRegistered();

    try testing.expect(!hasMethod("_notification"));
}

/// `no_inheritance` throughout: `Object` brings plenty of its own, and this is
/// asking what *this* class declared.
fn hasMethod(comptime name: [:0]const u8) bool {
    return ClassDb.classHasMethod("AutoBindNode", name, .{ .no_inheritance = true });
}

/// How many entries in the class's own property list carry `name`. One is
/// correct; zero means it was never bound; more than one would mean Godot
/// accepted a duplicate.
fn countProperty(comptime name: [:0]const u8) usize {
    var list = ClassDb.classGetPropertyList("AutoBindNode", .{ .no_inheritance = true });
    defer list.deinit();

    var count: usize = 0;
    var i: i64 = 0;
    while (i < list.size()) : (i += 1) {
        var entry = list.get(i);
        defer entry.deinit();

        var dict = entry.as(Dictionary) orelse continue;
        defer dict.deinit();

        var key: String = .fromLatin1("name");
        defer key.deinit();
        var value = dict.get(.init(String, key), .{});
        defer value.deinit();

        var found = value.as(String) orelse continue;
        defer found.deinit();

        var buf: [128]u8 = undefined;
        if (std.mem.eql(u8, found.toLatin1Buf(buf[0..]), name)) count += 1;
    }
    return count;
}

const std = @import("std");
const testing = std.testing;

const gdzig = @import("gdzig");
const allocator = gdzig.testing.allocator;
const ClassDb = gdzig.class.ClassDb;
const Object = gdzig.class.Object;
const Dictionary = gdzig.builtin.Dictionary;
const StringName = gdzig.builtin.StringName;
const String = gdzig.builtin.String;

test "a `getX` decl beside a field becomes that property's getter, not a second method" {
    ensureRegistered();

    // Bound once. Before this was handled, the method loop registered
    // `get_computed` and the property registered it again, Godot refused the
    // second, and which one survived was down to ordering.
    try testing.expect(hasMethod("get_computed"));
    try testing.expectEqual(@as(usize, 1), countProperty("computed"));

    // And the decl is what runs: reading the property gives the getter's 99
    // rather than the field's 3.
    const node = try AutoBindNode.create();
    defer node.destroy();

    const value = Object.upcast(node).get(StringName.fromComptimeLatin1("computed").*);
    try testing.expectEqual(@as(i64, 99), value.as(i64).?);
}
