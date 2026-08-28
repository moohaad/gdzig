const std = @import("std");

var child_crashed = std.atomic.Value(bool).init(true);
var child_running = std.atomic.Value(bool).init(false);

fn watchGodotThread(io: std.Io, cmd: []const []const u8) void {
    while (true) {
        if (!child_running.load(.seq_cst)) {
            std.Io.sleep(io, std.Io.Duration.fromNanoseconds(100 * std.time.ns_per_ms), .awake) catch {};
            continue;
        }

        var cwd_dir = std.Io.Dir.openDir(.cwd(), io, ".", .{}) catch {
            child_crashed.store(true, .seq_cst);
            child_running.store(false, .seq_cst);
            continue;
        };
        defer cwd_dir.close(io);

        var child = std.process.spawn(io, .{
            .argv = cmd,
            .cwd = .{ .dir = cwd_dir },
        }) catch {
            std.debug.print("[watch] Failed to spawn Godot\n", .{});
            child_crashed.store(true, .seq_cst);
            child_running.store(false, .seq_cst);
            continue;
        };

        const term = child.wait(io) catch |err| {
            std.debug.print("[watch] Failed to wait for Godot: {}\n", .{err});
            child_crashed.store(true, .seq_cst);
            child_running.store(false, .seq_cst);
            continue;
        };

        if (term == .exited and term.exited != 0) {
            std.debug.print("\n[watch] Godot crashed with exit code {}\n", .{term.exited});
            child_crashed.store(true, .seq_cst);
        } else if (term == .signal) {
            std.debug.print("\n[watch] Godot killed by signal\n", .{});
            child_crashed.store(true, .seq_cst);
        } else {
            std.debug.print("\n[watch] Godot exited cleanly.\n", .{});
        }
        child_running.store(false, .seq_cst);
    }
}

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.page_allocator;

    var src_dir_path: []const u8 = "src";
    var lib_dir_path: []const u8 = "lib";
    var run_cmd: ?[]const []const u8 = null;

    var args_iter = try init.minimal.args.iterateAllocator(allocator);
    var args_iter_deinit = args_iter;
    defer args_iter_deinit.deinit();

    _ = args_iter.next(); // Skip executable

    var run_args_list = std.ArrayList([]const u8).empty;
    defer run_args_list.deinit(allocator);

    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--src-dir")) {
            src_dir_path = args_iter.next() orelse return error.MissingSrcDir;
        } else if (std.mem.eql(u8, arg, "--lib-dir")) {
            lib_dir_path = args_iter.next() orelse return error.MissingLibDir;
        } else if (std.mem.eql(u8, arg, "--run")) {
            while (args_iter.next()) |run_arg| {
                try run_args_list.append(allocator, run_arg);
            }
        }
    }

    if (run_args_list.items.len > 0) {
        run_cmd = run_args_list.items;
        
        // Spawn the Godot watcher thread
        _ = try std.Thread.spawn(.{}, watchGodotThread, .{ init.io, run_cmd.? });
    }

    var last_mtime: i128 = try getMaxMTime(init.io, src_dir_path);
    std.debug.print("Watching '{s}' for changes...\n", .{src_dir_path});

    // Run build once at startup
    cleanStaleArtifacts(init.io, lib_dir_path);
    _ = runBuild(init.io);

    if (run_cmd != null) {
        child_crashed.store(false, .seq_cst);
        child_running.store(true, .seq_cst);
    }

    while (true) {
        std.Io.sleep(init.io, std.Io.Duration.fromNanoseconds(100 * std.time.ns_per_ms), .awake) catch {};

        const current_mtime = getMaxMTime(init.io, src_dir_path) catch last_mtime;
        if (current_mtime > last_mtime) {
            std.debug.print("\n[watch] Changes detected in '{s}'. Rebuilding...\n", .{src_dir_path});
            last_mtime = current_mtime;

            cleanStaleArtifacts(init.io, lib_dir_path);
            const build_ok = runBuild(init.io);

            if (build_ok and run_cmd != null) {
                if (child_crashed.load(.seq_cst)) {
                    std.debug.print("[watch] Restarting Godot instance...\n", .{});
                    child_crashed.store(false, .seq_cst);
                    child_running.store(true, .seq_cst);
                }
            }
        }
    }
}

fn getMaxMTime(io: std.Io, src_dir_path: []const u8) !i128 {
    var max_mtime: i128 = 0;
    // `.iterate` is required to walk it. Without it the walk yields nothing,
    // the maximum stays 0, and `current > last` is never true -- so the watcher
    // starts, builds once, and then silently never notices another change.
    var dir = std.Io.Dir.openDir(.cwd(), io, src_dir_path, .{ .iterate = true }) catch return 0;
    defer dir.close(io);

    var walker = try dir.walk(std.heap.page_allocator);
    defer walker.deinit();

    while (walker.next(io) catch null) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.basename, ".zig")) {
            const stat = dir.statFile(io, entry.path, .{}) catch continue;
            if (stat.mtime.nanoseconds > max_mtime) {
                max_mtime = stat.mtime.nanoseconds;
            }
        }
    }
    return max_mtime;
}

fn cleanStaleArtifacts(io: std.Io, lib_dir_path: []const u8) void {
    var dir = std.Io.Dir.openDir(.cwd(), io, lib_dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        // Every platform's shared library, not just Windows': Godot writes the
        // same `~` copies beside a `.so` and a `.dylib`, and a leftover blocks
        // the next load there too.
        const stale = std.mem.startsWith(u8, entry.name, "~") and
            (std.mem.endsWith(u8, entry.name, ".dll") or
                std.mem.endsWith(u8, entry.name, ".so") or
                std.mem.endsWith(u8, entry.name, ".dylib"));
        if (entry.kind == .file and stale) {
            dir.deleteFile(io, entry.name) catch continue;
            std.debug.print("[watch] Cleaned stale hot-reload artifact: {s}/{s}\n", .{ lib_dir_path, entry.name });
        }
    }
}

fn runBuild(io: std.Io) bool {
    var cwd_dir = std.Io.Dir.openDir(.cwd(), io, ".", .{}) catch return false;
    defer cwd_dir.close(io);

    var child = std.process.spawn(io, .{
        .argv = &.{ "zig", "build" },
        .cwd = .{ .dir = cwd_dir },
    }) catch return false;

    const term = child.wait(io) catch return false;
    if (term == .exited and term.exited == 0) {
        return true;
    }
    return false;
}
