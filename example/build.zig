pub fn build(b: *Build) !void {
    // Options
    var target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const godot_version = b.option([]const u8, "godot-version", "Download and use this Godot version (e.g. `latest` or `4.5`)");
    const godot_path = b.option([]const u8, "godot-path", "Directory containing Godot executable [default: $PATH]");
    const single_threaded = b.option(bool, "single_threaded", "Target single threaded GdExtension [default: false]") orelse false;

    if (!single_threaded and target.result.cpu.arch.isWasm()) {
        target.query.cpu_features_add.addFeature(@intFromEnum(std.Target.wasm.Feature.atomics));
        target.query.cpu_features_add.addFeature(@intFromEnum(std.Target.wasm.Feature.bulk_memory));
    }

    // Dependencies
    const gdzig_dep = b.dependency("gdzig", .{
        .target = target,
        .optimize = optimize,
        .@"godot-version" = godot_version,
        .@"godot-path" = godot_path,
        .godot_project = b.pathFromRoot("project"),
    });

    // Extension module
    const mod = b.createModule(.{
        .root_source_file = b.path("src/example.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = single_threaded,
        .imports = &.{
            .{ .name = "godot", .module = gdzig_dep.module("gdzig") },
        },
    });

    // Extension library (handles both native and wasm)
    const extension = gdzig.addExtension(b, .{
        .name = "example",
        .root_module = mod,
        .entry_symbol = "my_extension_init",
        .target = target,
        .optimize = optimize,
        // Names every `.tscn` under the project for `Scene(@embedFile(...))`,
        // and lets gdzig preflight the project before Godot has to.
        .godot_project = "project",
    }) orelse return;

    // Install
    const install = b.addInstallFileWithDir(extension.output, .{ .custom = "../project/lib" }, extension.filename);
    b.default_step.dependOn(&install.step);

    // Run
    const run = Build.Step.Run.create(b, "run godot");
    run.addFileArg(gdzig_dep.namedLazyPath("godot"));
    run.addArg("--path");
    run.addDirectoryArg(b.path("./project"));
    // Forwarded so the example can be driven the way the demos are:
    // `zig build run -- --headless --quit-after 300`.
    if (b.args) |args| run.addArgs(args);
    run.step.dependOn(&install.step);

    const run_step = b.step("run", "Run with Godot");
    run_step.dependOn(&run.step);

    // Reload has to be driven from GDScript in editor mode: the library is
    // unloaded mid-test, so a Zig assertion goes with it, and
    // `reload_extension` refuses outside the editor.
    const reload = Build.Step.Run.create(b, "reload harness");
    reload.addFileArg(gdzig_dep.namedLazyPath("godot"));
    reload.addArg("--path");
    reload.addDirectoryArg(b.path("./project"));
    reload.addArgs(&.{ "--headless", "--editor", "--script", "res://demo/reload_driver.gd" });
    reload.step.dependOn(&install.step);

    b.step("reload-test", "Reload the extension and check what survived")
        .dependOn(&reload.step);

    // Tests
    const tests = gdzig.addTest(b, .{
        .root_module = mod,
        .target = target,
        .optimize = optimize,
    });
    b.step("test", "Run tests in Godot").dependOn(&tests.step);
}

const std = @import("std");
const Build = std.Build;

const gdzig = @import("gdzig");
