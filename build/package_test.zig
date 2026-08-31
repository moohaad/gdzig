//! Builds a project against gdzig as a *package* rather than as this checkout.
//!
//! Every other gate, and the example, reach gdzig through a path dependency on
//! the working tree -- which has a `.zig-cache` with Godot already extracted in
//! it. That happens to paper over any path gdzig hands out relative to the wrong
//! root, because the wrong root has the file too. A real consumer fetches gdzig
//! into `zig-pkg/`, where there is no cache and no Godot, and the same path
//! resolves to nothing:
//!
//!     error: failed to run '...\zig-pkg\godot-<hash>\.zig-cache\o\<digest>\
//!     Godot_v4.7.1-stable_win64.exe': FileNotFound
//!
//! That reached users on their first build and was invisible from inside the
//! repository. This gate is the difference.
//!
//! The package is built from `git ls-files` rather than by copying the tree:
//! tracked files are what a fetched package contains, 198 of them and about two
//! megabytes, where the working tree carries 226 MB of generated bindings that a
//! consumer regenerates for itself. Committed state only, so an uncommitted
//! regression shows up on the next run rather than this one -- acceptable for a
//! gate whose question is "would a published package work".

pub fn main(init: std.process.Init) !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = init.io;

    var args = try init.minimal.args.iterateAllocator(arena);
    _ = args.next();

    const scaffolder = args.next() orelse return fail("expected the init executable's path", .{});
    const out_path = args.next() orelse return fail("expected an output directory", .{});
    const gdzig_root = args.next() orelse return fail("expected the absolute gdzig root", .{});

    std.Io.Dir.cwd().deleteTree(io, out_path) catch {};
    try std.Io.Dir.cwd().createDirPath(io, out_path);

    var out = try std.Io.Dir.openDir(.cwd(), io, out_path, .{});
    defer out.close(io);

    // 1. The package: every tracked file, and nothing else.
    try out.createDirPath(io, "pkg");
    var pkg = try out.openDir(io, "pkg", .{});
    defer pkg.close(io);

    var src = try std.Io.Dir.openDir(.cwd(), io, gdzig_root, .{});
    defer src.close(io);

    const listing = try gitListFiles(io, arena, src, gdzig_root);
    var copied: usize = 0;
    var it = std.mem.splitScalar(u8, listing, 0);
    while (it.next()) |rel| {
        if (rel.len == 0) continue;
        src.copyFile(rel, pkg, rel, io, .{ .make_path = true }) catch |err| {
            return fail("could not copy '{s}': {s}", .{ rel, @errorName(err) });
        };
        copied += 1;
    }
    if (copied == 0) return fail("git listed no files; is '{s}' a checkout?", .{gdzig_root});

    // A copy that still had one would defeat the whole point.
    if (pkg.statFile(io, ".zig-cache", .{})) |_| {
        return fail("the package copy has a .zig-cache, so it cannot show the bug it is here for", .{});
    } else |_| {}

    // 2. A project that depends on it.
    const name = "pkgprobe";
    const consumer_path = try std.fs.path.join(arena, &.{ out_path, "consumer" });
    try run(io, ".", &.{ scaffolder, "--name", name, "--out", consumer_path });

    var consumer = std.Io.Dir.openDir(.cwd(), io, consumer_path, .{}) catch |err| {
        return fail("'{s}' was not created: {s}", .{ consumer_path, @errorName(err) });
    };
    defer consumer.close(io);

    const manifest = try consumer.readFileAlloc(io, "build.zig.zon", arena, @enumFromInt(1 << 20));
    const fingerprint = try between(manifest, ".fingerprint = ", ",");
    try consumer.writeFile(io, .{ .sub_path = "build.zig.zon", .data = try std.fmt.allocPrint(arena,
        \\.{{
        \\    .name = .{s},
        \\    .version = "0.0.0",
        \\    .fingerprint = {s},
        \\    .minimum_zig_version = "0.16.0",
        \\    .dependencies = .{{
        \\        .gdzig = .{{ .path = "../pkg" }},
        \\    }},
        \\    .paths = .{{ "build.zig", "build.zig.zon", "src" }},
        \\}}
        \\
    , .{ name, fingerprint }) });

    // 3. The assertion: it builds. Godot has to be downloaded and then found
    //    again through a path that means the same thing from in here.
    try run(io, consumer_path, &.{ "zig", "build" });

    var lib = consumer.openDir(io, "lib", .{ .iterate = true }) catch |err| {
        return fail("no lib/ after building against the package: {s}", .{@errorName(err)});
    };
    defer lib.close(io);

    var found = false;
    var entries = lib.iterate();
    while (entries.next(io) catch null) |entry| {
        if (entry.kind == .file and std.mem.indexOf(u8, entry.name, name) != null) found = true;
    }
    if (!found) return fail("built, but produced no library named for '{s}'", .{name});

    std.debug.print("package: built a project against gdzig as a package ({d} files)\n", .{copied});
}

/// The tracked files, NUL-separated. `git` rather than a directory walk because
/// the working tree holds generated bindings a package would not carry, and
/// reimplementing which of them are ignored is how that list goes stale.
fn gitListFiles(io: std.Io, arena: std.mem.Allocator, dir: std.Io.Dir, root: []const u8) ![]const u8 {
    var child = std.process.spawn(io, .{
        .argv = &.{ "git", "ls-files", "-z" },
        .cwd = .{ .dir = dir },
        .stdout = .pipe,
    }) catch |err| {
        return fail("could not run git in '{s}': {s}", .{ root, @errorName(err) });
    };

    var buf: [64 * 1024]u8 = undefined;
    var reader = child.stdout.?.readerStreaming(io, &buf);
    const listing = try reader.interface.allocRemaining(arena, .limited(8 << 20));

    const term = try child.wait(io);
    if (term != .exited or term.exited != 0) return fail("'git ls-files' failed in '{s}'", .{root});
    return listing;
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

fn fail(comptime fmt: []const u8, args: anytype) error{PackageCheckFailed} {
    std.debug.print("package test: " ++ fmt ++ "\n", args);
    return error.PackageCheckFailed;
}

const std = @import("std");
