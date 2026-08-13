//! Structural diff of two `extension_api.json` dumps.
//!
//! Rather than comparing values, this profiles the *shape*: for every
//! `section.field` reachable from the top-level arrays, it records the set of
//! value kinds seen across all occurrences, then reports where the two dumps
//! disagree. That is what catches a field changing from string to number, or
//! appearing for the first time.
//!
//! Two mistakes cost real time when this was done by hand, and both are
//! guarded against here:
//!
//!   * Lists must distinguish their element kind. Recording every array as
//!     "list" makes a field that changed from list-of-string to list-of-object
//!     read as unchanged.
//!   * The inputs must actually be different versions, dumped with the same
//!     flags. A dump compared against itself reports no differences and looks
//!     like a clean result; `--dump-extension-api` against
//!     `--dump-extension-api-with-docs` reports every `description` as removed.
//!     Both are checked before diffing.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Json = std.json.Value;

/// The kinds a JSON value can take, with arrays carrying their element kind.
const Kind = enum {
    null,
    bool,
    number,
    string,
    object,
    list_empty,
    list_of_bool,
    list_of_number,
    list_of_string,
    list_of_object,
    list_of_list,

    fn of(value: Json) Kind {
        return switch (value) {
            .null => .null,
            .bool => .bool,
            .integer, .float, .number_string => .number,
            .string => .string,
            .object => .object,
            .array => |items| {
                if (items.items.len == 0) return .list_empty;
                return switch (items.items[0]) {
                    .bool => .list_of_bool,
                    .integer, .float, .number_string => .list_of_number,
                    .string => .list_of_string,
                    .object => .list_of_object,
                    .array => .list_of_list,
                    .null => .list_empty,
                };
            },
        };
    }
};

const KindSet = std.EnumSet(Kind);

/// `section.field` -> every kind that field was seen holding.
const Profile = std.StringArrayHashMapUnmanaged(KindSet);

pub fn run(arena: Allocator, io: Io, out: *Io.Writer, old_path: []const u8, new_path: []const u8) !void {
    const main = @import("main.zig");

    const old_doc = try std.json.parseFromSlice(Json, arena, try main.readFile(arena, io, old_path), .{});
    const new_doc = try std.json.parseFromSlice(Json, arena, try main.readFile(arena, io, new_path), .{});

    const old_id = try identify(arena, old_doc.value);
    const new_id = try identify(arena, new_doc.value);

    try out.print("old: {s}  ({s})\n", .{ old_id.version, if (old_id.has_docs) "with docs" else "no docs" });
    try out.print("new: {s}  ({s})\n\n", .{ new_id.version, if (new_id.has_docs) "with docs" else "no docs" });

    // Both guards exist because both mistakes were actually made.
    if (std.mem.eql(u8, old_id.version, new_id.version)) {
        try out.writeAll("refusing to diff: both inputs are the same version.\n");
        return error.SameVersion;
    }
    if (old_id.has_docs != new_id.has_docs) {
        try out.writeAll(
            \\refusing to diff: the dumps were taken with different flags, so every
            \\`description` field would show up as added or removed. Re-dump both with
            \\(or both without) --dump-extension-api-with-docs.
            \\
        );
        return error.MismatchedDumpFlags;
    }

    var old_profile: Profile = .empty;
    var new_profile: Profile = .empty;
    try profile(arena, old_doc.value, &old_profile);
    try profile(arena, new_doc.value, &new_profile);

    var keys: std.StringArrayHashMapUnmanaged(void) = .empty;
    for (old_profile.keys()) |k| try keys.put(arena, k, {});
    for (new_profile.keys()) |k| try keys.put(arena, k, {});

    const sorted = keys.keys();
    std.mem.sort([]const u8, sorted, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    var differences: usize = 0;
    for (sorted) |key| {
        const in_old = old_profile.get(key);
        const in_new = new_profile.get(key);
        if (in_old != null and in_new != null and in_old.?.eql(in_new.?)) continue;

        differences += 1;
        try out.print("{s}:\n    old = {f}\n    new = {f}\n", .{
            key,
            KindSetFmt{ .set = in_old },
            KindSetFmt{ .set = in_new },
        });
    }

    if (differences == 0) {
        try out.writeAll("no shape differences.\n");
    } else {
        try out.print("\n{d} field(s) differ.\n", .{differences});
    }
}

const Identity = struct {
    version: []const u8,
    has_docs: bool,
};

fn identify(arena: Allocator, doc: Json) !Identity {
    _ = arena;
    const header = doc.object.get("header") orelse return error.MissingHeader;
    const version = header.object.get("version_full_name") orelse return error.MissingVersion;

    // Docs are only present when dumped with --dump-extension-api-with-docs.
    // Any class description will do to tell the two apart.
    var has_docs = false;
    if (doc.object.get("classes")) |classes| {
        for (classes.array.items) |class| {
            if (class.object.get("description") != null or class.object.get("brief_description") != null) {
                has_docs = true;
                break;
            }
        }
    }

    return .{ .version = version.string, .has_docs = has_docs };
}

/// Walks every top-level array, recording the kinds each field takes. Nested
/// arrays of objects are walked too, under a dotted path.
fn profile(arena: Allocator, doc: Json, out: *Profile) !void {
    var it = doc.object.iterator();
    while (it.next()) |entry| {
        switch (entry.value_ptr.*) {
            .array => |items| try profileObjects(arena, entry.key_ptr.*, items.items, out),
            .object => |obj| {
                var fields = obj.iterator();
                while (fields.next()) |field| {
                    try record(arena, out, entry.key_ptr.*, field.key_ptr.*, field.value_ptr.*);
                }
            },
            else => {},
        }
    }
}

fn profileObjects(arena: Allocator, prefix: []const u8, items: []const Json, out: *Profile) !void {
    for (items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        var fields = obj.iterator();
        while (fields.next()) |field| {
            try record(arena, out, prefix, field.key_ptr.*, field.value_ptr.*);

            if (field.value_ptr.* == .array) {
                const nested = field.value_ptr.array.items;
                const has_objects = for (nested) |n| {
                    if (n == .object) break true;
                } else false;
                if (has_objects) {
                    const key = try std.fmt.allocPrint(arena, "{s}.{s}", .{ prefix, field.key_ptr.* });
                    try profileObjects(arena, key, nested, out);
                }
            }
        }
    }
}

fn record(arena: Allocator, out: *Profile, prefix: []const u8, field: []const u8, value: Json) !void {
    const key = try std.fmt.allocPrint(arena, "{s}.{s}", .{ prefix, field });
    const gop = try out.getOrPut(arena, key);
    if (!gop.found_existing) gop.value_ptr.* = .initEmpty();
    gop.value_ptr.insert(Kind.of(value));
}

const KindSetFmt = struct {
    set: ?KindSet,

    pub fn format(self: KindSetFmt, w: *Io.Writer) Io.Writer.Error!void {
        const set = self.set orelse return w.writeAll("<absent>");
        var first = true;
        var it = set.iterator();
        while (it.next()) |kind| {
            if (!first) try w.writeAll(", ");
            first = false;
            try w.writeAll(@tagName(kind));
        }
        if (first) try w.writeAll("<none>");
    }
};
