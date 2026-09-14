const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    var args = try init.minimal.args.iterateAllocator(allocator);
    _ = args.next();
    const command = args.next() orelse return usage();
    if (std.mem.eql(u8, command, "-C")) {
        const path = args.next() orelse return error.MissingBuildDirectory;
        var cwd = try std.Io.Dir.cwd().openDir(init.io, path, .{});
        defer cwd.close(init.io);
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.append(allocator, try std.process.executablePathAlloc(init.io, allocator));
        while (args.next()) |arg| try argv.append(allocator, arg);
        var child = try std.process.spawn(init.io, .{ .argv = argv.items, .cwd = .{ .dir = cwd } });
        defer child.kill(init.io);
        const term = try child.wait(init.io);
        std.process.exit(if (term == .exited) term.exited else 1);
    }
    if (std.mem.eql(u8, command, "setup-editor")) {
        @import("setup_editor.zig").main(init) catch |err| {
            std.debug.print("gdzig setup-editor: {s}. Existing addons are not overwritten.\n", .{@errorName(err)});
            std.process.exit(1);
        };
        return;
    }
    if (std.mem.eql(u8, command, "init")) return @import("init.zig").main(init);
    if (std.mem.eql(u8, command, "add")) {
        @import("add.zig").main(init) catch |err| {
            std.debug.print("gdzig add: {s}. See gdzig add --help.\n", .{@errorName(err)});
            std.process.exit(1);
        };
        return;
    }
    if (std.mem.eql(u8, command, "doctor")) return @import("doctor.zig").main(init);
    if (std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) return usage();
    const watch = std.mem.eql(u8, command, "watch");
    const exporting = std.mem.eql(u8, command, "export");
    const build = std.mem.eql(u8, command, "build");
    if (!build and !watch and !exporting and !std.mem.eql(u8, command, "run") and !std.mem.eql(u8, command, "editor")) {
        std.debug.print("Unknown command: {s}\n", .{command});
        std.process.exit(2);
    }
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(allocator, &.{ "zig", "build" });
    if (!build) try argv.append(allocator, command);
    var build_args: std.ArrayList([]const u8) = .empty;
    var export_args: std.ArrayList([]const u8) = .empty;
    var separator = false;
    var has_optimize = false;
    while (args.next()) |arg| {
        if (exporting) {
            if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) return @import("export.zig").usage();
            if (!separator and std.mem.eql(u8, arg, "--")) {
                separator = true;
                continue;
            }
            if (separator) {
                try export_args.append(allocator, arg);
                continue;
            }
            if (std.mem.startsWith(u8, arg, "-Doptimize=")) has_optimize = true;
        }
        if (watch and std.mem.eql(u8, arg, "--")) {
            std.debug.print("watch accepts build options only; use run/editor -- <Godot arguments>\n", .{});
            std.process.exit(2);
        }
        try argv.append(allocator, arg);
        if (watch) try build_args.append(allocator, arg);
    }
    if (exporting) {
        _ = @import("export.zig").parse(export_args.items) catch |err| {
            std.debug.print("gdzig export: {s}\n", .{@errorName(err)});
            @import("export.zig").usage();
            std.process.exit(2);
        };
        if (!has_optimize) try argv.append(allocator, "-Doptimize=ReleaseSafe");
        try argv.append(allocator, "--");
        try argv.appendSlice(allocator, export_args.items);
    }
    // The outer build selects the engine. Every nested watcher rebuild must
    // receive the same options, including target, optimization, and engine.
    if (watch) {
        try argv.append(allocator, "--");
        try argv.appendSlice(allocator, build_args.items);
    }
    var child = try std.process.spawn(init.io, .{ .argv = argv.items });
    defer child.kill(init.io);
    const term = try child.wait(init.io);
    std.process.exit(if (term == .exited) term.exited else 1);
}

fn usage() void {
    std.debug.print(
        \\Usage: gdzig [-C <build-directory>] <command> [options]
        \\  setup-editor Install the optional Godot editor panel
        \\  init       Create a project: gdzig init --out mygame --name mygame
        \\  add        Generate and register a node, resource, or editor plugin
        \\  build      Build the extension (forwards options to zig build)
        \\  run        Build, import, and run the project
        \\  editor     Build, import, and open the editor
        \\  watch      Watch sources and rebuild with the same build options
        \\  export     Build and export a desktop game; see gdzig export --help
        \\  doctor     Diagnose local setup; see gdzig doctor --help
        \\
        \\Run build/run/editor/watch beside build.zig. Launch commands use project
        \\build steps generated by gdzig init. Older projects must add those steps.
        \\Example: gdzig run -Dgodot-version=4.7 -- --headless --quit
        \\
    , .{});
}
