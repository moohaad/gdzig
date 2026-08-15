pub fn register(r: *gdzig.extension.Registry) void {
    const class = r.createClass(PropertyNode, {}, .auto);

    // Field-based property with auto-detected getter/setter
    class.addProperty("field_value", .auto);

    // Read-only property (getter only, no setter)
    class.addProperty("read_only", .{ .setter = .none });

    // Property with explicit getter/setter methods
    const get_custom = class.createMethod("get_custom", .auto);
    const set_custom = class.createMethod("set_custom", .auto);
    class.addProperty("custom", .{
        .getter = .{ .method = get_custom },
        .setter = .{ .method = set_custom },
    });

    // The `@export_*` constructors. Registered so the hints can be read back
    // from the engine below, which is the only way to tell that the hint string
    // was in the format Godot expects rather than merely well-typed.
    class.addProperty("ranged", .range(0, 100, 1, ""));
    class.addProperty("ranged_extra", .range(0, 10, 0.5, "or_greater"));
    class.addProperty("choice", .enumOf(&.{ "Low", "High:5" }));
    class.addProperty("bits", .flags(&.{ "Fire:1", "Ice:2" }));
    class.addProperty("texture_path", .file("*.png"));
    class.addProperty("note", .multiline());
    class.addProperty("hidden", .storage());
    class.addProperty("mask", .layers(.physics_2d));

    // Property groups
    const stats = class.createGroup("Stats", .{ .prefix = "stat_" });
    stats.addProperty("health", .auto);
    stats.addProperty("mana", .auto);

    // Property subgroups
    const combat = stats.createSubgroup("Combat", .{});
    combat.addProperty("armor", .auto);
    combat.addProperty("damage", .auto);

    // Indexed properties - shared getter/setter with index parameter (requires Godot 4.2+)
    if (gdzig.version.gte(.@"4.2")) {
        const get_slot = class.createMethod("get_inventory_slot", .auto);
        const set_slot = class.createMethod("set_inventory_slot", .auto);
        class.addProperty("slot_0", .{ .getter = .{ .method = get_slot }, .setter = .{ .method = set_slot }, .index = 0 });
        class.addProperty("slot_1", .{ .getter = .{ .method = get_slot }, .setter = .{ .method = set_slot }, .index = 1 });
        class.addProperty("slot_2", .{ .getter = .{ .method = get_slot }, .setter = .{ .method = set_slot }, .index = 2 });
    }
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

test "field-based property" {
    ensureRegistered();

    const node = try PropertyNode.create();
    defer node.destroy();

    const obj = Object.upcast(node);

    var result = obj.get(StringName.fromComptimeLatin1("field_value").*);
    try testing.expectEqual(@as(i64, 42), result.as(i64).?);

    obj.set(StringName.fromComptimeLatin1("field_value").*, .init(i64, 100));
    result = obj.get(StringName.fromComptimeLatin1("field_value").*);
    try testing.expectEqual(@as(i64, 100), result.as(i64).?);
}

test "read-only property" {
    ensureRegistered();

    const node = try PropertyNode.create();
    defer node.destroy();

    const obj = Object.upcast(node);

    const result = obj.get(StringName.fromComptimeLatin1("read_only").*);
    try testing.expectEqual(@as(i64, 999), result.as(i64).?);
}

test "explicit getter/setter property" {
    ensureRegistered();

    const node = try PropertyNode.create();
    defer node.destroy();

    const obj = Object.upcast(node);

    var result = obj.get(StringName.fromComptimeLatin1("custom").*);
    try testing.expectEqual(@as(i64, 0), result.as(i64).?);

    obj.set(StringName.fromComptimeLatin1("custom").*, .init(i64, 555));
    result = obj.get(StringName.fromComptimeLatin1("custom").*);
    try testing.expectEqual(@as(i64, 555), result.as(i64).?);
}

test "grouped properties" {
    ensureRegistered();

    const node = try PropertyNode.create();
    defer node.destroy();

    const obj = Object.upcast(node);

    var result = obj.get(StringName.fromComptimeLatin1("health").*);
    try testing.expectEqual(@as(i64, 100), result.as(i64).?);

    result = obj.get(StringName.fromComptimeLatin1("mana").*);
    try testing.expectEqual(@as(i64, 50), result.as(i64).?);
}

test "subgrouped properties" {
    ensureRegistered();

    const node = try PropertyNode.create();
    defer node.destroy();

    const obj = Object.upcast(node);

    var result = obj.get(StringName.fromComptimeLatin1("armor").*);
    try testing.expectEqual(@as(i64, 10), result.as(i64).?);

    result = obj.get(StringName.fromComptimeLatin1("damage").*);
    try testing.expectEqual(@as(i64, 25), result.as(i64).?);
}

test "indexed properties" {
    ensureRegistered();

    // Indexed properties require Godot 4.2+
    if (!gdzig.version.gte(.@"4.2")) return;

    const node = try PropertyNode.create();
    defer node.destroy();

    const obj = Object.upcast(node);

    // Check initial values
    var result = obj.get(StringName.fromComptimeLatin1("slot_0").*);
    try testing.expectEqual(@as(i64, 100), result.as(i64).?);

    result = obj.get(StringName.fromComptimeLatin1("slot_1").*);
    try testing.expectEqual(@as(i64, 200), result.as(i64).?);

    result = obj.get(StringName.fromComptimeLatin1("slot_2").*);
    try testing.expectEqual(@as(i64, 300), result.as(i64).?);

    // Modify via indexed property
    obj.set(StringName.fromComptimeLatin1("slot_1").*, .init(i64, 999));
    result = obj.get(StringName.fromComptimeLatin1("slot_1").*);
    try testing.expectEqual(@as(i64, 999), result.as(i64).?);

    // Verify other slots unchanged
    result = obj.get(StringName.fromComptimeLatin1("slot_0").*);
    try testing.expectEqual(@as(i64, 100), result.as(i64).?);

    result = obj.get(StringName.fromComptimeLatin1("slot_2").*);
    try testing.expectEqual(@as(i64, 300), result.as(i64).?);
}

/// What Godot reports for one registered property.
///
/// Named rather than anonymous: each mention of an anonymous struct is a
/// distinct type, so a `?struct { ... }` return never unifies with itself. The
/// hint string is kept as a buffer plus a length rather than a slice, because a
/// slice into `buf` would point at the local copy once this is returned by
/// value.
const HintInfo = struct {
    hint: i64,
    usage: i64,
    buf: [64]u8 = undefined,
    len: usize = 0,

    fn string(self: *const HintInfo) []const u8 {
        return self.buf[0..self.len];
    }
};

/// Reads a property's entry back out of Godot's own property list. Asserting on
/// `CreateOptions` would only prove the struct was filled in; this proves the
/// engine took the hint and kept the string verbatim.
fn hintOf(obj: *PropertyNode, comptime prop: [:0]const u8) ?HintInfo {
    var list = obj.base.getPropertyList();
    defer list.deinit();

    var i: i64 = 0;
    while (i < list.size()) : (i += 1) {
        var entry = list.get(i);
        defer entry.deinit();

        var dict = entry.as(Dictionary) orelse continue;
        defer dict.deinit();

        var name_str = lookupString(&dict, "name") orelse continue;
        defer name_str.deinit();
        var name_buf: [64]u8 = undefined;
        if (!std.mem.eql(u8, name_str.toLatin1Buf(name_buf[0..]), prop)) continue;

        var out: HintInfo = .{
            .hint = lookupInt(&dict, "hint"),
            .usage = lookupInt(&dict, "usage"),
        };
        if (lookupString(&dict, "hint_string")) |*hs| {
            var mutable = hs.*;
            defer mutable.deinit();
            out.len = mutable.toLatin1Buf(out.buf[0..]).len;
        }
        return out;
    }
    return null;
}

fn lookupString(dict: *Dictionary, comptime key: [:0]const u8) ?String {
    var k: String = .fromLatin1(key);
    defer k.deinit();
    var v = dict.get(.init(String, k), .{});
    defer v.deinit();
    return v.as(String);
}

fn lookupInt(dict: *Dictionary, comptime key: [:0]const u8) i64 {
    var k: String = .fromLatin1(key);
    defer k.deinit();
    var v = dict.get(.init(String, k), .{});
    defer v.deinit();
    return v.as(i64) orelse 0;
}

test "the export constructors reach Godot with the hint string intact" {
    ensureRegistered();

    const obj = try PropertyNode.create();
    defer obj.destroy();

    const range = hintOf(obj, "ranged") orelse return error.PropertyMissing;
    try testing.expectEqual(@as(i64, @intFromEnum(gdzig.global.PropertyHint.property_hint_range)), range.hint);
    try testing.expectEqualStrings("0,100,1", range.string());

    // The modifier is appended after the numbers, which is where Godot looks.
    const extra = hintOf(obj, "ranged_extra") orelse return error.PropertyMissing;
    try testing.expectEqualStrings("0,10,0.5,or_greater", extra.string());

    const choice = hintOf(obj, "choice") orelse return error.PropertyMissing;
    try testing.expectEqual(@as(i64, @intFromEnum(gdzig.global.PropertyHint.property_hint_enum)), choice.hint);
    try testing.expectEqualStrings("Low,High:5", choice.string());

    const bits = hintOf(obj, "bits") orelse return error.PropertyMissing;
    try testing.expectEqualStrings("Fire:1,Ice:2", bits.string());

    const file = hintOf(obj, "texture_path") orelse return error.PropertyMissing;
    try testing.expectEqualStrings("*.png", file.string());

    // Hint-free constructors: the hint carries the meaning, not the string.
    const note = hintOf(obj, "note") orelse return error.PropertyMissing;
    try testing.expectEqual(@as(i64, @intFromEnum(gdzig.global.PropertyHint.property_hint_multiline_text)), note.hint);
    try testing.expectEqualStrings("", note.string());

    const mask = hintOf(obj, "mask") orelse return error.PropertyMissing;
    try testing.expectEqual(@as(i64, @intFromEnum(gdzig.global.PropertyHint.property_hint_layers_2d_physics)), mask.hint);

    // `storage` is a usage change, so it must NOT carry the editor bit.
    const hidden = hintOf(obj, "hidden") orelse return error.PropertyMissing;
    try testing.expectEqual(@as(i64, 2), hidden.usage);
}

test "a group's prefix reaches the inspector" {
    ensureRegistered();

    const obj = try PropertyNode.create();
    defer obj.destroy();

    // Godot lists a group as an entry of its own, carrying the prefix in the
    // hint string. Reading it back is the only way to tell the prefix was
    // passed rather than dropped -- it was hardcoded empty until now.
    const group = hintOf(obj, "Stats") orelse return error.GroupMissing;
    try testing.expectEqualStrings("stat_", group.string());

    const subgroup = hintOf(obj, "Combat") orelse return error.SubgroupMissing;
    try testing.expectEqualStrings("", subgroup.string());
}

const PropertyNode = struct {
    base: *Object,

    // Field-based property
    field_value: i64 = 42,

    // Read-only property
    read_only: i64 = 999,

    // Backing for the `@export_*` constructors.
    ranged: i64 = 0,
    ranged_extra: f64 = 0,
    choice: i64 = 0,
    bits: i64 = 0,
    texture_path: i64 = 0,
    note: i64 = 0,
    hidden: i64 = 0,
    mask: i64 = 0,

    // Custom getter/setter backing storage
    custom_backing: i64 = 0,

    // Grouped properties
    health: i64 = 100,
    mana: i64 = 50,

    // Subgrouped properties
    armor: i64 = 10,
    damage: i64 = 25,

    // Indexed property backing storage
    inventory: [3]i64 = .{ 100, 200, 300 },

    pub fn create() !*PropertyNode {
        const self = try allocator.create(PropertyNode);
        self.* = .{ .base = Object.init() };
        self.base.setInstance(PropertyNode, self);
        return self;
    }

    pub fn destroy(self: *PropertyNode) void {
        self.base.destroy();
        allocator.destroy(self);
    }

    // Custom property getter/setter
    pub fn getCustom(self: *const PropertyNode) i64 {
        return self.custom_backing;
    }

    pub fn setCustom(self: *PropertyNode, value: i64) void {
        self.custom_backing = value;
    }

    // Indexed property getter/setter
    pub fn getInventorySlot(self: *const PropertyNode, index: i64) i64 {
        if (index >= 0 and index < 3) {
            return self.inventory[@intCast(index)];
        }
        return 0;
    }

    pub fn setInventorySlot(self: *PropertyNode, index: i64, value: i64) void {
        if (index >= 0 and index < 3) {
            self.inventory[@intCast(index)] = value;
        }
    }
};

const std = @import("std");
const testing = std.testing;

const gdzig = @import("gdzig");
const allocator = gdzig.testing.allocator;
const Object = gdzig.class.Object;
const StringName = gdzig.builtin.StringName;
const String = gdzig.builtin.String;
const Dictionary = gdzig.builtin.Dictionary;
