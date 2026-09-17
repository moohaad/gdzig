const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    var args = try init.minimal.args.iterateAllocator(a);
    _ = args.next();
    _ = args.next();
    var project: []const u8 = ".";
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help")) {
            std.debug.print("Usage: gdzig setup-editor [--project <Godot directory>]\nInstalls addons/gdzig without overwriting it. Enable gdzig in Project Settings > Plugins.\n", .{});
            return;
        } else if (std.mem.eql(u8, arg, "--project")) {
            project = args.next() orelse return error.MissingProject;
        } else return error.UnknownArgument;
    }
    var dir = try std.Io.Dir.cwd().openDir(init.io, project, .{});
    defer dir.close(init.io);
    _ = try dir.statFile(init.io, "project.godot", .{});
    try install(dir, init.io);
    std.debug.print("Installed addons/gdzig. Enable gdzig in Project Settings > Plugins. No commands run automatically.\n", .{});
}

pub fn install(project: std.Io.Dir, io: std.Io) !void {
    try project.createDirPath(io, "addons");
    // Exclusive directory creation protects an existing installation, including
    // user changes. Roll back only the directory this call created.
    try project.createDir(io, "addons/gdzig", .default_dir);
    errdefer project.deleteTree(io, "addons/gdzig") catch {};
    inline for (.{ "plugin.cfg", "plugin.gd", "process.gd", "diagnostics.gd", "zig_highlighter.gd" }) |name| {
        try project.writeFile(io, .{ .sub_path = "addons/gdzig/" ++ name, .data = @embedFile("editor/" ++ name) });
    }
}
