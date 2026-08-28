//! Checks that the watcher cleans stale reload artifacts, and that it notices a
//! source change and does it again.
//!
//! Watching is a loop that never returns, so a test has to observe it from
//! outside and then kill it. The trap is observing it through its output:
//! reading a pipe that may never produce the line you are waiting for turns a
//! failure into a hung job, which is worse than no test.
//!
//! So nothing here reads the watcher's output. Both assertions are file
//! deletions the watcher performs and this program can see: drop a `~*.dll`
//! into the lib directory and poll until it is gone. That is deterministic, it
//! cannot hang -- every wait has a deadline -- and it happens to exercise the
//! two things worth having: the cleanup, and the change detection that triggers
//! a second round of it.
//!
//! Godot is not involved. `--run` is left off, so the watcher never starts a
//! child, which keeps the test free of the one part that genuinely cannot be
//! made deterministic.


pub fn main(init: std.process.Init) !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = init.io;

    var args = try init.minimal.args.iterateAllocator(arena);
    _ = args.next();

    const scaffolder = args.next() orelse return fail("expected the init executable's path", .{});
    const watcher = args.next() orelse return fail("expected the watch executable's path", .{});
    const out_path = args.next() orelse return fail("expected an output directory", .{});
    const dep_path = args.next() orelse return fail("expected a relative path to gdzig", .{});
    const build_root = args.next() orelse return fail("expected the absolute build root", .{});

    // The watcher has to be spawned with the scratch project as its working
    // directory, because that is where it runs `zig build`. Its own path
    // arrived relative to the build root, so it needs joining first or the
    // spawn fails with FileNotFound.
    const watcher_abs = if (std.fs.path.isAbsolute(watcher))
        watcher
    else
        try std.fs.path.join(arena, &.{ build_root, watcher });

    std.Io.Dir.cwd().deleteTree(io, out_path) catch {};

    const name = "watchprobe";
    try run(io, ".", &.{ scaffolder, "--name", name, "--out", out_path });

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

    // Once up front, so `lib/` exists and the watcher's own build is a no-op
    // rather than the slowest part of the first assertion.
    try run(io, out_path, &.{ "zig", "build" });

    try dir.writeFile(io, .{ .sub_path = "lib/~stale.dll", .data = "not a real library" });

    var child = try std.process.spawn(io, .{
        .argv = &.{ watcher_abs, "--src-dir", "src", "--lib-dir", "lib" },
        .cwd = .{ .dir = dir },
    });
    // Killed on every path out of here, including the failures below.
    defer child.kill(io);

    try waitGone(io, dir, "lib/~stale.dll", "the watcher did not clean the stale artifact at startup");

    // Now the same thing again, but only reachable by noticing a change. The
    // artifact goes in first: the watcher cleans as part of handling the
    // change, so it has to be there before the change is made.
    try dir.writeFile(io, .{ .sub_path = "lib/~afterchange.dll", .data = "not a real library" });

    const entry = try std.fmt.allocPrint(arena, "src/{s}.zig", .{name});
    const source = try dir.readFileAlloc(io, entry, arena, @enumFromInt(1 << 20));
    try dir.writeFile(io, .{ .sub_path = entry, .data = try std.fmt.allocPrint(
        arena,
        "{s}\n// touched by the watch test\n",
        .{source},
    ) });

    try waitGone(io, dir, "lib/~afterchange.dll", "the watcher did not react to a source change");

    std.debug.print("watch: cleaned stale artifacts at startup and after a change\n", .{});
}

/// Polls until `path` is gone, or gives up. The deadline is what keeps a
/// failure from becoming a hung job.
fn waitGone(io: std.Io, dir: std.Io.Dir, path: []const u8, whatFailed: []const u8) !void {
    const attempts = 1200; // 100ms apart, so two minutes
    var i: usize = 0;
    while (i < attempts) : (i += 1) {
        _ = dir.statFile(io, path, .{}) catch return;
        std.Io.sleep(io, std.Io.Duration.fromNanoseconds(100 * std.time.ns_per_ms), .awake) catch {};
    }
    return fail("{s} ('{s}' is still there after two minutes)", .{ whatFailed, path });
}

fn run(io: std.Io, cwd_path: []const u8, argv: []const []const u8) !void {
    var cwd_dir = try std.Io.Dir.openDir(.cwd(), io, cwd_path, .{});
    defer cwd_dir.close(io);

    var child = try std.process.spawn(io, .{ .argv = argv, .cwd = .{ .dir = cwd_dir } });
    const term = try child.wait(io);
    if (term != .exited or term.exited != 0) {
        return fail("'{s}' failed in {s}", .{ argv[0], cwd_path });
    }
}

fn between(haystack: []const u8, open: []const u8, close: []const u8) ![]const u8 {
    const start = std.mem.indexOf(u8, haystack, open) orelse
        return fail("generated build.zig.zon has no '{s}'", .{open});
    const from = start + open.len;
    const end = std.mem.indexOfScalarPos(u8, haystack, from, close[0]) orelse
        return fail("generated build.zig.zon has no '{s}' after '{s}'", .{ close, open });
    return haystack[from..end];
}

fn fail(comptime fmt: []const u8, args: anytype) error{WatchCheckFailed} {
    std.debug.print("watch test: " ++ fmt ++ "\n", args);
    return error.WatchCheckFailed;
}

const std = @import("std");
