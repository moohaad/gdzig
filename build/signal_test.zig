//! Checks that connecting a handler whose signature does not match the signal
//! is a compile error, and that a matching one is not.
//!
//! `assertSignalSignature` runs at the four points in `Object.mixin` where a
//! connection is made, and its whole job is to fail. That cannot be asserted
//! from a normal test, so this drives builds that are *expected* to fail and
//! reads the messages back -- the same shape as the `res://` check.
//!
//! Three cases rather than two. The accepting one alone would still pass with
//! the assertion deleted, and the two rejecting ones cover branches that can rot
//! independently: counting the arguments and checking their types are separate
//! code.
//!
//! The receiver has to be one of your own classes. `connect` resolves the
//! handler against the receiver type's public declarations, so an engine
//! pointer would fail on *that* rather than on the signature, and the test would
//! pass while proving nothing.

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

    const name = "sigprobe";
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

    const entry = try std.fmt.allocPrint(arena, "src/{s}.zig", .{name});

    // The signal carries one `i64`, so this handler matches it.
    try dir.writeFile(io, .{ .sub_path = entry, .data = try probe(arena, "i64") });
    run(io, out_path, &.{ "zig", "build" }, null) catch {
        return fail("a handler matching its signal failed to compile", .{});
    };

    try rejects(io, arena, dir, entry, out_path, null, "argument count mismatch");
    try rejects(io, arena, dir, entry, out_path, "f64", "type mismatch");

    std.debug.print("signals: matching handler accepted, mismatched handlers rejected\n", .{});
}

/// Requires a probe whose handler takes `arg` to fail the build with `wanted`
/// somewhere in the output.
fn rejects(
    io: std.Io,
    arena: std.mem.Allocator,
    dir: std.Io.Dir,
    entry: []const u8,
    out_path: []const u8,
    arg: ?[]const u8,
    wanted: []const u8,
) !void {
    try dir.writeFile(io, .{ .sub_path = entry, .data = try probe(arena, arg) });

    var output: std.ArrayList(u8) = .empty;
    if (run(io, out_path, &.{ "zig", "build" }, &output)) |_| {
        return fail("a handler that does not match its signal compiled anyway (expected '{s}')", .{wanted});
    } else |_| {}

    if (std.mem.indexOf(u8, output.items, wanted) == null) {
        return fail("the build failed, but not with '{s}'; got:\n{s}", .{ wanted, output.items });
    }
}

/// An extension entry whose class connects a handler to a signal carrying one
/// `i64`. `arg` is the handler's own argument type, or null for no argument at
/// all, which is the count mismatch.
fn probe(arena: std.mem.Allocator, arg: ?[]const u8) ![]const u8 {
    const param = if (arg) |t| try std.fmt.allocPrint(arena, ", a: {s}", .{t}) else "";
    const discard = if (arg == null) "" else " _ = a; ";

    return std.fmt.allocPrint(arena,
        \\const Probe = struct {{
        \\    allocator: std.mem.Allocator,
        \\    base: *godot.class.Node,
        \\
        \\    pub const Ping = struct {{ value: i64 }};
        \\
        \\    pub fn onPing(_: *Probe{s}) void {{{s}}}
        \\}};
        \\
        \\// Never runs: the build is the assertion. `connect` checks the handler
        \\// against the signal at comptime, which is what is on trial. The pointer
        \\// is fabricated rather than `undefined`, which Zig rejects as illegal
        \\// behaviour even on a path that is only ever compiled.
        \\fn wire(p: *Probe) void {{
        \\    p.base.connect(Probe.Ping, p, &Probe.onPing);
        \\}}
        \\
        \\pub fn register(r: *godot.extension.Registry) void {{
        \\    r.autoRegister(Probe);
        \\    wire(@ptrFromInt(@alignOf(Probe)));
        \\}}
        \\
        \\const std = @import("std");
        \\const godot = @import("godot");
        \\
    , .{ param, discard });
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

fn fail(comptime fmt: []const u8, args: anytype) error{SignalCheckFailed} {
    std.debug.print("signal test: " ++ fmt ++ "\n", args);
    return error.SignalCheckFailed;
}

const std = @import("std");
