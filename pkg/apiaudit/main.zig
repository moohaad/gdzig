//! Auditing tools for Godot's `extension_api.json`.
//!
//! Two subcommands:
//!
//!   diff <old.json> <new.json>
//!       Reports how the *shape* of the API changed between two dumps: fields
//!       gained, lost, or whose value kind differs. This is what finds the
//!       class of defect that blocked Godot 4.7, where `global_constants` went
//!       from always-empty to populated and a field bindgen typed as a string
//!       started arriving as a number.
//!
//!   coverage <extension_api.json> <test-dir>...
//!       Reports how much of the generated surface the tests actually exercise,
//!       broken down by category, so the untouched areas are visible.
//!
//! Both read the dump dynamically rather than through `GodotApi`, which is the
//! point: a typed parse can only see fields the model already knows about, and
//! the interesting changes are the ones it does not.

const std = @import("std");
const Io = std.Io;

const diff = @import("diff.zig");
const coverage = @import("coverage.zig");

const usage =
    \\usage: api-audit diff <old.json> <new.json>
    \\       api-audit coverage <extension_api.json> <test-dir>...
    \\
;

pub fn main(init: std.process.Init) !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    var stdout_buf: [8192]u8 = undefined;
    var stdout_writer = Io.File.stdout().writerStreaming(io, &stdout_buf);
    const out = &stdout_writer.interface;
    defer out.flush() catch {};

    if (args.len < 3) {
        try out.writeAll(usage);
        try out.flush();
        std.process.exit(2);
    }

    const command = args[1];
    const result = blk: {
        if (std.mem.eql(u8, command, "diff")) {
            if (args.len != 4) {
                try out.writeAll(usage);
                try out.flush();
                std.process.exit(2);
            }
            break :blk diff.run(arena, io, out, args[2], args[3]);
        } else if (std.mem.eql(u8, command, "coverage")) {
            break :blk coverage.run(arena, io, out, args[2], args[3..]);
        } else {
            try out.print("unknown command '{s}'\n\n{s}", .{ command, usage });
            try out.flush();
            std.process.exit(2);
        }
    };

    // A refused diff is a normal outcome for a tool like this, and the reason
    // has already been printed. Reporting it as an unhandled error would bury
    // that message under a stack trace.
    result catch |err| switch (err) {
        error.SameVersion, error.MismatchedDumpFlags, error.NoSources => {
            try out.flush();
            std.process.exit(1);
        },
        else => return err,
    };
}

/// Reads a whole file through the `Io` interface.
pub fn readFile(arena: std.mem.Allocator, io: Io, path: []const u8) ![]u8 {
    var file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    const size = (try file.stat(io)).size;
    const buf = try arena.alloc(u8, @intCast(size));

    var read_buf: [64 * 1024]u8 = undefined;
    var reader = file.reader(io, &read_buf);
    try reader.interface.readSliceAll(buf);
    return buf;
}
