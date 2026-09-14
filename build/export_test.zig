const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;
    var args = try init.minimal.args.iterateAllocator(a);
    const self_arg = args.next().?;
    const first = args.next().?;
    // A deterministic fake editor, including a failure diagnostic on stderr.
    if (std.mem.eql(u8, first, "--headless")) {
        if (!std.mem.eql(u8, args.next().?, "--path")) return error.BadCommand;
        var project = try std.Io.Dir.cwd().openDir(io, args.next().?, .{});
        defer project.close(io);
        const phase = args.next().?;
        const scenario = try project.readFileAlloc(io, "scenario", a, .limited(100));
        if (std.mem.eql(u8, phase, "--import")) {
            if (std.mem.eql(u8, scenario, "import-fail")) {
                std.debug.print("fixture import diagnostic\n", .{});
                std.process.exit(7);
            }
            try project.writeFile(io, .{ .sub_path = "imported", .data = "yes" });
            return;
        }
        _ = try project.statFile(io, "imported", .{});
        if (!std.mem.eql(u8, phase, "--export-release") and !std.mem.eql(u8, phase, "--export-debug")) return error.BadMode;
        if (!std.mem.eql(u8, args.next().?, "Desktop With Spaces")) return error.BadPreset;
        const output = args.next().?;
        if (!std.fs.path.isAbsolute(output)) return error.RelativeOutput;
        if (std.mem.eql(u8, scenario, "export-fail")) {
            std.debug.print("fixture template diagnostic\n", .{});
            std.process.exit(9);
        }
        if (!std.mem.eql(u8, scenario, "no-output")) try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = output, .data = "export fixture" });
        return;
    }
    const runner = try std.Io.Dir.cwd().realPathFileAlloc(io, first, a);
    const self = try std.Io.Dir.cwd().realPathFileAlloc(io, self_arg, a);
    const fixture_path = args.next().?;
    try std.Io.Dir.cwd().createDirPath(io, fixture_path);
    var fixture = try std.Io.Dir.cwd().openDir(io, fixture_path, .{});
    defer fixture.close(io);
    // All fixtures are confined to the dedicated build-cache test directory.
    defer std.Io.Dir.cwd().deleteTree(io, fixture_path) catch {};
    for ([_][]const u8{ "ok", "debug", "import-fail", "export-fail", "no-output", "stale", "inside" }) |scenario| {
        const project = try std.fs.path.join(a, &.{ fixture_path, scenario, "project" });
        const output = try std.fs.path.join(a, &.{ fixture_path, scenario, if (std.mem.eql(u8, scenario, "inside")) "project/out/game.exe" else "out with spaces/game.exe" });
        try std.Io.Dir.cwd().createDirPath(io, project);
        var dir = try std.Io.Dir.cwd().openDir(io, project, .{});
        defer dir.close(io);
        try dir.writeFile(io, .{ .sub_path = "project.godot", .data = "config_version=5" });
        try dir.writeFile(io, .{ .sub_path = "scenario", .data = scenario });
        try dir.writeFile(io, .{ .sub_path = "export_presets.cfg", .data = "[preset.0]\nname=\"Desktop With Spaces\"\nplatform=\"Windows Desktop\"\n[preset.0.options]\nbinary_format/architecture=\"x86_64\"\n" });
        if (std.mem.eql(u8, scenario, "stale")) {
            try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(output).?);
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = output, .data = "preserve" });
        }
        var child = try std.process.spawn(io, .{
            .argv = &.{ runner, self, project, "windows", "x86_64", "native", "--preset", "Desktop With Spaces", "--output", output, if (std.mem.eql(u8, scenario, "debug")) "--debug" else "--release" },
            .stderr = .pipe,
        });
        var buffer: [4096]u8 = undefined;
        var reader = child.stderr.?.readerStreaming(io, &buffer);
        const diagnostic = try reader.interface.allocRemaining(a, .limited(1 << 20));
        const term = try child.wait(io);
        const expected_success = std.mem.eql(u8, scenario, "ok") or std.mem.eql(u8, scenario, "debug");
        if ((term == .exited and term.exited == 0) != expected_success) {
            std.debug.print("scenario {s}: {s}\n", .{ scenario, diagnostic });
            return error.WrongResult;
        }
        if (std.mem.eql(u8, scenario, "import-fail") and std.mem.indexOf(u8, diagnostic, "fixture import diagnostic") == null) return error.LostDiagnostic;
        if (std.mem.eql(u8, scenario, "export-fail") and std.mem.indexOf(u8, diagnostic, "fixture template diagnostic") == null) return error.LostDiagnostic;
        if (std.mem.eql(u8, scenario, "stale")) {
            const contents = try std.Io.Dir.cwd().readFileAlloc(io, output, a, .limited(100));
            if (!std.mem.eql(u8, contents, "preserve")) return error.OverwroteOutput;
        }
    }
    std.debug.print("Export process tests passed (7 scenarios).\n", .{});
}
