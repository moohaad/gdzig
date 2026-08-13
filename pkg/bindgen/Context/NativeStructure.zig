//! A Godot "native structure": a plain C struct passed across the FFI by
//! pointer, described in `extension_api.json` only as a C declaration string.
//!
//! ```json
//! { "name": "AudioFrame", "format": "float left;float right" }
//! ```
//!
//! These are not classes and have no methods; the engine reads and writes them
//! directly, so the Zig side must be an `extern struct` with a matching layout.
//! They appear exclusively in virtual methods that an extension implements --
//! `AudioStreamPlayback._mix`, the physics-server extension points -- so
//! without them those virtuals cannot be written at all.

const NativeStructure = @This();

name: []const u8 = "_",
name_api: []const u8 = "_",
fields: ArrayList(Field) = .empty,

pub const Field = struct {
    name: []const u8,
    /// Rendered Zig type, including any pointer or array wrapper.
    type: []const u8,
    /// Zig expression for the default, when the C declaration carries one.
    default: ?[]const u8 = null,
};

/// C spellings with a fixed Zig equivalent. Anything not listed is either a
/// Godot builtin, another native structure, or a class, and is resolved by
/// name.
const scalar_types = std.StaticStringMap([]const u8).initComptime(.{
    .{ "void", "void" },
    .{ "bool", "bool" },
    .{ "float", "f32" },
    .{ "double", "f64" },
    .{ "int", "i32" },
    .{ "int8_t", "i8" },
    .{ "int16_t", "i16" },
    .{ "int32_t", "i32" },
    .{ "int64_t", "i64" },
    .{ "uint8_t", "u8" },
    .{ "uint16_t", "u16" },
    .{ "uint32_t", "u32" },
    .{ "uint64_t", "u64" },
    // Godot's configurable float width. The generated bindings are already
    // per-precision, so this resolves at generation time like everything else.
    .{ "real_t", if (std.mem.eql(u8, build_options.precision, "double")) "f64" else "f32" },
});

pub fn fromApi(allocator: Allocator, api: GodotApi.NativeStructure, ctx: *const Context) !NativeStructure {
    var self: NativeStructure = .{};
    errdefer self.deinit(allocator);

    self.name = try casez.allocConvert(allocator, gdzig_case.type, api.name);
    self.name_api = try allocator.dupe(u8, api.name);

    var decls = std.mem.splitScalar(u8, api.format, ';');
    while (decls.next()) |raw| {
        const decl = std.mem.trim(u8, raw, " \t");
        if (decl.len == 0) continue;
        try self.fields.append(allocator, try parseField(allocator, decl, ctx));
    }

    return self;
}

/// Parses one `<type> <name>[<count>] = <default>` declaration.
fn parseField(allocator: Allocator, decl: []const u8, ctx: *const Context) !Field {
    var rest = decl;
    var default: ?[]const u8 = null;

    if (std.mem.indexOfScalar(u8, rest, '=')) |eq| {
        const raw_default = std.mem.trim(u8, rest[eq + 1 ..], " \t");
        rest = std.mem.trim(u8, rest[0..eq], " \t");
        default = try translateDefault(allocator, raw_default);
    }

    // A trailing `[N]` makes the field an array of the declared type.
    var array_len: ?[]const u8 = null;
    if (std.mem.indexOfScalar(u8, rest, '[')) |open| {
        const close = std.mem.indexOfScalar(u8, rest, ']') orelse return error.MalformedNativeStructure;
        array_len = try allocator.dupe(u8, std.mem.trim(u8, rest[open + 1 .. close], " \t"));
        rest = std.mem.trim(u8, rest[0..open], " \t");
    }

    // The name is the last whitespace-separated word; a `*` may cling to either
    // side of the gap, as in `Object *collider`.
    const split = std.mem.lastIndexOfAny(u8, rest, " \t*") orelse return error.MalformedNativeStructure;
    const field_name = std.mem.trim(u8, rest[split + 1 ..], " \t");
    const type_part = std.mem.trim(u8, rest[0 .. split + 1], " \t");

    const is_pointer = std.mem.indexOfScalar(u8, type_part, '*') != null;
    const bare_type = std.mem.trim(u8, std.mem.trimEnd(u8, type_part, "* \t"), " \t");

    var rendered = try renderType(allocator, bare_type, ctx);
    if (is_pointer) {
        // Engine-owned pointers are nullable; there is no annotation in the
        // format string saying otherwise.
        rendered = try std.fmt.allocPrint(allocator, "?*{s}", .{rendered});
    }
    if (array_len) |len| {
        rendered = try std.fmt.allocPrint(allocator, "[{s}]{s}", .{ len, rendered });
    }

    return .{
        .name = try allocator.dupe(u8, field_name),
        .type = rendered,
        .default = default,
    };
}

fn renderType(allocator: Allocator, bare: []const u8, ctx: *const Context) ![]const u8 {
    if (scalar_types.get(bare)) |zig| return try allocator.dupe(u8, zig);

    // `TextServer::Direction` names an enum scoped to a class.
    if (std.mem.indexOf(u8, bare, "::")) |sep| {
        const owner = bare[0..sep];
        const member = bare[sep + 2 ..];
        const owner_name = if (ctx.classes.get(owner)) |c| c.name else owner;
        const member_name = blk: {
            if (ctx.classes.get(owner)) |c| {
                if (c.enums.get(member)) |e| break :blk e.name;
                if (c.flags.get(member)) |f| break :blk f.name;
            }
            break :blk member;
        };
        return try std.fmt.allocPrint(allocator, "{s}.{s}", .{ owner_name, member_name });
    }

    // Otherwise a builtin, a class, or another native structure. All three are
    // spelled in Zig type case.
    return try casez.allocConvert(allocator, gdzig_case.type, bare);
}

/// C literals to Zig. Only the forms Godot actually emits are handled; anything
/// else is passed through, which surfaces as a compile error rather than a
/// silently wrong value.
fn translateDefault(allocator: Allocator, raw: []const u8) ![]const u8 {
    // `0.f` and `1.0f` are C float literals; Zig wants `0.0`.
    if (std.mem.endsWith(u8, raw, "f") and std.mem.indexOfScalar(u8, raw, '.') != null) {
        const trimmed = std.mem.trimEnd(u8, raw[0 .. raw.len - 1], ".");
        return try std.fmt.allocPrint(allocator, "{s}.0", .{trimmed});
    }
    return try allocator.dupe(u8, raw);
}

pub fn deinit(self: *NativeStructure, allocator: Allocator) void {
    allocator.free(self.name);
    allocator.free(self.name_api);
    for (self.fields.items) |field| {
        allocator.free(field.name);
        allocator.free(field.type);
        if (field.default) |d| allocator.free(d);
    }
    self.fields.deinit(allocator);
    self.* = .{};
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const build_options = @import("build_options");

const casez = @import("casez");
const common = @import("common");
const gdzig_case = common.gdzig_case;

const Context = @import("../Context.zig");
const GodotApi = @import("../GodotApi.zig");
