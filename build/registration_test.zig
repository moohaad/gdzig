//! Checks that registry modules cannot provide only one lifecycle hook.
//!
//! The guard is a `@compileError`, so this scaffolds a real consumer, accepts
//! the paired case, and checks both one-sided cases fail with useful messages.

pub fn main(init: std.process.Init) !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = init.io;

    var args = try init.minimal.args.iterateAllocator(arena);
    _ = args.next();

    const scaffolder = args.next() orelse return fail("expected the init executable's path", .{});
    const out_path = args.next() orelse return fail("expected an output directory", .{});
    const dep_path = args.next() orelse return fail("expected a relative path to gdzig", .{});

    std.Io.Dir.cwd().deleteTree(io, out_path) catch {};

    const name = "registrationprobe";
    try run(io, ".", &.{ scaffolder, "--name", name, "--out", out_path }, null);

    var dir = std.Io.Dir.openDir(.cwd(), io, out_path, .{}) catch |err| {
        return fail("'{s}' was not created: {s}", .{ out_path, @errorName(err) });
    };
    defer dir.close(io);

    const manifest = try dir.readFileAlloc(io, "build.zig.zon", arena, @enumFromInt(1 << 20));
    const fingerprint = try between(manifest, ".fingerprint = ", ",");
    try dir.writeFile(io, .{ .sub_path = "build.zig.zon", .data = try std.fmt.allocPrint(arena,
        \\.{{
        \\    .name = .{s},
        \\    .version = "0.0.0",
        \\    .fingerprint = {s},
        \\    .minimum_zig_version = "0.16.0",
        \\    .dependencies = .{{
        \\        .gdzig = .{{ .path = "{s}" }},
        \\    }},
        \\    .paths = .{{ "build.zig", "build.zig.zon", "src" }},
        \\}}
        \\
    , .{ name, fingerprint, dep_path }) });

    // Avoid an unrelated warning from addExtension in a project this compile
    // gate never opens with Godot.
    try dir.createDirPath(io, ".godot");
    try dir.writeFile(io, .{ .sub_path = ".godot/extension_list.cfg", .data = "res://" ++ name ++ ".gdextension\n" });

    const entry = try std.fmt.allocPrint(arena, "src/{s}.zig", .{name});

    try dir.writeFile(io, .{ .sub_path = entry, .data = try probeSource(
        arena,
        "pub fn register(_: *godot.extension.Registry) void {}",
        "pub fn unregister(_: *godot.extension.Registry) void {}",
    ) });
    run(io, out_path, &.{ "zig", "build" }, null) catch {
        return fail("a module with paired register and unregister hooks failed to compile", .{});
    };

    try rejects(
        io,
        arena,
        dir,
        entry,
        out_path,
        "pub fn register(_: *godot.extension.Registry) void {}",
        "",
        "declares 'register' but not 'unregister'",
    );
    try rejects(
        io,
        arena,
        dir,
        entry,
        out_path,
        "",
        "pub fn unregister(_: *godot.extension.Registry) void {}",
        "declares 'unregister' but not 'register'",
    );

    std.debug.print("registration: paired module hooks accepted, one-sided hooks rejected\n", .{});
}

fn rejects(
    io: std.Io,
    arena: std.mem.Allocator,
    dir: std.Io.Dir,
    entry: []const u8,
    out_path: []const u8,
    register_decl: []const u8,
    unregister_decl: []const u8,
    wanted: []const u8,
) !void {
    try dir.writeFile(io, .{ .sub_path = entry, .data = try probeSource(arena, register_decl, unregister_decl) });

    var output: std.ArrayList(u8) = .empty;
    if (run(io, out_path, &.{ "zig", "build" }, &output)) |_| {
        return fail("a one-sided registry module compiled anyway (expected '{s}')", .{wanted});
    } else |_| {}

    if (std.mem.indexOf(u8, output.items, wanted) == null) {
        return fail("the build failed, but not with '{s}'; got:\n{s}", .{ wanted, output.items });
    }
}

fn probeSource(arena: std.mem.Allocator, register_decl: []const u8, unregister_decl: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena,
        \\const Module = struct {{
        \\    {s}
        \\    {s}
        \\}};
        \\
        \\const items = .{{Module}};
        \\
        \\pub fn register(r: *godot.extension.Registry) void {{
        \\    r.registerAll(items);
        \\}}
        \\
        \\pub fn unregister(r: *godot.extension.Registry) void {{
        \\    r.unregisterAll(items);
        \\}}
        \\
        \\const godot = @import("godot");
        \\
    , .{ register_decl, unregister_decl });
}

fn run(io: std.Io, cwd_path: []const u8, argv: []const []const u8, collect: ?*std.ArrayList(u8)) !void {
    var cwd_dir = try std.Io.Dir.openDir(.cwd(), io, cwd_path, .{});
    defer cwd_dir.close(io);

    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .dir = cwd_dir },
        .stderr = if (collect == null) .inherit else .pipe,
    });

    if (collect) |out| {
        var buf: [4096]u8 = undefined;
        var reader = child.stderr.?.readerStreaming(io, &buf);
        const text = try reader.interface.allocRemaining(std.heap.page_allocator, .limited(1 << 22));
        try out.appendSlice(std.heap.page_allocator, text);
    }

    const term = try child.wait(io);
    if (term != .exited or term.exited != 0) return error.CommandFailed;
}

fn between(haystack: []const u8, open: []const u8, close: []const u8) ![]const u8 {
    const start = std.mem.indexOf(u8, haystack, open) orelse
        return fail("generated build.zig.zon has no '{s}'", .{open});
    const from = start + open.len;
    const end = std.mem.indexOfScalarPos(u8, haystack, from, close[0]) orelse
        return fail("generated build.zig.zon has no '{s}' after '{s}'", .{ close, open });
    return haystack[from..end];
}

fn fail(comptime fmt: []const u8, args: anytype) error{RegistrationCheckFailed} {
    std.debug.print("registration test: " ++ fmt ++ "\n", args);
    return error.RegistrationCheckFailed;
}

const std = @import("std");
