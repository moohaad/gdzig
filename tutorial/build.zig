const std = @import("std");
const gdzig = @import("gdzig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const dep = b.dependency("gdzig", .{
        .target = target,
        .optimize = optimize,
        .@"godot-path" = b.option([]const u8, "godot-path", "Godot executable"),
        .@"godot-version" = b.option([]const u8, "godot-version", "Godot version"),
        .godot_project = b.pathFromRoot("project"),
    });
    const extension = gdzig.addExtension(b, .{
        .name = "starcatcher",
        .entry_symbol = "starcatcher_init",
        .target = target,
        .optimize = optimize,
        .godot_project = "project",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "godot", .module = dep.module("gdzig") }},
        }),
    }) orelse return;
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(extension.output, .{ .custom = "../project/lib" }, extension.filename).step);
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(extension.manifest, .{ .custom = "../project" }, extension.manifest_filename).step);
    const import_project = std.Build.Step.Run.create(b, "import tutorial");
    _ = gdzig.addExportStep(b, .{ .dependency = dep, .target = target, .project = "project" });
    import_project.addFileArg(dep.namedLazyPath("godot"));
    import_project.addArgs(&.{ "--path", b.pathFromRoot("project"), "--headless", "--import" });
    import_project.step.dependOn(b.getInstallStep());
    inline for (.{ "run", "editor", "test" }) |command| {
        const run = std.Build.Step.Run.create(b, command);
        run.addFileArg(dep.namedLazyPath("godot"));
        run.addArgs(&.{ "--path", b.pathFromRoot("project") });
        if (comptime std.mem.eql(u8, command, "editor")) run.addArg("--editor");
        if (comptime std.mem.eql(u8, command, "test")) {
            run.addArgs(&.{ "--headless", "--script", "res://test_game.gd" });
        } else if (b.args) |args| run.addArgs(args);
        run.step.dependOn(&import_project.step);
        run.has_side_effects = true;
        b.step(command, "Build, import, and launch tutorial").dependOn(&run.step);
    }
}
