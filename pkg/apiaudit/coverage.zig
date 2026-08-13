//! Measures how much of the generated surface the tests actually exercise.
//!
//! The compile-only sweep (`-Dsurface-audit`) proves every generated
//! declaration type-checks. It says nothing about whether any of them have ever
//! *run*, and marshalling bugs -- the recurring kind in this codebase -- only
//! show up when a call crosses the FFI boundary for real.
//!
//! This counts what bindgen emits, scans the test sources for what they touch,
//! and reports the gap per category. The numbers are deliberately coarse: a
//! method is "touched" if its Zig name appears as a call in a test, which
//! cannot distinguish two same-named methods on different classes. The output
//! is meant to rank categories for attention, not to be a coverage percentage.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const casez = @import("casez");
const common = @import("common");
const gdzig_case = common.gdzig_case;

const Json = std.json.Value;

const Names = std.StringArrayHashMapUnmanaged(void);

/// How a name is recognised in the test sources.
const Match = enum {
    /// The name appears as a standalone identifier. Used for types, because
    /// Zig's decl literals mean a type is usually named only in the annotation
    /// -- `var a: Array = .init()` never writes `Array.init`. Requiring a call
    /// would report almost every type as untouched.
    ///
    /// This counts an unused import, so treat type numbers as an upper bound.
    identifier,
    /// The name is immediately followed by `(`. Methods are always called as
    /// `.name(` or `Type.name(`, so this is exact apart from two same-named
    /// methods on different types being indistinguishable.
    call,
};

const Category = struct {
    label: []const u8,
    match: Match,
    /// Zig-cased names bindgen emits for this category.
    generated: Names = .empty,
    /// The subset that appears in the test sources.
    touched: Names = .empty,
};

pub fn run(arena: Allocator, io: Io, out: *Io.Writer, api_path: []const u8, test_dirs: []const [:0]const u8) !void {
    const main = @import("main.zig");
    const doc = try std.json.parseFromSlice(Json, arena, try main.readFile(arena, io, api_path), .{});

    var classes: Category = .{ .label = "classes", .match = .identifier };
    var class_methods: Category = .{ .label = "class methods", .match = .call };
    var builtins: Category = .{ .label = "builtins", .match = .identifier };
    var builtin_methods: Category = .{ .label = "builtin methods", .match = .call };
    var utility_fns: Category = .{ .label = "utility functions", .match = .call };

    try collect(arena, doc.value, &classes, &class_methods, &builtins, &builtin_methods, &utility_fns);

    // Concatenate every test source; matching is textual, so one buffer is enough.
    var sources: std.ArrayList(u8) = .empty;
    for (test_dirs) |dir| try appendZigSources(arena, io, dir, &sources);

    if (sources.items.len == 0) {
        try out.writeAll("no .zig sources found in the given directories\n");
        return error.NoSources;
    }

    for ([_]*Category{ &classes, &class_methods, &builtins, &builtin_methods, &utility_fns }) |cat| {
        try markTouched(arena, sources.items, cat);
    }

    try out.print("{s}\n", .{versionOf(doc.value)});
    try out.print("scanned {d} bytes of test source across {d} director{s}\n\n", .{
        sources.items.len,
        test_dirs.len,
        if (test_dirs.len == 1) @as([]const u8, "y") else "ies",
    });

    try out.writeAll("category              touched      total    percent\n");
    try out.writeAll("--------------------------------------------------\n");
    for ([_]*const Category{ &classes, &class_methods, &builtins, &builtin_methods, &utility_fns }) |cat| {
        const total = cat.generated.count();
        const hit = cat.touched.count();
        const pct: f64 = if (total == 0) 0 else @as(f64, @floatFromInt(hit)) * 100.0 / @as(f64, @floatFromInt(total));
        try out.print("{s: <20} {d: >8} {d: >10} {d: >9.1}%\n", .{ cat.label, hit, total, pct });
    }

    for ([_]*const Category{ &classes, &builtins }) |cat| {
        try out.print("\n{s} exercised at all:\n", .{cat.label});
        try listTouched(out, cat, 16);
    }
}

fn collect(
    arena: Allocator,
    doc: Json,
    classes: *Category,
    class_methods: *Category,
    builtins: *Category,
    builtin_methods: *Category,
    utility_fns: *Category,
) !void {
    if (doc.object.get("classes")) |list| {
        for (list.array.items) |class| {
            const api_name = class.object.get("name").?.string;
            try classes.generated.put(arena, try casez.allocConvert(arena, gdzig_case.type, api_name), {});
            if (class.object.get("methods")) |methods| {
                for (methods.array.items) |method| {
                    const name = method.object.get("name").?.string;
                    try class_methods.generated.put(arena, try casez.allocConvert(arena, gdzig_case.func, name), {});
                }
            }
        }
    }

    if (doc.object.get("builtin_classes")) |list| {
        for (list.array.items) |builtin| {
            const api_name = builtin.object.get("name").?.string;
            try builtins.generated.put(arena, try casez.allocConvert(arena, gdzig_case.type, api_name), {});
            if (builtin.object.get("methods")) |methods| {
                for (methods.array.items) |method| {
                    const name = method.object.get("name").?.string;
                    try builtin_methods.generated.put(arena, try casez.allocConvert(arena, gdzig_case.func, name), {});
                }
            }
        }
    }

    if (doc.object.get("utility_functions")) |list| {
        for (list.array.items) |fun| {
            const name = fun.object.get("name").?.string;
            try utility_fns.generated.put(arena, try casez.allocConvert(arena, gdzig_case.func, name), {});
        }
    }
}

/// Marks each generated name that the sources reference, per the category's
/// `Match` rule. Occurrences inside a longer identifier never count, so
/// `String` is not matched by `PackedStringArray`.
fn markTouched(arena: Allocator, sources: []const u8, cat: *Category) !void {
    for (cat.generated.keys()) |name| {
        if (name.len == 0) continue;
        var search: usize = 0;
        while (std.mem.indexOfPos(u8, sources, search, name)) |at| {
            search = at + name.len;

            const before: u8 = if (at == 0) ' ' else sources[at - 1];
            if (std.ascii.isAlphanumeric(before) or before == '_') continue;

            const after: u8 = if (search >= sources.len) ' ' else sources[search];
            if (std.ascii.isAlphanumeric(after) or after == '_') continue;

            const matched = switch (cat.match) {
                .identifier => true,
                .call => after == '(',
            };
            if (matched) {
                try cat.touched.put(arena, name, {});
                break;
            }
        }
    }
}

fn appendZigSources(arena: Allocator, io: Io, path: []const u8, out: *std.ArrayList(u8)) !void {
    var dir = Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(io);

    var walker = try dir.walk(arena);
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;

        var file = try entry.dir.openFile(io, entry.basename, .{});
        defer file.close(io);

        const size = (try file.stat(io)).size;
        const buf = try arena.alloc(u8, @intCast(size));
        var read_buf: [64 * 1024]u8 = undefined;
        var reader = file.reader(io, &read_buf);
        try reader.interface.readSliceAll(buf);

        try out.appendSlice(arena, buf);
        try out.append(arena, '\n');
    }
}

fn listTouched(out: *Io.Writer, cat: *const Category, limit: usize) !void {
    var shown: usize = 0;
    for (cat.touched.keys()) |name| {
        if (shown == limit) {
            try out.print("  ... and {d} more\n", .{cat.touched.count() - limit});
            break;
        }
        try out.print("  {s}\n", .{name});
        shown += 1;
    }
    if (cat.touched.count() == 0) try out.writeAll("  (none)\n");
}

fn versionOf(doc: Json) []const u8 {
    const header = doc.object.get("header") orelse return "unknown";
    const version = header.object.get("version_full_name") orelse return "unknown";
    return version.string;
}
