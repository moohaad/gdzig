//! Desktop export runner. Godot remains authoritative for template/signing checks.
const std = @import("std");

pub const Options = struct {
    preset: []const u8,
    output: []const u8,
    mode: []const u8 = "--export-release",
};

pub fn parse(args: []const []const u8) !Options {
    var preset: ?[]const u8 = null;
    var output: ?[]const u8 = null;
    var mode: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--debug") or std.mem.eql(u8, arg, "--release")) {
            if (mode != null) return error.DuplicateMode;
            mode = if (std.mem.eql(u8, arg, "--debug")) "--export-debug" else "--export-release";
        } else if (std.mem.eql(u8, arg, "--preset") or std.mem.eql(u8, arg, "--output")) {
            i += 1;
            if (i == args.len or args[i].len == 0 or std.mem.startsWith(u8, args[i], "--")) return error.MissingValue;
            const slot = if (std.mem.eql(u8, arg, "--preset")) &preset else &output;
            if (slot.* != null) return error.DuplicateOption;
            slot.* = args[i];
        } else return error.UnknownOption;
    }
    return .{ .preset = preset orelse return error.MissingPreset, .output = output orelse return error.MissingOutput, .mode = mode orelse "--export-release" };
}

pub fn usage() void {
    std.debug.print(
        \\Usage: gdzig export [Zig build options] -- --preset <name> --output <file> [--debug|--release]
        \\Default: release export, ReleaseSafe extension (CLI only). Use -Doptimize=Debug for a debug extension.
        \\Configure a desktop preset in Godot and install its matching export templates first.
        \\Output is relative to the build directory, in an empty directory outside the Godot project.
        \\Only host-native desktop targets are supported. Existing output is never replaced.
        \\
    , .{});
}

pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        std.debug.print("gdzig export: {s}. Run gdzig export --help for usage.\n", .{@errorName(err)});
        std.process.exit(1);
    };
}

fn run(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;
    var iter = try init.minimal.args.iterateAllocator(a);
    _ = iter.next();
    const engine = iter.next() orelse return error.MissingEngine;
    const project_arg = iter.next() orelse return error.MissingProject;
    const platform = iter.next() orelse return error.MissingPlatform;
    const arch = iter.next() orelse return error.MissingArchitecture;
    const native = iter.next() orelse return error.MissingTarget;
    var args: std.ArrayList([]const u8) = .empty;
    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help")) return usage();
        try args.append(a, arg);
    }
    const options = try parse(args.items);
    if (!std.mem.eql(u8, native, "native")) return error.CrossTargetExportUnsupported;
    var project = try std.Io.Dir.cwd().openDir(io, project_arg, .{});
    defer project.close(io);
    _ = try project.statFile(io, "project.godot", .{});
    const presets = project.readFileAlloc(io, "export_presets.cfg", a, .limited(1 << 20)) catch |err| {
        std.debug.print("Create a preset using Godot: Project > Export. Cannot read export_presets.cfg.\n", .{});
        return err;
    };
    validatePreset(a, presets, options.preset, platform, arch) catch |err| {
        std.debug.print("Preset '{s}' must match the extension target {s}/{s}. Check its name, platform, and binary_format/architecture in export_presets.cfg.\n", .{ options.preset, platform, arch });
        return err;
    };
    const extension = std.fs.path.extension(options.output);
    const expected = if (std.mem.eql(u8, platform, "windows")) ".exe" else if (std.mem.eql(u8, platform, "macos")) ".zip" else "";
    if (expected.len != 0 and !std.ascii.eqlIgnoreCase(extension, expected)) return error.WrongOutputExtension;
    const parent = std.fs.path.dirname(options.output) orelse ".";
    const basename = std.fs.path.basename(options.output);
    if (basename.len == 0 or std.mem.eql(u8, basename, ".") or std.mem.eql(u8, basename, "..")) return error.InvalidOutput;
    try std.Io.Dir.cwd().createDirPath(io, parent);
    var destination = try std.Io.Dir.cwd().openDir(io, parent, .{ .iterate = true });
    defer destination.close(io);
    const project_path = try project.realPathFileAlloc(io, ".", a);
    const parent_path = try destination.realPathFileAlloc(io, ".", a);
    const relative = try std.fs.path.relative(a, project_path, null, project_path, parent_path);
    if (!std.fs.path.isAbsolute(relative) and !std.mem.eql(u8, relative, "..") and !std.mem.startsWith(u8, relative, ".." ++ std.fs.path.sep_str)) return error.OutputInsideProject;
    var entries = destination.iterate();
    if (try entries.next(io) != null) {
        std.debug.print("Output directory must be empty: {s}. Choose a new directory; existing files were not changed.\n", .{parent_path});
        return error.OutputDirectoryNotEmpty;
    }
    const output = try std.fs.path.join(a, &.{ parent_path, basename });
    try command(io, &.{ engine, "--headless", "--path", project_path, "--import" }, "import");
    command(io, &.{ engine, "--headless", "--path", project_path, options.mode, options.preset, output }, "export") catch |err| {
        std.debug.print("Check the Godot diagnostics above: install matching export templates in Editor > Manage Export Templates and check the preset. Partial output is retained at {s}.\n", .{parent_path});
        return err;
    };
    const stat = try destination.statFile(io, basename, .{});
    if (stat.kind != .file or stat.size == 0) return error.EmptyExport;
    std.debug.print("Exported: {s}\n", .{output});
}

fn command(io: std.Io, argv: []const []const u8, phase: []const u8) !void {
    var child = try std.process.spawn(io, .{ .argv = argv });
    defer child.kill(io);
    const term = try child.wait(io);
    if (term != .exited or term.exited != 0) {
        std.debug.print("Godot {s} failed: {any}\n", .{ phase, term });
        return error.GodotFailed;
    }
}

pub fn validatePreset(a: std.mem.Allocator, source: []const u8, name: []const u8, platform: []const u8, arch: []const u8) !void {
    const expected = if (std.mem.eql(u8, platform, "windows")) "Windows Desktop" else if (std.mem.eql(u8, platform, "linux")) "Linux" else if (std.mem.eql(u8, platform, "macos")) "macOS" else return error.UnsupportedExportPlatform;
    var lines = std.mem.splitScalar(u8, source, '\n');
    var selected = false;
    var matched = false;
    var actual_platform: ?[]const u8 = null;
    var actual_arch: ?[]const u8 = null;
    var in_preset = false;
    var in_options = false;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, line, "[")) {
            if (std.mem.startsWith(u8, line, "[preset.") and !std.mem.endsWith(u8, line, ".options]")) {
                if (selected) break;
                in_preset = true;
                in_options = false;
                actual_platform = null;
            } else {
                in_preset = false;
                in_options = selected and std.mem.endsWith(u8, line, ".options]");
            }
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (in_preset and std.mem.eql(u8, key, "name")) {
            const decoded = try std.zig.string_literal.parseAlloc(a, value);
            defer a.free(decoded);
            selected = std.mem.eql(u8, decoded, name);
            matched = matched or selected;
        } else if (in_preset and std.mem.eql(u8, key, "platform")) {
            actual_platform = value;
        } else if (in_options and std.mem.eql(u8, key, "binary_format/architecture")) {
            actual_arch = value;
        }
    }
    if (!matched) return error.PresetNotFound;
    const p = try std.zig.string_literal.parseAlloc(a, actual_platform orelse return error.MissingPresetPlatform);
    defer a.free(p);
    if (!std.mem.eql(u8, p, expected)) return error.PresetPlatformMismatch;
    const ar = try std.zig.string_literal.parseAlloc(a, actual_arch orelse return error.MissingPresetArchitecture);
    defer a.free(ar);
    if (!std.mem.eql(u8, ar, arch)) return error.PresetArchitectureMismatch;
}

test "strict export options" {
    const o = try parse(&.{ "--preset", "Windows Desktop", "--output", "out/game.exe", "--debug" });
    try std.testing.expectEqualStrings("--export-debug", o.mode);
    try std.testing.expectError(error.MissingOutput, parse(&.{ "--preset", "x" }));
    try std.testing.expectError(error.DuplicateMode, parse(&.{ "--debug", "--release" }));
    try std.testing.expectError(error.UnknownOption, parse(&.{"--verbose"}));
    try std.testing.expectError(error.MissingValue, parse(&.{"--output"}));
}

test "preset platform and architecture checks" {
    const source = "[preset.0]\nname=\"Other\"\nplatform=\"Linux\"\n[preset.0.options]\nbinary_format/architecture=\"arm64\"\n[preset.1]\nname=\"Windows Desktop\"\nplatform=\"Windows Desktop\"\n[preset.1.options]\nbinary_format/architecture=\"x86_64\"\n[preset.2]\nname=\"Later\"\n";
    try validatePreset(std.testing.allocator, source, "Windows Desktop", "windows", "x86_64");
    try std.testing.expectError(error.PresetNotFound, validatePreset(std.testing.allocator, source, "missing", "windows", "x86_64"));
    try std.testing.expectError(error.PresetPlatformMismatch, validatePreset(std.testing.allocator, source, "Windows Desktop", "linux", "x86_64"));
    try std.testing.expectError(error.PresetArchitectureMismatch, validatePreset(std.testing.allocator, source, "Windows Desktop", "windows", "arm64"));
}
