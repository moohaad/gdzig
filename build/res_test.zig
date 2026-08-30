//! Checks that `res` accepts a path the project has and rejects one it does not.
//!
//! The whole value of `res` over `load` is the second half: a typo in a
//! `res://` path becomes a build error instead of a null at runtime, hours
//! later, in a scene you were not looking at. That behaviour is a
//! `@compileError`, so it cannot be asserted from a normal test -- a test that
//! triggers it stops compiling. It has to be a build that is *expected* to
//! fail, with its output read back.
//!
//! Both directions matter equally. A check that only proves the good path
//! compiles would still pass if the comptime search were deleted outright,
//! which is exactly the regression worth catching.
//!
//! The project is scaffolded rather than checked in: `res_paths` is built by
//! walking `godot_project` at build time, so a real project on disk is the only
//! way to exercise the walk -- including the backslash-to-slash normalisation,
//! which is only ever wrong on Windows.

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

    const name = "resprobe";
    try run(io, ".", &.{ scaffolder, "--name", name, "--out", out_path }, null);

    var dir = std.Io.Dir.openDir(.cwd(), io, out_path, .{}) catch |err| {
        return fail("'{s}' was not created: {s}", .{ out_path, @errorName(err) });
    };
    defer dir.close(io);

    // Depend on this checkout rather than the published gdzig, so the test
    // covers the tree it is running in and needs no network.
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

    // As in init_test: the file Godot's import pass would write, so a gate that
    // never opens Godot does not warn about its absence on every clean run.
    try dir.createDirPath(io, ".godot");
    try dir.writeFile(io, .{ .sub_path = ".godot/extension_list.cfg", .data = "res://resprobe.gdextension\n" });

    const entry = try std.fmt.allocPrint(arena, "src/{s}.zig", .{name});

    // `build.zig` is a file the scaffolder wrote into the project, so the walk
    // that fills `res_paths` must have seen it. Using it rather than a `.tscn`
    // keeps the fixture free of Godot assets.
    try dir.writeFile(io, .{ .sub_path = entry, .data = probeSource("res://build.zig") });
    try run(io, out_path, &.{ "zig", "build" }, null);

    // And now one that is not there. The build has to fail, and say which path.
    try dir.writeFile(io, .{ .sub_path = entry, .data = probeSource("res://not_a_real_file.tscn") });

    var output: std.ArrayList(u8) = .empty;
    const failed = run(io, out_path, &.{ "zig", "build" }, &output);

    if (failed) |_| return fail(
        "a res:// path the project does not have compiled anyway; the comptime check did not run",
        .{},
    ) else |_| {}

    if (std.mem.indexOf(u8, output.items, "Resource not found in godot_project") == null) {
        return fail(
            "the build failed, but not with the resource check; got:\n{s}",
            .{output.items},
        );
    }
    if (std.mem.indexOf(u8, output.items, "res://not_a_real_file.tscn") == null) {
        return fail("the error does not name the offending path, which is the useful half", .{});
    }

    std.debug.print("res: accepted a real path and rejected a missing one\n", .{});
}

fn probeSource(comptime path: []const u8) []const u8 {
    return
    \\pub fn register(r: *godot.extension.Registry) void {
    \\    _ = r;
    \\    _ = godot.res(godot.class.PackedScene, "
    ++ path ++
        \\");
        \\}
        \\
        \\const godot = @import("godot");
        \\
    ;
}

/// Runs `argv`, optionally collecting its output. Errors when the command
/// fails, which the caller may be expecting.
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

fn fail(comptime fmt: []const u8, args: anytype) error{ResCheckFailed} {
    std.debug.print("res test: " ++ fmt ++ "\n", args);
    return error.ResCheckFailed;
}

const std = @import("std");
