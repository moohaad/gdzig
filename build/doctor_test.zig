//! Exercises the installed `gdzig doctor` command against complete and broken
//! project trees. The fixture uses a zero-byte library: doctor verifies wiring,
//! not whether a native library can be loaded by the current process.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = init.io;

    var args = try init.minimal.args.iterateAllocator(arena);
    _ = args.next();
    const doctor_arg = args.next() orelse return fail("expected the gdzig executable path", .{});
    const fixture_path = args.next() orelse return fail("expected a fixture directory", .{});
    // Build artifact arguments are relative to the outer build root, but the
    // probe deliberately runs from inside the fixture. Resolve it before that
    // cwd change so the command tests the same invocation a user makes.
    const doctor = try std.Io.Dir.cwd().realPathFileAlloc(io, doctor_arg, arena);

    std.Io.Dir.cwd().deleteTree(io, fixture_path) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, fixture_path) catch {};
    try std.Io.Dir.createDirPath(.cwd(), io, fixture_path);

    var fixture = try std.Io.Dir.openDir(.cwd(), io, fixture_path, .{});
    defer fixture.close(io);
    try fixture.createDirPath(io, ".godot");
    try fixture.createDirPath(io, "lib");
    try fixture.writeFile(io, .{
        .sub_path = "build.zig",
        .data =
        \\const gdzig = @import("gdzig");
        \\pub fn build(b: anytype) void {
        \\    const extension = gdzig.addExtension(b, .{}) orelse return;
        \\    _ = extension.manifest;
        \\}
        \\
        ,
    });
    try fixture.writeFile(io, .{
        .sub_path = "build.zig.zon",
        .data =
        \\.{
        \\    .dependencies = .{ .gdzig = .{ .path = "../.." } },
        \\}
        \\
        ,
    });
    try fixture.writeFile(io, .{ .sub_path = "project.godot", .data = "config_version=5\n" });
    try fixture.writeFile(io, .{
        .sub_path = "game.gdextension",
        .data =
        \\[configuration]
        \\entry_symbol = "game_init"
        \\compatibility_minimum = "4.7"
        \\
        \\[libraries]
        \\windows.debug.x86_64 = "lib/game.bin"
        \\linux.debug.x86_64 = "lib/game.bin"
        \\macos.debug.x86_64 = "lib/game.bin"
        \\macos.debug.arm64 = "lib/game.bin"
        \\bsd.debug.x86_64 = "lib/game.bin"
        \\
        ,
    });
    try fixture.writeFile(io, .{ .sub_path = ".godot/extension_list.cfg", .data = "res://game.gdextension\n" });
    try fixture.writeFile(io, .{ .sub_path = "lib/game.bin", .data = "" });

    var output: std.ArrayList(u8) = .empty;
    try run(io, arena, fixture_path, &.{ doctor, "doctor" }, true, &output);
    if (std.mem.indexOf(u8, output.items, "0 failures") == null or
        std.mem.indexOf(u8, output.items, "points to existing library") == null)
    {
        return fail("healthy project was not reported healthy:\n{s}", .{output.items});
    }

    try fixture.deleteFile(io, "lib/game.bin");
    try fixture.writeFile(io, .{ .sub_path = ".godot/extension_list.cfg", .data = "res://other.gdextension\n" });
    output.clearRetainingCapacity();
    try run(io, arena, fixture_path, &.{ doctor, "doctor" }, false, &output);
    if (std.mem.indexOf(u8, output.items, "points to missing library") == null or
        std.mem.indexOf(u8, output.items, "import list omits res://game.gdextension") == null)
    {
        return fail("broken project did not report both wiring failures:\n{s}", .{output.items});
    }

    std.debug.print("gdzig doctor: healthy and broken project diagnostics verified\n", .{});
}

fn run(
    io: std.Io,
    allocator: std.mem.Allocator,
    cwd_path: []const u8,
    argv: []const []const u8,
    should_succeed: bool,
    output: *std.ArrayList(u8),
) !void {
    var cwd = try std.Io.Dir.openDir(.cwd(), io, cwd_path, .{});
    defer cwd.close(io);
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .dir = cwd },
        .stderr = .pipe,
    });
    var buffer: [4096]u8 = undefined;
    var reader = child.stderr.?.readerStreaming(io, &buffer);
    const text = try reader.interface.allocRemaining(allocator, .limited(1 << 20));
    try output.appendSlice(allocator, text);
    const term = try child.wait(io);
    const succeeded = term == .exited and term.exited == 0;
    if (succeeded != should_succeed) {
        return fail("doctor success={any}, expected {any}:\n{s}", .{ succeeded, should_succeed, output.items });
    }
}

fn fail(comptime format: []const u8, args: anytype) error{DoctorCheckFailed} {
    std.debug.print("doctor test: " ++ format ++ "\n", args);
    return error.DoctorCheckFailed;
}
