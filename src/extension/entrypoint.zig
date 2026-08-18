//! Root module for GDExtension libraries built with `gdzig.addExtension()`.

const std = @import("std");
const gdzig = @import("gdzig");
const extension = @import("extension");
const options = @import("options");

pub const std_options: std.Options = if (@hasDecl(extension, "std_options")) extension.std_options else .{};

var registry: gdzig.extension.Registry = .init(gdzig.engine_allocator);

comptime {
    @export(&entrypoint, .{
        .name = options.entry_symbol,
        .linkage = .strong,
    });
}

fn entrypoint(
    get_proc_address: gdzig.c.GDExtensionInterfaceGetProcAddress,
    library: gdzig.c.GDExtensionClassLibraryPtr,
    r_initialization: *gdzig.c.GDExtensionInitialization,
) callconv(.c) gdzig.c.GDExtensionBool {
    gdzig.raw = .init(get_proc_address.?, library.?);

    // `get_godot_version2` supersedes `get_godot_version`, deprecated in 4.5.
    // Its absence means an engine older than 4.5, which is already below the
    // supported floor, so it doubles as the first half of the version check.
    const getVersion = gdzig.raw.getGodotVersion2 orelse {
        std.log.err("gdzig requires Godot {d}.{d} or newer, but this engine predates 'get_godot_version2'", .{
            gdzig.Version.minimum_supported.major,
            gdzig.Version.minimum_supported.minor,
        });
        return 0;
    };
    getVersion(@ptrCast(&gdzig.version));

    // Refuse an unsupported engine rather than misregistering against it. gdzig
    // registers classes through the 4.4+ entry point and its bindings are
    // generated from a 4.7 API dump; on an older engine that surfaces as
    // confusing engine-side breakage well after load.
    if (gdzig.version.lt(gdzig.Version.minimum_supported)) {
        std.log.err("gdzig requires Godot {d}.{d} or newer, but this engine is {s}", .{
            gdzig.Version.minimum_supported.major,
            gdzig.Version.minimum_supported.minor,
            gdzig.version.string,
        });
        return 0;
    }

    extension.register(&registry);

    r_initialization.* = .{
        .minimum_initialization_level = @intFromEnum(options.minimum_initialization_level),
        .initialize = &enter,
        .deinitialize = &exit,
        .userdata = null,
    };
    return 1;
}

fn enter(_: ?*anyopaque, level: gdzig.c.GDExtensionInitializationLevel) callconv(.c) void {
    registry.enter(@enumFromInt(level));
}

fn exit(_: ?*anyopaque, level: gdzig.c.GDExtensionInitializationLevel) callconv(.c) void {
    if (level < @intFromEnum(options.minimum_initialization_level)) return;

    registry.exit(@enumFromInt(level));
    if (level == @intFromEnum(options.minimum_initialization_level)) {
        if (@hasDecl(extension, "unregister")) extension.unregister(&registry);
        registry.deinit();
    }
}
