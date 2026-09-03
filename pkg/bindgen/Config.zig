const std = @import("std");
const build_options = @import("build_options");
const Io = std.Io;
const Dir = Io.Dir;

const Config = @This();

arch: Arch,
extension_api: Io.File,
gdextension_interface: Io.File,
input: Io.Dir,
output: Io.Dir,
/// The `Io` implementation used for every file operation performed with the
/// handles above. Stored here so codegen can reach it via `ctx.config.io`.
io: Io,
precision: Precision,
verbosity: Verbosity,
/// Comma-separated Godot or gdzig class names. Empty means the full surface.
classes: []const u8,

/// Address width, matching `-Darch`.
pub const Arch = enum(u8) {
    @"32" = 32,
    @"64" = 64,
};

/// Floating-point width, matching `-Dprecision`. Decides what `real_t` and the
/// builtin struct sizes come out as.
pub const Precision = enum {
    double,
    float,
};

pub const Verbosity = enum {
    quiet,
    verbose,
};

pub fn loadFromArgs(io: Io, args: []const [:0]const u8) !Config {
    const cwd = Io.Dir.cwd();

    // args[1]: path to gdextension_interface.h
    // args[2]: path to extension_api.json
    // args[3]: input directory (hand-written sources the generator reads)
    // args[4]: output directory
    // args[5]: precision, `float` or `double`
    // args[6]: architecture, `32` or `64`
    // args[7]: verbosity, `quiet` or `verbose`
    // args[8]: optional comma-separated class filter
    //
    // Precision comes before architecture; see `build/bindgen.zig`, which is the
    // only caller. The two used to be read in this order but named the other way
    // round, so passing them correctly produced "Invalid architecture 64".
    const gdextension_interface = try cwd.openFile(io, args[1], .{});
    const extension_api = try cwd.openFile(io, args[2], .{});

    const input = try cwd.createDirPathOpen(io, args[3], .{});
    const output = try cwd.createDirPathOpen(io, args[4], .{});

    const precision = std.meta.stringToEnum(Config.Precision, args[5]) orelse std.debug.panic("Invalid precision '{s}', expected one of {any}", .{ args[5], std.meta.tags(Config.Precision) });
    const arch = std.meta.stringToEnum(Config.Arch, args[6]) orelse std.debug.panic("Invalid architecture '{s}', expected one of {any}", .{ args[6], std.meta.tags(Config.Arch) });
    const verbosity = std.meta.stringToEnum(Config.Verbosity, args[7]) orelse .quiet;
    const classes = if (args.len > 8) args[8] else "";

    return .{
        .arch = arch,
        .extension_api = extension_api,
        .gdextension_interface = gdextension_interface,
        .input = input,
        .output = output,
        .io = io,
        .precision = precision,
        .verbosity = verbosity,
        .classes = classes,
    };
}

/// The key Godot uses for this build in `builtin_class_sizes`, e.g. `float_64`.
pub fn buildConfiguration(self: *Config) []const u8 {
    return switch (self.precision) {
        .double => switch (self.arch) {
            .@"32" => "double_32",
            .@"64" => "double_64",
        },
        .float => switch (self.arch) {
            .@"32" => "float_32",
            .@"64" => "float_64",
        },
    };
}

pub fn deinit(self: *Config) void {
    self.gdextension_interface.close(self.io);
    self.extension_api.close(self.io);
    self.input.close(self.io);
    self.output.close(self.io);
}

pub fn testConfig(io: Io, output: Dir) !Config {
    var headers = Io.Dir.openDirAbsolute(io, build_options.headers, .{}) catch |err| {
        std.debug.print("Failed to open headers dir: {s}\n", .{@errorName(err)});
        return err;
    };
    defer headers.close(io);

    return Config{
        .arch = .@"32",
        .extension_api = try headers.openFile(io, "extension_api.json", .{}),
        .gdextension_interface = try headers.openFile(io, "gdextension_interface.h", .{}),
        .input = output,
        .output = output,
        .io = io,
        .precision = .float,
        .verbosity = .quiet,
        .classes = "",
    };
}
