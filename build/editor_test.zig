const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;
    var args = try init.minimal.args.iterateAllocator(a);
    _ = args.next();
    const cli = try std.Io.Dir.cwd().realPathFileAlloc(io, args.next().?, a);
    const godot = try std.Io.Dir.cwd().realPathFileAlloc(io, args.next().?, a);
    const fixture_path = args.next().?;
    try std.Io.Dir.cwd().createDirPath(io, fixture_path);
    defer std.Io.Dir.cwd().deleteTree(io, fixture_path) catch {};
    var fixture = try std.Io.Dir.cwd().openDir(io, fixture_path, .{});
    defer fixture.close(io);
    try fixture.createDirPath(io, "game/.godot");
    try fixture.writeFile(io, .{ .sub_path = "build.zig", .data =
        \\const std = @import("std");
        \\pub fn build(b: *std.Build) void {
        \\    _ = b.option([]const u8, "godot-path", "Godot executable") orelse @panic("editor did not select Godot");
        \\    const files = b.addWriteFiles();
        \\    _ = files.add("editor-build-probe", "success");
        \\    b.default_step.dependOn(&files.step);
        \\}
        \\
    });
    try fixture.createDirPath(io, "src");
    // The pre-current scaffold called this tuple `nodes`; the editor generator
    // must support it without requiring users to rewrite a valid entry point.
    try fixture.writeFile(io, .{ .sub_path = "src/main.zig", .data = "const nodes = .{};\npub fn register(r: anytype) void { r.registerAll(nodes); }\npub fn unregister(r: anytype) void { r.unregisterAll(nodes); }\n" });
    try fixture.writeFile(io, .{ .sub_path = "game/project.godot", .data = "config_version=5\n[application]\nconfig/name=\"Editor integration test\"\n[editor_plugins]\nenabled=PackedStringArray(\"res://addons/gdzig/plugin.cfg\", \"res://addons/test_driver/plugin.cfg\")\n[rendering]\nrenderer/rendering_method=\"gl_compatibility\"\n" });
    try command(io, &.{ cli, "-C", fixture_path, "setup-editor", "--project", "game" }, true);
    const plugin_before = try fixture.readFileAlloc(io, "game/addons/gdzig/plugin.gd", a, .limited(1 << 20));
    try command(io, &.{ cli, "-C", fixture_path, "setup-editor", "--project", "game" }, false);
    const plugin_after = try fixture.readFileAlloc(io, "game/addons/gdzig/plugin.gd", a, .limited(1 << 20));
    if (!std.mem.eql(u8, plugin_before, plugin_after)) return error.OverwroteAddon;
    // Godot config uses slash paths on every host.
    const cli_config = try a.dupe(u8, cli);
    std.mem.replaceScalar(u8, cli_config, '\\', '/');
    const root = try fixture.realPathFileAlloc(io, ".", a);
    std.mem.replaceScalar(u8, root, '\\', '/');
    try fixture.writeFile(io, .{ .sub_path = "game/.godot/gdzig-editor.cfg", .data = try std.fmt.allocPrint(a, "[tools]\nexecutable=\"{s}\"\nbuild_root=\"{s}\"\n", .{ cli_config, root }) });
    try fixture.createDirPath(io, "game/addons/test_driver");
    try fixture.writeFile(io, .{ .sub_path = "game/addons/test_driver/plugin.cfg", .data = "[plugin]\nname=\"test driver\"\ndescription=\"test\"\nauthor=\"gdzig\"\nversion=\"1\"\nscript=\"plugin.gd\"\n" });
    try fixture.writeFile(io, .{ .sub_path = "game/addons/test_driver/plugin.gd", .data = @embedFile("editor/test_driver.gd") });
    try fixture.writeFile(io, .{ .sub_path = "game/test_job.gd", .data = @embedFile("editor/test_job.gd") });
    try command(io, &.{ godot, "--headless", "--editor", "--path", try std.fs.path.join(a, &.{ root, "game" }), "--max-fps", "60", "--quit-after", "12000" }, true);
    const result = try fixture.readFileAlloc(io, "game/.godot/gdzig-test-result", a, .limited(100));
    if (!std.mem.eql(u8, result, "0")) return error.EditorTestsDidNotPass;
}

fn command(io: std.Io, argv: []const []const u8, success: bool) !void {
    var child = try std.process.spawn(io, .{ .argv = argv });
    defer child.kill(io);
    const term = try child.wait(io);
    if ((term == .exited and term.exited == 0) != success) return error.UnexpectedExit;
}
