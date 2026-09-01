//! Checks that a correctly named Godot virtual compiles and that public
//! underscore-prefixed functions Godot cannot call are rejected.
//!
//! The rejection is a `@compileError`, so a normal unit test cannot exercise
//! it. Like the signal and `res://` gates, this scaffolds a real consumer,
//! drives builds expected to fail, and checks that the useful diagnostic is
//! what stopped them.

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

    const name = "virtualprobe";
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

    try dir.writeFile(io, .{ .sub_path = entry, .data = probeSource("_physics_process") });
    run(io, out_path, &.{ "zig", "build" }, null) catch {
        return fail("a correctly named _physics_process virtual failed to compile", .{});
    };

    try rejects(
        io,
        dir,
        entry,
        out_path,
        "_physicsProcess",
        "did you mean '_physics_process'?",
    );
    try rejects(
        io,
        dir,
        entry,
        out_path,
        "_definitely_not_a_virtual",
        "Godot will never call this function",
    );
    try rejects(
        io,
        dir,
        entry,
        out_path,
        "_toString",
        "did you mean '_to_string'?",
    );

    std.debug.print("virtuals: valid callback accepted, unknown callbacks rejected\n", .{});
}

fn rejects(
    io: std.Io,
    dir: std.Io.Dir,
    entry: []const u8,
    out_path: []const u8,
    comptime virtual_name: []const u8,
    comptime wanted: []const u8,
) !void {
    try dir.writeFile(io, .{ .sub_path = entry, .data = probeSource(virtual_name) });

    var output: std.ArrayList(u8) = .empty;
    if (run(io, out_path, &.{ "zig", "build" }, &output)) |_| {
        return fail("unknown virtual '{s}' compiled anyway", .{virtual_name});
    } else |_| {}

    if (std.mem.indexOf(u8, output.items, wanted) == null) {
        return fail("'{s}' failed, but not with '{s}'; got:\n{s}", .{ virtual_name, wanted, output.items });
    }
}

fn probeSource(comptime virtual_name: []const u8) []const u8 {
    return std.fmt.comptimePrint(
        \\const Probe = struct {{
        \\    allocator: std.mem.Allocator,
        \\    base: *godot.class.Node,
        \\
        \\    pub fn {s}(_: *Probe, _: f64) void {{}}
        \\}};
        \\
        \\pub fn register(r: *godot.extension.Registry) void {{
        \\    r.autoRegister(Probe);
        \\}}
        \\
        \\const std = @import("std");
        \\const godot = @import("godot");
        \\
    , .{virtual_name});
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

fn fail(comptime fmt: []const u8, args: anytype) error{VirtualCheckFailed} {
    std.debug.print("virtual test: " ++ fmt ++ "\n", args);
    return error.VirtualCheckFailed;
}

const std = @import("std");
