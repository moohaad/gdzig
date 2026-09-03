//! Verifies that a reduced bindgen run emits the requested class, closes over
//! every class alias its generated files reference, and omits unrelated API.

pub fn main(init: std.process.Init) !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 2) return fail("expected the selective bindings directory", .{});

    var root = try std.Io.Dir.openDir(.cwd(), io, args[1], .{ .iterate = true });
    defer root.close(io);

    const index = try root.readFileAlloc(io, "class.zig", arena, @enumFromInt(4 << 20));
    if (!hasExport(index, "Node2d")) return fail("requested Node2D was not generated", .{});
    if (!hasExport(index, "Object")) return fail("Node2D's Object ancestor was not generated", .{});
    if (!hasExport(index, "ClassDb")) return fail("the ClassDB runtime dependency was not generated", .{});
    if (hasExport(index, "EditorPlugin")) return fail("unrelated EditorPlugin was generated", .{});

    var classes = try root.openDir(io, "class", .{ .iterate = true });
    defer classes.close(io);
    var entries = classes.iterate();
    var count: usize = 0;
    while (try entries.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".zig")) continue;
        count += 1;
        const source = try classes.readFileAlloc(io, entry.name, arena, @enumFromInt(64 << 20));
        try checkClassAliases(index, source, entry.name);
    }

    if (count < 3) return fail("dependency closure emitted only {d} classes", .{count});
    if (count >= 250) return fail("Node2D selection unexpectedly expanded to {d} classes", .{count});

    const generic_surface = try root.readFileAlloc(io, "surface_generic.zig", arena, @enumFromInt(64 << 20));
    if (std.mem.indexOf(u8, generic_surface, "gdzig.class.EditorPlugin.") != null) {
        return fail("surface audit still references an omitted class", .{});
    }

    std.debug.print("selective bindings: Node2D closed over {d} classes and omitted unrelated classes\n", .{count});
}

fn checkClassAliases(index: []const u8, source: []const u8, filename: []const u8) !void {
    const marker = " = gdzig.class.";
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, trimmed, "const ")) continue;
        const start = std.mem.indexOf(u8, trimmed, marker) orelse continue;
        const name_start = start + marker.len;
        const end = std.mem.indexOfScalarPos(u8, trimmed, name_start, ';') orelse continue;
        const name = trimmed[name_start..end];
        if (name.len == 0 or !std.ascii.isUpper(name[0])) continue;
        if (std.mem.indexOfScalar(u8, name, '.') != null) continue;
        if (!hasExport(index, name)) {
            return fail("class/{s} references omitted class {s}", .{ filename, name });
        }
    }
}

fn hasExport(index: []const u8, name: []const u8) bool {
    var buffer: [256]u8 = undefined;
    const declaration = std.fmt.bufPrint(&buffer, "pub const {s} =", .{name}) catch return false;
    return std.mem.indexOf(u8, index, declaration) != null;
}

fn fail(comptime format: []const u8, args: anytype) error{SelectiveBindingsTestFailed} {
    std.debug.print("selective bindings test: " ++ format ++ "\n", args);
    return error.SelectiveBindingsTestFailed;
}

const std = @import("std");
