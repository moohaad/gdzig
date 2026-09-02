//! Proves that HeadersStep invalidates when an executable is replaced in place
//! and when the dump flags change, and preserves diagnostics when Godot fails.

pub fn main(init: std.process.Init) !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 6) return fail("expected v1, v2, failing fixture, HeadersStep source, and output paths", .{});
    const fake_v1 = args[1];
    const fake_v2 = args[2];
    const fake_fail = args[3];
    const headers_source = args[4];
    const out_path = args[5];

    std.Io.Dir.cwd().deleteTree(io, out_path) catch {};
    var out = try std.Io.Dir.cwd().createDirPathOpen(io, out_path, .{});
    defer out.close(io);

    const fake_name = if (builtin.os.tag == .windows) "fake-godot.exe" else "fake-godot";
    try std.Io.Dir.cwd().copyFile(fake_v1, out, fake_name, io, .{});
    try std.Io.Dir.cwd().copyFile(headers_source, out, "HeadersStep.zig", io, .{});
    try writeBuild(io, out, fake_name, false);
    try runBuild(io, out_path);
    try expectDump(io, arena, out, "v1:docs");

    // Same path and same-size marker, different executable contents.
    try std.Io.Dir.cwd().copyFile(fake_v2, out, fake_name, io, .{ .replace = true });
    try runBuild(io, out_path);
    try expectDump(io, arena, out, "v2:docs");

    // Same executable and path, different dump flags.
    try writeBuild(io, out, fake_name, true);
    try runBuild(io, out_path);
    try expectDump(io, arena, out, "v2:no-docs");

    // A manifest can outlive its output directory. Remove one required source
    // file and its installed copy; the next build must regenerate both rather
    // than returning the now-incomplete cached directory.
    try deleteCachedDump(io, arena, out, "v2:no-docs");
    try out.deleteFile(io, "zig-out/headers/extension_api.json");
    try runBuild(io, out_path);
    try expectDump(io, arena, out, "v2:no-docs");

    // A failed engine invocation must retain its status and both diagnostic
    // streams in the build failure instead of reducing it to a generic error.
    try std.Io.Dir.cwd().copyFile(fake_fail, out, fake_name, io, .{ .replace = true });
    try writeBuild(io, out, fake_name, false);
    try expectBuildFailureDiagnostics(io, arena, out_path);

    std.debug.print("headers cache: invalidation works and Godot diagnostics survive failures\n", .{});
}

fn writeBuild(io: std.Io, out: std.Io.Dir, fake_name: []const u8, force_no_docs: bool) !void {
    const invocation = if (force_no_docs)
        try std.fmt.allocPrint(
            std.heap.page_allocator,
            "HeadersStep.createWithFlags(b, b.path(\"{s}\"), .{{ .use_docs = false, .has_json = false }})",
            .{fake_name},
        )
    else
        try std.fmt.allocPrint(
            std.heap.page_allocator,
            "HeadersStep.create(b, b.path(\"{s}\"))",
            .{fake_name},
        );
    defer std.heap.page_allocator.free(invocation);
    const source = try std.fmt.allocPrint(std.heap.page_allocator,
        \\const std = @import("std");
        \\const HeadersStep = @import("HeadersStep.zig");
        \\
        \\pub fn build(b: *std.Build) void {{
        \\    const headers = {s};
        \\    const install = b.addInstallDirectory(.{{
        \\        .source_dir = headers.getDirectory(),
        \\        .install_dir = .prefix,
        \\        .install_subdir = "headers",
        \\    }});
        \\    b.getInstallStep().dependOn(&install.step);
        \\}}
        \\
    , .{invocation});
    defer std.heap.page_allocator.free(source);
    try out.writeFile(io, .{ .sub_path = "build.zig", .data = source });
}

fn runBuild(io: std.Io, cwd_path: []const u8) !void {
    var cwd = try std.Io.Dir.openDir(.cwd(), io, cwd_path, .{});
    defer cwd.close(io);

    var child = try std.process.spawn(io, .{
        .argv = &.{ "zig", "build", "--summary", "none" },
        .cwd = .{ .dir = cwd },
        .stderr = .inherit,
        .stdout = .inherit,
    });
    const term = try child.wait(io);
    if (term != .exited or term.exited != 0) return fail("nested header build failed", .{});
}

fn expectBuildFailureDiagnostics(io: std.Io, arena: std.mem.Allocator, cwd_path: []const u8) !void {
    const output = try std.process.run(arena, io, .{
        .argv = &.{ "zig", "build", "--summary", "none" },
        .cwd = .{ .path = cwd_path },
        .stdout_limit = .limited(4 << 20),
        .stderr_limit = .limited(4 << 20),
    });
    if (output.term == .exited and output.term.exited == 0) {
        return fail("nested header build unexpectedly succeeded", .{});
    }

    const expected = [_][]const u8{
        "exited with status 23",
        "HEADER_CACHE_FAKE_STDOUT_DIAGNOSTIC",
        "HEADER_CACHE_FAKE_STDERR_DIAGNOSTIC",
    };
    for (expected) |needle| {
        if (std.mem.indexOf(u8, output.stdout, needle) == null and
            std.mem.indexOf(u8, output.stderr, needle) == null)
        {
            return fail(
                "missing '{s}' in nested build diagnostics\n--- stdout ---\n{s}\n--- stderr ---\n{s}",
                .{ needle, output.stdout, output.stderr },
            );
        }
    }
}

fn expectDump(io: std.Io, arena: std.mem.Allocator, out: std.Io.Dir, expected: []const u8) !void {
    const actual = try out.readFileAlloc(io, "zig-out/headers/extension_api.json", arena, @enumFromInt(1024));
    if (!std.mem.eql(u8, actual, expected)) {
        return fail("expected header marker '{s}', got '{s}'", .{ expected, actual });
    }
}

fn deleteCachedDump(io: std.Io, arena: std.mem.Allocator, out: std.Io.Dir, expected: []const u8) !void {
    var objects = try out.openDir(io, ".zig-cache/o", .{ .iterate = true });
    defer objects.close(io);

    var entries = objects.iterate();
    while (try entries.next(io)) |entry| {
        if (entry.kind == .file) continue;
        var object = objects.openDir(io, entry.name, .{}) catch continue;
        defer object.close(io);

        const actual = object.readFileAlloc(io, "extension_api.json", arena, @enumFromInt(1024)) catch continue;
        if (!std.mem.eql(u8, actual, expected)) continue;
        try object.deleteFile(io, "extension_api.json");
        return;
    }
    return fail("could not find cached header marker '{s}' to remove", .{expected});
}

fn fail(comptime format: []const u8, args: anytype) error{HeaderCacheTestFailed} {
    std.debug.print("header cache test: " ++ format ++ "\n", args);
    return error.HeaderCacheTestFailed;
}

const std = @import("std");
const builtin = @import("builtin");
