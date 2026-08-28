//! Scaffolds a project with `init-gdzig` and builds it.
//!
//! `init-gdzig` is the first thing a newcomer runs, and until now nothing
//! checked that what it produces compiles. It writes four interlocking files --
//! the entry symbol has to match between `build.zig` and the `.gdextension`,
//! the module has to point at the source it also writes -- and a mistake in any
//! of them surfaces as a build failure in someone else's project.
//!
//! The scaffolder ends by fetching gdzig from GitHub. This replaces that with a
//! path dependency on the working tree, for two reasons: the test then needs no
//! network, and it checks *this* gdzig rather than whatever is published, which
//! is the only version that can be broken by a change under test.
//!
//! Rewriting the manifest is also an assertion. It carries over the name and
//! fingerprint the scaffolder produced, so a fingerprint left at `0x0` -- which
//! is what happens if the `zig init` step it shells out to fails -- stops the
//! nested build with the same error a user would see.

pub fn main(init: std.process.Init) !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = init.io;

    var args = try init.minimal.args.iterateAllocator(arena);
    _ = args.next(); // argv[0]

    const scaffolder = args.next() orelse return fail("expected the init executable's path", .{});
    const out_path = args.next() orelse return fail("expected an output directory", .{});
    const dep_path = args.next() orelse return fail("expected a relative path to gdzig", .{});

    // A previous run's output would make `zig init` refuse, and a stale tree
    // would let a broken scaffolder pass on last time's files.
    std.Io.Dir.cwd().deleteTree(io, out_path) catch {};

    const name = "initprobe";

    try run(io, ".", &.{ scaffolder, "--name", name, "--out", out_path });

    var dir = std.Io.Dir.openDir(.cwd(), io, out_path, .{}) catch |err| {
        return fail("'{s}' was not created: {s}", .{ out_path, @errorName(err) });
    };
    defer dir.close(io);

    // Every file the scaffolder promises. Checked by name before building, so a
    // missing one is reported as missing rather than as a compile error.
    for ([_][]const u8{
        "build.zig",
        "build.zig.zon",
        // The quickstart tells the reader to open this in Godot. Without it
        // there is no project to open and the scaffold is unusable, so it is
        // checked like any other file the scaffolder promises.
        "project.godot",
        name ++ ".gdextension",
        "src/" ++ name ++ ".zig",
    }) |wanted| {
        _ = dir.statFile(io, wanted, .{}) catch |err| {
            return fail("scaffolder did not write '{s}': {s}", .{ wanted, @errorName(err) });
        };
    }

    const manifest = dir.readFileAlloc(io, "build.zig.zon", arena, @enumFromInt(1 << 20)) catch |err| {
        return fail("cannot read the generated build.zig.zon: {s}", .{@errorName(err)});
    };

    const fingerprint = try between(manifest, ".fingerprint = ", ",");
    if (std.mem.eql(u8, fingerprint, "0x0")) {
        return fail("fingerprint is still 0x0, so `zig init` did not run; the nested build cannot succeed", .{});
    }

    // Rewritten rather than patched: `zig fetch --save` may or may not have
    // reached GitHub, so the dependency block is not known in advance.
    const rewritten = try std.fmt.allocPrint(arena,
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
    , .{ name, fingerprint, dep_path });
    try dir.writeFile(io, .{ .sub_path = "build.zig.zon", .data = rewritten });

    try run(io, out_path, &.{ "zig", "build" });

    // The point of the whole exercise: a library where the `.gdextension` says
    // one will be.
    var lib = dir.openDir(io, "lib", .{ .iterate = true }) catch |err| {
        return fail("no lib/ directory after building the scaffolded project: {s}", .{@errorName(err)});
    };
    defer lib.close(io);

    var found = false;
    var iter = lib.iterate();
    while (iter.next(io) catch null) |entry| {
        if (entry.kind == .file and std.mem.indexOf(u8, entry.name, name) != null) found = true;
    }
    if (!found) return fail("built, but produced no library named for '{s}' in lib/", .{name});

    std.debug.print("init-gdzig: scaffolded '{s}' and built it\n", .{name});
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

/// The text between two markers, or an error naming the one that was missing.
fn between(haystack: []const u8, open: []const u8, close: []const u8) ![]const u8 {
    const start = std.mem.indexOf(u8, haystack, open) orelse
        return fail("generated build.zig.zon has no '{s}'", .{open});
    const from = start + open.len;
    const end = std.mem.indexOfScalarPos(u8, haystack, from, close[0]) orelse
        return fail("generated build.zig.zon has no '{s}' after '{s}'", .{ close, open });
    return haystack[from..end];
}

fn fail(comptime fmt: []const u8, args: anytype) error{InitScaffoldFailed} {
    std.debug.print("init-gdzig test: " ++ fmt ++ "\n", args);
    return error.InitScaffoldFailed;
}

const std = @import("std");
