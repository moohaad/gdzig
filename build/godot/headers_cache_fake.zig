//! Tiny stand-in for Godot used by the header-cache integration gate.
//!
//! Two copies are compiled with equal-length but different markers. Replacing
//! one with the other at the same filesystem path must invalidate HeadersStep.

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const args = try init.minimal.args.toSlice(arena_state.allocator());

    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--version")) {
            var buffer: [64]u8 = undefined;
            var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
            try stdout.interface.writeAll("4.7.0.stable.header-cache-test\n");
            try stdout.interface.flush();
            return;
        }
    }

    if (fixture_options.fail) {
        var buffer: [128]u8 = undefined;
        var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
        try stdout.interface.writeAll("HEADER_CACHE_FAKE_STDOUT_DIAGNOSTIC\n");
        try stdout.interface.flush();
        std.debug.print("HEADER_CACHE_FAKE_STDERR_DIAGNOSTIC\n", .{});
        std.process.exit(23);
    }

    var with_docs = false;
    var with_json = false;
    for (args[1..]) |arg| {
        with_docs = with_docs or std.mem.eql(u8, arg, "--dump-extension-api-with-docs");
        with_json = with_json or std.mem.eql(u8, arg, "--dump-gdextension-interface-json");
    }

    const marker = try std.fmt.allocPrint(
        arena_state.allocator(),
        "{s}{s}",
        .{ fixture_options.marker, if (with_docs) ":docs" else ":no-docs" },
    );
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "extension_api.json", .data = marker });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "gdextension_interface.h", .data = "fixture header\n" });
    if (with_json) {
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "gdextension_interface.json", .data = "{}\n" });
    }
}

const std = @import("std");
const fixture_options = @import("fixture_options");
