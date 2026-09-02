//! Checks that a consumer sees the actions from its actual `project.godot`.
//!
//! A generated enum only earns its keep if a configured action compiles and a
//! typo does not. The rejection is a compiler diagnostic, so this test drives
//! two nested builds and inspects the expected failure.

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
    const godot_path = args.next();
    const godot_option = if (godot_path) |path|
        try std.fmt.allocPrint(arena, "-Dgodot-path={s}", .{path})
    else
        null;

    std.Io.Dir.cwd().deleteTree(io, out_path) catch {};
    try run(io, ".", &.{ scaffolder, "--name", "actionprobe", "--out", out_path }, null);

    var dir = try std.Io.Dir.openDir(.cwd(), io, out_path, .{});
    defer dir.close(io);

    const manifest = try dir.readFileAlloc(io, "build.zig.zon", arena, @enumFromInt(1 << 20));
    const fingerprint = try between(manifest, ".fingerprint = ", ",");
    try dir.writeFile(io, .{ .sub_path = "build.zig.zon", .data = try std.fmt.allocPrint(arena,
        \\.{{
        \\    .name = .actionprobe,
        \\    .version = "0.0.0",
        \\    .fingerprint = {s},
        \\    .minimum_zig_version = "0.16.0",
        \\    .dependencies = .{{
        \\        .gdzig = .{{ .path = "{s}" }},
        \\    }},
        \\    .paths = .{{ "build.zig", "build.zig.zon", "src" }},
        \\}}
        \\
    , .{ fingerprint, dep_path }) });

    try dir.createDirPath(io, ".godot");
    try dir.writeFile(io, .{
        .sub_path = ".godot/extension_list.cfg",
        .data = "res://actionprobe.gdextension\n",
    });

    const original_project = try dir.readFileAlloc(io, "project.godot", arena, @enumFromInt(1 << 20));
    try dir.writeFile(io, .{
        .sub_path = "project.godot",
        .data = try projectSource(arena, original_project, "jump"),
    });

    const entry = "src/actionprobe.zig";
    try dir.writeFile(io, .{ .sub_path = entry, .data = source(
        \\    use(godot.input.Action.jump);
        \\    use(godot.input.Action.@"menu accept");
    ) });
    try runBuild(io, out_path, godot_option, null);

    // Rename an action in the project without touching build.zig. The next
    // invocation must regenerate the enum and reject the now-stale Zig use.
    try dir.writeFile(io, .{
        .sub_path = "project.godot",
        .data = try projectSource(arena, original_project, "leap"),
    });
    var output: std.ArrayList(u8) = .empty;
    const failed = runBuild(io, out_path, godot_option, &output);
    if (failed) |_| return fail(
        "an action removed from project.godot compiled anyway",
        .{},
    ) else |_| {}

    if (std.mem.indexOf(u8, output.items, "jump") == null or
        std.mem.indexOf(u8, output.items, "Action") == null)
    {
        return fail("the rejection does not identify the bad action; got:\n{s}", .{output.items});
    }

    std.debug.print("input actions: generated project enum follows an Input Map rename\n", .{});
}

fn projectSource(
    allocator: std.mem.Allocator,
    original: []const u8,
    primary_action: []const u8,
) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        \\{s}
        \\[input]
        \\
        \\{s}={{
        \\"deadzone": 0.5,
        \\"events": []
        \\}}
        \\"menu accept"={{
        \\"deadzone": 0.5,
        \\"events": []
        \\}}
        \\
    , .{ original, primary_action });
}

fn runBuild(
    io: std.Io,
    cwd_path: []const u8,
    godot_option: ?[]const u8,
    collect: ?*std.ArrayList(u8),
) !void {
    if (godot_option) |option| {
        return run(io, cwd_path, &.{ "zig", "build", option }, collect);
    }
    return run(io, cwd_path, &.{ "zig", "build" }, collect);
}

fn source(comptime body: []const u8) []const u8 {
    return
    \\pub fn register(r: *godot.extension.Registry) void {
    \\    _ = r;
    ++ body ++
        \\}
        \\
        \\fn use(_: godot.input.Action) void {}
        \\
        \\const godot = @import("godot");
        \\
    ;
}

fn run(io: std.Io, cwd_path: []const u8, argv: []const []const u8, collect: ?*std.ArrayList(u8)) !void {
    var cwd = try std.Io.Dir.openDir(.cwd(), io, cwd_path, .{});
    defer cwd.close(io);

    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .dir = cwd },
        .stderr = if (collect == null) .inherit else .pipe,
    });

    if (collect) |out| {
        var buf: [4096]u8 = undefined;
        var reader = child.stderr.?.readerStreaming(io, &buf);
        const text = try reader.interface.allocRemaining(std.heap.page_allocator, .limited(1 << 22));
        defer std.heap.page_allocator.free(text);
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

fn fail(comptime format: []const u8, args: anytype) error{InputActionCheckFailed} {
    std.debug.print("input action test: " ++ format ++ "\n", args);
    return error.InputActionCheckFailed;
}

const std = @import("std");
