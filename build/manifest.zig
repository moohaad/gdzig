const std = @import("std");
const Build = std.Build;

pub const Options = struct {
    extension_name: []const u8,
    entry_symbol: []const u8,
    library_filename: []const u8,
    library_dir: []const u8,
    target: std.Target,
    reloadable: bool,
};

pub const Output = struct {
    path: Build.LazyPath,
    filename: []const u8,
};

/// Generates the descriptor beside the extension build instead of asking the
/// caller to repeat the symbol, target, and output filename by hand.
pub fn add(b: *Build, options: Options) Output {
    assertIniString("extension name", options.extension_name);
    assertIniString("entry symbol", options.entry_symbol);
    assertIniString("library filename", options.library_filename);
    assertIniString("library directory", options.library_dir);

    const platform = platformName(options.target.os.tag, options.target.abi) orelse
        std.debug.panic(
            "gdzig: cannot generate a .gdextension library selector for target OS '{s}' with ABI '{s}'",
            .{ @tagName(options.target.os.tag), @tagName(options.target.abi) },
        );
    const architecture = architectureName(options.target.cpu.arch) orelse
        std.debug.panic(
            "gdzig: cannot generate a .gdextension library selector for architecture '{s}'",
            .{@tagName(options.target.cpu.arch)},
        );

    const trimmed_dir = std.mem.trimEnd(u8, options.library_dir, "/\\");
    const raw_library_path = if (trimmed_dir.len == 0)
        b.dupe(options.library_filename)
    else
        b.fmt("{s}/{s}", .{ trimmed_dir, options.library_filename });
    // A build may run on Windows, but `.gdextension` paths always use Godot's
    // resource-path separator.
    std.mem.replaceScalar(u8, raw_library_path, '\\', '/');

    // Both selectors deliberately point at the same artifact. `debug` and
    // `release` are features of the Godot executable (the editor is `debug`),
    // not Zig's optimization mode; a ReleaseFast extension must still be
    // loadable in the editor.
    const contents = b.fmt(
        \\[configuration]
        \\
        \\entry_symbol = "{s}"
        \\compatibility_minimum = "4.7"
        \\reloadable = {s}
        \\
        \\[libraries]
        \\
        \\{s}.debug.{s} = "{s}"
        \\{s}.release.{s} = "{s}"
        \\
    , .{
        options.entry_symbol,
        if (options.reloadable) "true" else "false",
        platform,
        architecture,
        raw_library_path,
        platform,
        architecture,
        raw_library_path,
    });

    const filename = b.fmt("{s}.gdextension", .{options.extension_name});
    const files = b.addWriteFiles();
    return .{
        .path = files.add(filename, contents),
        .filename = filename,
    };
}

fn assertIniString(comptime label: []const u8, value: []const u8) void {
    if (std.mem.indexOfAny(u8, value, "\"\r\n") != null) {
        std.debug.panic("gdzig: {s} cannot contain a quote or newline", .{label});
    }
}

/// Godot's OS feature name. Android is a Linux ABI in Zig, so its ABI must be
/// considered before the OS tag.
pub fn platformName(os: std.Target.Os.Tag, abi: std.Target.Abi) ?[]const u8 {
    if (abi == .android or abi == .androideabi) return "android";
    return switch (os) {
        .windows => "windows",
        .linux => "linux",
        .macos, .maccatalyst => "macos",
        .ios => "ios",
        .visionos => "visionos",
        .emscripten => "web",
        .dragonfly, .freebsd, .netbsd, .openbsd => "bsd",
        else => null,
    };
}

/// Godot's architecture feature name for the architectures it supports as
/// native extension targets.
pub fn architectureName(arch: std.Target.Cpu.Arch) ?[]const u8 {
    return switch (arch) {
        .x86 => "x86_32",
        .x86_64 => "x86_64",
        .arm, .armeb, .thumb, .thumbeb => "arm32",
        .aarch64, .aarch64_be => "arm64",
        .riscv64, .riscv64be => "rv64",
        .powerpc64, .powerpc64le => "ppc64",
        .wasm32 => "wasm32",
        else => null,
    };
}

test "platform names match Godot feature tags" {
    try std.testing.expectEqualStrings("windows", platformName(.windows, .msvc).?);
    try std.testing.expectEqualStrings("linux", platformName(.linux, .gnu).?);
    try std.testing.expectEqualStrings("android", platformName(.linux, .android).?);
    try std.testing.expectEqualStrings("macos", platformName(.macos, .none).?);
    try std.testing.expectEqualStrings("web", platformName(.emscripten, .none).?);
    try std.testing.expectEqual(@as(?[]const u8, null), platformName(.wasi, .none));
}

test "architecture names match Godot feature tags" {
    try std.testing.expectEqualStrings("x86_32", architectureName(.x86).?);
    try std.testing.expectEqualStrings("x86_64", architectureName(.x86_64).?);
    try std.testing.expectEqualStrings("arm32", architectureName(.arm).?);
    try std.testing.expectEqualStrings("arm64", architectureName(.aarch64).?);
    try std.testing.expectEqualStrings("rv64", architectureName(.riscv64).?);
    try std.testing.expectEqualStrings("wasm32", architectureName(.wasm32).?);
    try std.testing.expectEqual(@as(?[]const u8, null), architectureName(.wasm64));
}
