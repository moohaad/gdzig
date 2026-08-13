pub const BuildOptions = struct {
    target: Build.ResolvedTarget,
    optimize: OptimizeMode,
};

pub fn build(b: *Build, options: BuildOptions) *Build.Step.Compile {
    const target = options.target;
    const optimize = options.optimize;

    const casez = b.dependency("casez", .{ .target = target, .optimize = optimize });

    const common_mod = common.build(b, .{
        .target = target,
        .optimize = optimize,
        .casez = casez.module("casez"),
    });

    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("pkg/apiaudit/main.zig"),
        .imports = &.{
            .{ .name = "casez", .module = casez.module("casez") },
            .{ .name = "common", .module = common_mod },
        },
    });

    return b.addExecutable(.{
        .name = "gdzig-api-audit",
        .root_module = mod,
    });
}

const std = @import("std");
const Build = std.Build;
const OptimizeMode = std.builtin.OptimizeMode;

const common = @import("common.zig");
