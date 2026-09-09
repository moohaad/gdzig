const std = @import("std");
const builtin = @import("builtin");

const max_file_size = 1 << 20;

const Reporter = struct {
    passes: usize = 0,
    warnings: usize = 0,
    failures: usize = 0,

    fn pass(self: *Reporter, comptime format: []const u8, args: anytype) void {
        self.passes += 1;
        std.debug.print("PASS  " ++ format ++ "\n", args);
    }

    fn warn(self: *Reporter, comptime format: []const u8, args: anytype) void {
        self.warnings += 1;
        std.debug.print("WARN  " ++ format ++ "\n", args);
    }

    fn fail(self: *Reporter, comptime format: []const u8, args: anytype) void {
        self.failures += 1;
        std.debug.print("FAIL  " ++ format ++ "\n", args);
    }
};

const Options = struct {
    project: []const u8 = ".",
    godot: ?[]const u8 = null,
};

pub fn main(init: std.process.Init) !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var args = try init.minimal.args.iterateAllocator(arena);
    _ = args.next();

    const command = args.next() orelse {
        usage();
        std.process.exit(2);
    };
    if (std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        usage();
        return;
    }
    if (!std.mem.eql(u8, command, "doctor")) {
        std.debug.print("Error: unknown command '{s}'\n\n", .{command});
        usage();
        std.process.exit(2);
    }

    var options: Options = .{};
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--project") or std.mem.eql(u8, arg, "-p")) {
            options.project = args.next() orelse usageError("expected a directory after {s}", .{arg});
        } else if (std.mem.eql(u8, arg, "--godot") or std.mem.eql(u8, arg, "-g")) {
            options.godot = args.next() orelse usageError("expected an executable after {s}", .{arg});
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            doctorUsage();
            return;
        } else {
            usageError("unrecognised argument '{s}'", .{arg});
        }
    }

    std.debug.print("gdzig doctor\nproject: {s}\n\n", .{options.project});

    var reporter: Reporter = .{};
    checkZig(init.io, arena, &reporter);
    checkGodot(init.io, arena, options.godot, &reporter);
    checkBuildFiles(init.io, arena, &reporter);
    checkProject(init.io, arena, options.project, &reporter);

    std.debug.print(
        "\nsummary: {d} passed, {d} warning{s}, {d} failure{s}\n",
        .{
            reporter.passes,
            reporter.warnings,
            if (reporter.warnings == 1) "" else "s",
            reporter.failures,
            if (reporter.failures == 1) "" else "s",
        },
    );
    if (reporter.failures != 0) std.process.exit(1);
}

fn checkZig(io: std.Io, allocator: std.mem.Allocator, reporter: *Reporter) void {
    const output = commandOutput(io, allocator, &.{ "zig", "version" }) orelse {
        reporter.fail("Zig was not found in PATH; install Zig 0.16.x", .{});
        return;
    };
    const version = std.mem.trim(u8, output, " \t\r\n");
    const parsed = parseVersion(version) orelse {
        reporter.fail("could not understand `zig version` output: {s}", .{version});
        return;
    };
    if (parsed.major != 0 or parsed.minor != 16) {
        reporter.fail("Zig {s} is incompatible; gdzig requires Zig 0.16.x", .{version});
        return;
    }
    reporter.pass("Zig {s}", .{version});
}

fn checkGodot(io: std.Io, allocator: std.mem.Allocator, requested: ?[]const u8, reporter: *Reporter) void {
    if (requested) |executable| {
        const output = commandOutput(io, allocator, &.{ executable, "--version" }) orelse {
            reporter.fail("could not run Godot at '{s}'", .{executable});
            return;
        };
        checkGodotVersion(executable, output, reporter);
        return;
    }

    for ([_][]const u8{ "godot", "godot4" }) |executable| {
        if (commandOutput(io, allocator, &.{ executable, "--version" })) |output| {
            checkGodotVersion(executable, output, reporter);
            return;
        }
    }
    reporter.warn(
        "Godot is not in PATH; this is fine when `zig build` downloads it, or pass --godot <path> to verify one",
        .{},
    );
}

fn checkGodotVersion(executable: []const u8, output: []const u8, reporter: *Reporter) void {
    const version = std.mem.trim(u8, output, " \t\r\n");
    const parsed = parseVersion(version) orelse {
        reporter.fail("could not understand `{s} --version` output: {s}", .{ executable, version });
        return;
    };
    if (parsed.major != 4 or parsed.minor != 7) {
        reporter.fail("Godot {s} is incompatible; this gdzig release targets Godot 4.7", .{version});
        return;
    }
    reporter.pass("Godot {s} ({s})", .{ version, executable });
}

fn checkBuildFiles(io: std.Io, allocator: std.mem.Allocator, reporter: *Reporter) void {
    const cwd = std.Io.Dir.cwd();
    const build_zig = readFile(cwd, io, allocator, "build.zig") orelse {
        reporter.fail("build.zig is missing from the current directory", .{});
        return;
    };
    reporter.pass("build.zig exists", .{});
    if (std.mem.indexOf(u8, build_zig, "addExtension") == null) {
        reporter.warn("could not identify addExtension in build.zig; verify setup in any build helpers", .{});
    } else if (std.mem.indexOf(u8, build_zig, "extension.manifest") == null) {
        reporter.warn("could not identify extension.manifest in build.zig; verify the generated descriptor is installed", .{});
    } else {
        reporter.pass("build.zig references addExtension and extension.manifest (source hint only)", .{});
    }

    const zon = readFile(cwd, io, allocator, "build.zig.zon") orelse {
        reporter.fail("build.zig.zon is missing from the current directory", .{});
        return;
    };
    if (std.mem.indexOf(u8, zon, ".gdzig") == null) {
        reporter.warn(
            "could not identify a gdzig dependency; if absent, run `zig fetch --save=gdzig git+https://github.com/moohaad/gdzig.git`",
            .{},
        );
    } else {
        reporter.pass("build.zig.zon mentions gdzig (source hint only)", .{});
    }
}

fn checkProject(io: std.Io, allocator: std.mem.Allocator, project_path: []const u8, reporter: *Reporter) void {
    var project = std.Io.Dir.openDir(.cwd(), io, project_path, .{ .iterate = true }) catch |err| {
        reporter.fail("cannot open project directory '{s}': {s}", .{ project_path, @errorName(err) });
        return;
    };
    defer project.close(io);

    if (!fileExists(project, io, "project.godot")) {
        reporter.fail("{s}/project.godot is missing; pass --project <dir> for a split-layout project", .{project_path});
        return;
    }
    reporter.pass("project.godot exists", .{});

    var manifests: std.ArrayList([]const u8) = .empty;
    var entries = project.iterate();
    while (entries.next(io) catch null) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".gdextension")) continue;
        manifests.append(allocator, allocator.dupe(u8, entry.name) catch return) catch return;
    }
    if (manifests.items.len == 0) {
        reporter.fail("no .gdextension descriptor exists; run `zig build`", .{});
        checkExtensionList(project, io, allocator, project_path, manifests.items, reporter);
        return;
    }
    reporter.pass("found {d} .gdextension descriptor{s}", .{
        manifests.items.len,
        if (manifests.items.len == 1) "" else "s",
    });

    for (manifests.items) |name| checkManifest(project, io, allocator, name, reporter);
    checkExtensionList(project, io, allocator, project_path, manifests.items, reporter);
    checkReloadArtifacts(project, io, reporter);
}

fn checkManifest(
    project: std.Io.Dir,
    io: std.Io,
    allocator: std.mem.Allocator,
    name: []const u8,
    reporter: *Reporter,
) void {
    const body = readFile(project, io, allocator, name) orelse {
        reporter.fail("cannot read {s}", .{name});
        return;
    };
    const entry_symbol = iniValue(body, "entry_symbol") orelse {
        reporter.fail("{s} has no entry_symbol", .{name});
        return;
    };
    if (entry_symbol.len == 0) {
        reporter.fail("{s} has an empty entry_symbol", .{name});
    } else {
        reporter.pass("{s} entry symbol is {s}", .{ name, entry_symbol });
    }

    const compatibility = iniValue(body, "compatibility_minimum") orelse {
        reporter.fail("{s} has no compatibility_minimum", .{name});
        return;
    };
    const compatible_version = parseVersion(compatibility);
    if (compatible_version == null or
        compatible_version.?.major != 4 or compatible_version.?.minor != 7)
    {
        reporter.fail("{s} declares compatibility_minimum={s}; gdzig targets Godot 4.7", .{ name, compatibility });
    } else {
        reporter.pass("{s} targets Godot {s}", .{ name, compatibility });
    }

    const selector = currentSelector(allocator) catch return;
    const library = libraryForSelector(body, selector) orelse {
        reporter.fail("{s} has no library for this host ({s})", .{ name, selector });
        return;
    };
    const resource_path = if (std.mem.startsWith(u8, library, "res://")) library[6..] else library;
    if (fileExists(project, io, resource_path)) {
        reporter.pass("{s} points to existing library {s}", .{ name, library });
    } else {
        reporter.fail("{s} points to missing library {s}; run `zig build`", .{ name, library });
    }
}

fn checkExtensionList(
    project: std.Io.Dir,
    io: std.Io,
    allocator: std.mem.Allocator,
    project_path: []const u8,
    manifests: []const []const u8,
    reporter: *Reporter,
) void {
    const list = readFile(project, io, allocator, ".godot/extension_list.cfg") orelse {
        reporter.fail(
            ".godot/extension_list.cfg is missing; open the project once or run `godot --path {s} --headless --import`",
            .{project_path},
        );
        return;
    };
    for (manifests) |name| {
        const wanted = std.fmt.allocPrint(allocator, "res://{s}", .{name}) catch return;
        if (hasTrimmedLine(list, wanted)) {
            reporter.pass("Godot import list contains {s}", .{wanted});
        } else {
            reporter.fail("Godot import list omits {s}; run a Godot import pass", .{wanted});
        }
    }
}

fn checkReloadArtifacts(project: std.Io.Dir, io: std.Io, reporter: *Reporter) void {
    var lib = project.openDir(io, "lib", .{ .iterate = true }) catch return;
    defer lib.close(io);
    var entries = lib.iterate();
    while (entries.next(io) catch null) |entry| {
        if (entry.kind == .file and std.mem.startsWith(u8, entry.name, "~")) {
            reporter.warn("hot-reload copy lib/{s}; if Godot is closed, rebuild to clear it", .{entry.name});
        }
    }
}

fn commandOutput(io: std.Io, allocator: std.mem.Allocator, argv: []const []const u8) ?[]const u8 {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch return null;
    defer child.kill(io);

    var buffer: [4096]u8 = undefined;
    var reader = child.stdout.?.readerStreaming(io, &buffer);
    const output = reader.interface.allocRemaining(allocator, .limited(64 * 1024)) catch return null;
    const term = child.wait(io) catch return null;
    if (term != .exited or term.exited != 0) return null;
    return output;
}

const Version = struct { major: u32, minor: u32 };

fn parseVersion(text: []const u8) ?Version {
    var parts = std.mem.splitScalar(u8, text, '.');
    const major_text = parts.next() orelse return null;
    const minor_text = parts.next() orelse return null;
    return .{
        .major = std.fmt.parseInt(u32, major_text, 10) catch return null,
        .minor = std.fmt.parseInt(u32, minor_text, 10) catch return null,
    };
}

fn currentSelector(allocator: std.mem.Allocator) ![]const u8 {
    const platform = switch (builtin.os.tag) {
        .windows => "windows",
        .linux => "linux",
        .macos => "macos",
        .freebsd, .netbsd, .openbsd, .dragonfly => "bsd",
        else => @tagName(builtin.os.tag),
    };
    const architecture = switch (builtin.cpu.arch) {
        .x86 => "x86_32",
        .x86_64 => "x86_64",
        .arm, .armeb, .thumb, .thumbeb => "arm32",
        .aarch64, .aarch64_be => "arm64",
        .riscv64, .riscv64be => "rv64",
        .powerpc64, .powerpc64le => "ppc64",
        else => @tagName(builtin.cpu.arch),
    };
    return std.fmt.allocPrint(allocator, "{s}.debug.{s}", .{ platform, architecture });
}

fn iniValue(body: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (!std.mem.startsWith(u8, line, key)) continue;
        var rest = std.mem.trimStart(u8, line[key.len..], " \t");
        if (rest.len == 0 or rest[0] != '=') continue;
        rest = std.mem.trim(u8, rest[1..], " \t\r");
        if (rest.len < 2 or rest[0] != '"' or rest[rest.len - 1] != '"') continue;
        return rest[1 .. rest.len - 1];
    }
    return null;
}

fn libraryForSelector(body: []const u8, selector: []const u8) ?[]const u8 {
    var in_libraries = false;
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == ';' or line[0] == '#') continue;
        if (line[0] == '[') {
            in_libraries = std.mem.eql(u8, line, "[libraries]");
            continue;
        }
        if (!in_libraries) continue;
        if (std.mem.startsWith(u8, line, selector)) return iniValue(line, selector);
    }
    return null;
}

fn hasTrimmedLine(body: []const u8, wanted: []const u8) bool {
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        if (std.mem.eql(u8, std.mem.trim(u8, line, " \t\r"), wanted)) return true;
    }
    return false;
}

fn readFile(dir: std.Io.Dir, io: std.Io, allocator: std.mem.Allocator, path: []const u8) ?[]const u8 {
    return dir.readFileAlloc(io, path, allocator, @enumFromInt(max_file_size)) catch null;
}

fn fileExists(dir: std.Io.Dir, io: std.Io, path: []const u8) bool {
    const stat = dir.statFile(io, path, .{}) catch return false;
    return stat.kind == .file;
}

fn usage() void {
    std.debug.print(
        \\Usage: gdzig <command>
        \\
        \\Commands:
        \\  doctor    diagnose a gdzig project and its local toolchain
        \\
        \\Run `gdzig doctor --help` for command options.
        \\
    , .{});
}

fn doctorUsage() void {
    std.debug.print(
        \\Usage: gdzig doctor [--project <dir>] [--godot <executable>]
        \\
        \\  -p, --project <dir>     Godot project directory (default: .)
        \\  -g, --godot <path>      Godot executable to verify
        \\  -h, --help              print this and exit
        \\
        \\Run this from the directory containing build.zig. The command is read-only.
        \\Checks generated descriptors in the project root for this host's debug selector.
        \\Does not load libraries or verify exported symbols. Build-source checks are hints.
        \\Exit codes: 0 = no failures, 1 = failed checks, 2 = invalid arguments.
        \\
    , .{});
}

fn usageError(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print("Error: " ++ format ++ "\n\n", args);
    doctorUsage();
    std.process.exit(2);
}

test "version parser accepts Zig and Godot version suffixes" {
    try std.testing.expectEqual(Version{ .major = 0, .minor = 16 }, parseVersion("0.16.0-dev.123") orelse return error.TestUnexpectedResult);
    try std.testing.expectEqual(Version{ .major = 4, .minor = 7 }, parseVersion("4.7.1.stable.official") orelse return error.TestUnexpectedResult);
    try std.testing.expect(parseVersion("not-a-version") == null);
}

test "manifest parser reads only the requested library selector" {
    const body =
        \\[configuration]
        \\entry_symbol = "game_init"
        \\
        \\[libraries]
        \\windows.debug.x86_64 = "lib/game.dll"
        \\linux.debug.x86_64 = "lib/libgame.so"
        \\;
    ;
    try std.testing.expectEqualStrings("game_init", iniValue(body, "entry_symbol").?);
    try std.testing.expectEqualStrings("lib/game.dll", libraryForSelector(body, "windows.debug.x86_64").?);
    try std.testing.expect(libraryForSelector(body, "macos.debug.arm64") == null);
}

test "extension list matches complete resource lines" {
    const list = "res://one.gdextension\r\nres://two.gdextension\n";
    try std.testing.expect(hasTrimmedLine(list, "res://one.gdextension"));
    try std.testing.expect(!hasTrimmedLine(list, "res://one.gdextension.bak"));
}
