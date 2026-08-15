//! Higher level bindings generated from the Godot Engine's extension API:
//!
//! - `builtin` - Core Godot value types: String, Vector2/3/4, Array, Dictionary, Color
//! - `class` - Godot class hierarchy and OOP utilities for working with classes
//! - `global` - Global scope enumerations, flag structs, and constants
//! - `general` - General-purpose utility functions like logging
//! - `math` - Mathematical utilities and constants
//! - `random` - Random number generation utilities
//!
//! Lower level access to the GDExtension APIs:
//!
//! - `raw` - Runtime function pointers loaded from Godot
//! - `c` - C type definitions from `gdextension_interface.h`
//!

pub const c = @import("gdextension");
pub const builtin = @import("builtin.zig");
pub const class = @import("class.zig");
pub const heap = @import("heap.zig");
pub const engine_allocator = heap.engine_allocator;
pub const GeneralPurposeAllocator = heap.GeneralPurposeAllocator;
pub const general = @import("general.zig");
pub const global = @import("global.zig");
/// Plain C structs the engine passes by pointer, used by virtual methods such
/// as `AudioStreamPlayback._mix`.
pub const native = @import("native.zig");
pub const math = @import("math.zig");
pub const random = @import("random.zig");
pub const extension = @import("extension.zig");
pub const testing = @import("testing.zig");
pub const Gd = @import("gd.zig").Gd;
pub const Weak = @import("weak.zig").Weak;
pub const Child = @import("child.zig").Child;
pub const Scene = @import("scene.zig").Scene;
pub const load = @import("load.zig").load;

const DispatchTable = @import("DispatchTable.zig");

/// Godot function pointers, populated at load time.
pub var raw: DispatchTable = undefined;

/// The current running version of Godot, initialized during extension initialization.
pub var version: Version = undefined;

pub const CallError = error{
    InvalidMethod,
    InvalidArgument,
    TooManyArguments,
    TooFewArguments,
    InstanceIsNull,
    MethodNotConst,
};

pub const ConnectError = error{
    AlreadyConnected,
};

pub const EmitError = error{
    InvalidSignal,
    SignalsBlocked,
    MethodNotFound,
};

pub const PropertyError = error{
    InvalidOperation,
    InvalidKey,
    IndexOutOfBounds,
};

/// Mirrors `GDExtensionGodotVersion2`, which `get_godot_version2` fills in.
///
/// The layout must match the C struct exactly: the engine writes into it
/// through a pointer cast. The older `GDExtensionGodotVersion` carried only
/// major/minor/patch/string; the rest of these fields arrived with
/// `get_godot_version2` in Godot 4.5, which deprecated the original.
pub const Version = extern struct {
    major: u32,
    minor: u32,
    patch: u32,
    /// Version packed as `(major << 16) | (minor << 8) | patch`.
    hex: u32 = 0,
    /// Release status, e.g. "stable" or "beta3".
    status: [*:0]const u8 = "",
    /// Distribution-specific build identifier, e.g. "official".
    build: [*:0]const u8 = "",
    /// Full git commit hash, or empty when unavailable.
    hash: [*:0]const u8 = "",
    /// Commit timestamp, or 0 when unavailable.
    timestamp: u64 = 0,
    string: [*:0]const u8 = "",

    pub const @"4.1" = parse("4.1");
    pub const @"4.2" = parse("4.2");
    pub const @"4.3" = parse("4.3");
    pub const @"4.4" = parse("4.4");
    pub const @"4.7" = parse("4.7");

    /// The oldest engine gdzig supports. Class registration targets the 4.4+
    /// entry point and the generated bindings come from a 4.7 API dump, so an
    /// older engine would misregister rather than fail cleanly.
    pub const minimum_supported = @"4.7";

    var current: Version = undefined;

    pub fn gt(self: Version, other: Version) bool {
        if (self.major != other.major) return self.major > other.major;
        if (self.minor != other.minor) return self.minor > other.minor;
        return self.patch > other.patch;
    }

    pub fn gte(self: Version, other: Version) bool {
        if (self.major != other.major) return self.major > other.major;
        if (self.minor != other.minor) return self.minor > other.minor;
        return self.patch >= other.patch;
    }

    pub fn lt(self: Version, other: Version) bool {
        if (self.major != other.major) return self.major < other.major;
        if (self.minor != other.minor) return self.minor < other.minor;
        return self.patch < other.patch;
    }

    pub fn lte(self: Version, other: Version) bool {
        if (self.major != other.major) return self.major < other.major;
        if (self.minor != other.minor) return self.minor < other.minor;
        return self.patch <= other.patch;
    }

    /// Returns true if self is in the range [min_ver, max_ver).
    pub fn range(self: Version, min_ver: Version, max_ver: Version) bool {
        return self.gte(min_ver) and self.lt(max_ver);
    }

    pub fn parse(version_string: []const u8) Version {
        var parts: [3]u32 = .{ 0, 0, 0 };
        var part_idx: usize = 0;
        for (version_string) |ch| {
            if (ch == '.') {
                part_idx += 1;
            } else {
                parts[part_idx] = parts[part_idx] * 10 + (ch - '0');
            }
        }
        return .{ .major = parts[0], .minor = parts[1], .patch = parts[2] };
    }

    test {
        const v14_2 = parse("14.2.0");
        const v14_3 = parse("14.3.0");

        try std.testing.expectEqual(v14_2.major, 14);
        try std.testing.expectEqual(v14_2.minor, 2);
        try std.testing.expectEqual(v14_2.patch, 0);

        try std.testing.expect(v14_3.gt(v14_2));
        try std.testing.expect(v14_3.gte(v14_2));
        try std.testing.expect(v14_2.lt(v14_3));
        try std.testing.expect(v14_2.lte(v14_3));
        try std.testing.expect(v14_3.range(v14_2, parse("14.4.0")));
    }
};

test {
    std.testing.refAllDecls(@This());
    // Type-checks the generated surface; see that file for why the library
    // build alone does not. Opt-in via `-Dsurface-audit` while the defects it
    // reports are still being worked through.
    if (@import("build_options").surface_audit) {
        _ = @import("surface.zig");
    }
}

const std = @import("std");
