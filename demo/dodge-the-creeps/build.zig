pub fn build(b: *Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const godot_version = b.option([]const u8, "godot-version", "Download and use this Godot version");
    const godot_path = b.option([]const u8, "godot-path", "Path to a Godot executable");

    const gdzig_dep = b.dependency("gdzig", .{
        .target = target,
        .optimize = optimize,
        .@"godot-version" = godot_version,
        .@"godot-path" = godot_path,
    });

    const mod = b.createModule(.{
        .root_source_file = b.path("src/dodge.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "godot", .module = gdzig_dep.module("gdzig") },
        },
    });

    const extension = gdzig.addExtension(b, .{
        .name = "dodge",
        .root_module = mod,
        .entry_symbol = "dodge_the_creeps_init",
        .target = target,
        .optimize = optimize,
        // Makes every scene under `godot/` embeddable by name, which is what
        // `Scene(@embedFile("Player.tscn"))` in Hud.zig and Player.zig needs.
        .godot_project = "godot",
    }) orelse return;

    const install = b.addInstallFileWithDir(extension.output, .{ .custom = "../godot/lib" }, extension.filename);
    b.default_step.dependOn(&install.step);

    const run = Build.Step.Run.create(b, "run godot");
    run.addFileArg(gdzig_dep.namedLazyPath("godot"));
    run.addArg("--path");
    run.addDirectoryArg(b.path("./godot"));
    if (b.args) |args| run.addArgs(args);
    run.step.dependOn(&install.step);

    b.step("run", "Run the game with Godot").dependOn(&run.step);
}

const std = @import("std");
const Build = std.Build;

const gdzig = @import("gdzig");
