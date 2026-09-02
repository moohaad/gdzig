//! Audits every absolute gdzig autodoc link emitted into generated bindings.
//! A target is valid only when its file and each declaration segment exist.

pub fn main(init: std.process.Init) !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3) return fail("expected the generated bindings and maintained source directories", .{});

    var root = try std.Io.Dir.openDir(.cwd(), io, args[1], .{ .iterate = true });
    defer root.close(io);
    var maintained = try std.Io.Dir.openDir(.cwd(), io, args[2], .{ .iterate = true });
    defer maintained.close(io);

    var links: std.StringHashMapUnmanaged(void) = .empty;
    var generated_files: std.StringHashMapUnmanaged(void) = .empty;
    var walker = try root.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        try generated_files.put(arena, try arena.dupe(u8, entry.path), {});
        const source = try root.readFileAlloc(io, entry.path, arena, @enumFromInt(64 << 20));
        try collectLinks(arena, &links, source);
    }

    // The final autodoc input combines bindgen output with maintained files
    // such as Variant and the mixins. Scan only maintained files that bindgen
    // did not produce, so a stale ignored copy under src cannot affect this
    // gate while handwritten documentation still receives the same coverage.
    var maintained_walker = try maintained.walk(arena);
    defer maintained_walker.deinit();
    while (try maintained_walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        if (generated_files.contains(entry.path)) continue;
        const source = try maintained.readFileAlloc(io, entry.path, arena, @enumFromInt(64 << 20));
        try collectLinks(arena, &links, source);
    }

    var source_cache: std.StringHashMapUnmanaged([]const u8) = .empty;
    var broken: usize = 0;
    var it = links.keyIterator();
    while (it.next()) |target| {
        const valid = validateTarget(io, arena, root, maintained, &source_cache, target.*) catch |err| {
            std.debug.print("documentation link target '{s}' could not be checked: {s}\n", .{ target.*, @errorName(err) });
            broken += 1;
            continue;
        };
        if (!valid) {
            std.debug.print("broken autodoc link: {s}{s}\n", .{ link_prefix, target.* });
            broken += 1;
        }
    }

    if (broken != 0) return fail("{d} of {d} unique autodoc links are broken", .{ broken, links.count() });
    std.debug.print("documentation links: all {d} autodoc targets resolve\n", .{links.count()});
}

fn collectLinks(arena: std.mem.Allocator, links: *std.StringHashMapUnmanaged(void), source: []const u8) !void {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, source, from, link_prefix)) |start| {
        const target_start = start + link_prefix.len;
        var end = target_start;
        while (end < source.len and source[end] != ')' and !std.ascii.isWhitespace(source[end])) : (end += 1) {}
        if (end > target_start) try links.put(arena, try arena.dupe(u8, source[target_start..end]), {});
        from = end;
    }
}

fn validateTarget(
    io: std.Io,
    arena: std.mem.Allocator,
    root: std.Io.Dir,
    maintained: std.Io.Dir,
    source_cache: *std.StringHashMapUnmanaged([]const u8),
    target: []const u8,
) !bool {
    var parts_buffer: [16][]const u8 = undefined;
    var part_count: usize = 0;
    var parts_it = std.mem.splitScalar(u8, target, '.');
    while (parts_it.next()) |part| {
        if (part_count == parts_buffer.len) return false;
        parts_buffer[part_count] = part;
        part_count += 1;
    }
    const parts = parts_buffer[0..part_count];
    if (parts.len < 2) return false;

    const filename, const declarations = if (std.mem.eql(u8, parts[0], "class") or
        std.mem.eql(u8, parts[0], "builtin"))
    blk: {
        if (parts.len < 3) return false;
        break :blk .{
            try std.fmt.allocPrint(arena, "{s}/{s}.zig", .{ parts[0], parts[1] }),
            parts[2..],
        };
    } else if (std.mem.eql(u8, parts[0], "global")) blk: {
        if (parts.len == 2) break :blk .{ "global.zig", parts[1..] };
        break :blk .{
            try std.fmt.allocPrint(arena, "global/{s}.zig", .{parts[1]}),
            parts[2..],
        };
    } else blk: {
        break :blk .{
            try std.fmt.allocPrint(arena, "{s}.zig", .{parts[0]}),
            parts[1..],
        };
    };

    const source = source_cache.get(filename) orelse source: {
        const contents = root.readFileAlloc(io, filename, arena, @enumFromInt(64 << 20)) catch
            maintained.readFileAlloc(io, filename, arena, @enumFromInt(64 << 20)) catch return false;
        try source_cache.put(arena, filename, contents);
        break :source contents;
    };

    for (declarations) |declaration| {
        if (!hasPublicDeclaration(source, declaration)) return false;
    }
    return true;
}

fn hasPublicDeclaration(source: []const u8, name: []const u8) bool {
    const forms = [_][]const u8{ "pub const ", "pub var ", "pub fn " };
    for (forms) |form| {
        var from: usize = 0;
        while (std.mem.indexOfPos(u8, source, from, form)) |start| {
            const name_start = start + form.len;
            if (identifierMatches(source[name_start..], name)) return true;
            from = name_start;
        }
    }

    const quoted = "pub fn @\"";
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, source, from, quoted)) |start| {
        const name_start = start + quoted.len;
        if (source[name_start..].len > name.len and
            std.mem.eql(u8, source[name_start..][0..name.len], name) and
            source[name_start + name.len] == '"') return true;
        from = name_start;
    }
    return false;
}

fn identifierMatches(source: []const u8, name: []const u8) bool {
    if (source.len < name.len or !std.mem.eql(u8, source[0..name.len], name)) return false;
    if (source.len == name.len) return true;
    return !std.ascii.isAlphanumeric(source[name.len]) and source[name.len] != '_';
}

fn fail(comptime format: []const u8, args: anytype) error{DocLinksTestFailed} {
    std.debug.print("documentation link test: " ++ format ++ "\n", args);
    return error.DocLinksTestFailed;
}

const link_prefix = "https://gdzig.github.io/gdzig/#gdzig.";
const std = @import("std");
