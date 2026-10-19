const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 5) return error.InvalidArguments;
    const executable = try std.Io.Dir.cwd().realPathFileAlloc(io, args[1], arena);
    const output_path = std.fs.path.dirname(args[3]) orelse ".";
    var output = try std.Io.Dir.cwd().createDirPathOpen(io, output_path, .{});
    defer output.close(io);
    var engine = try std.Io.Dir.cwd().openFile(io, executable, .{});
    defer engine.close(io);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(args[2]);
    // Include the wrapper's own version so changes to dump flags invalidate it.
    hash.update("gdzig-headers-v1");
    var buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const n = engine.readStreaming(io, &.{&buffer}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (n == 0) break;
        hash.update(buffer[0..n]);
    }
    const identity = std.fmt.bytesToHex(hash.finalResult(), .lower);
    const cached_identity = output.readFileAlloc(io, "identity", arena, .limited(64)) catch "";
    if (std.mem.eql(u8, cached_identity, &identity)) {
        if (output.statFile(io, "extension_api.json", .{})) |_| {
            if (output.statFile(io, "gdextension_interface.h", .{})) |_| return else |_| {}
        } else |_| {}
    }
    // Failed or partial dumps must never inherit a previous success marker.
    output.deleteFile(io, "identity") catch {};
    inline for (.{ "extension_api.json", "gdextension_interface.h" }) |name| {
        output.deleteFile(io, name) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }
    const result = try std.process.run(arena, io, .{
        .argv = &.{ executable, if (std.mem.eql(u8, args[2], "docs")) "--dump-extension-api-with-docs" else "--dump-extension-api", "--dump-gdextension-interface", "--headless", "--quit" },
        .cwd = .{ .dir = output },
        .stdout_limit = .limited(16 << 20),
        .stderr_limit = .limited(16 << 20),
    });
    if (!result.term.success()) {
        switch (result.term) {
            .exited => |status| std.debug.print("Godot exited with status {d}\n", .{status}),
            else => std.debug.print("Godot terminated: {any}\n", .{result.term}),
        }
        std.debug.print("Godot stdout:\n{s}\nGodot stderr:\n{s}\n", .{ result.stdout, result.stderr });
        std.process.exit(1);
    }
    // Check required outputs before the Run step can cache a successful dump.
    _ = try output.statFile(io, "extension_api.json", .{});
    _ = try output.statFile(io, "gdextension_interface.h", .{});
    try output.writeFile(io, .{ .sub_path = "identity", .data = &identity });
}
