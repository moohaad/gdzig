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
pub const gd = @import("gd.zig");
pub const Gd = @import("gd.zig").Gd;
pub const Weak = @import("weak.zig").Weak;
pub const Child = @import("child.zig").Child;
pub const Autoload = @import("child.zig").Autoload;
pub const Parent = @import("child.zig").Parent;
pub const Children = @import("child.zig").Children;
pub const Scene = @import("scene.zig").Scene;
pub const rpc = @import("rpc.zig");
pub const coro = @import("coro.zig");
pub const load = @import("load.zig").load;
pub const input = @import("input.zig");

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

/// Automatically resolves `@onready` emulation for a given struct instance.
/// 
/// Evaluates the `pub const onready = .{ .{ "field", "NodePath" } };` tuple
/// and populates the fields via `self.base.getNodeOrNull` and `class.castTo`.
pub fn resolveOnReady(self: anytype) void {
    const T = @TypeOf(self);
    const ChildT = std.meta.Child(T);
    if (!@hasDecl(ChildT, "onready")) return;

    const onready = @field(ChildT, "onready");
    const info = @typeInfo(@TypeOf(onready));
    if (info == .@"struct" and info.@"struct".is_tuple) {
        inline for (info.@"struct".fields) |field| {
            const entry = @field(onready, field.name);
            const prop_name = entry[0];
            const node_path = entry[1];
            
            const PropType = @TypeOf(@field(self, prop_name));
            const is_optional = @typeInfo(PropType) == .optional;
            const PtrType = if (is_optional) std.meta.Child(PropType) else PropType;
            
            var godot_str = builtin.String.fromNullTerminatedUtf8(node_path);
            defer godot_str.deinit();
            var node_path_obj = builtin.NodePath.fromString(godot_str);
            defer node_path_obj.deinit();
            
            if (self.base.getNodeOrNull(node_path_obj)) |node| {
                if (class.castTo(std.meta.Child(PtrType), node)) |cast_node| {
                    @field(self, prop_name) = cast_node;
                }
            }
        }
    }
}

/// Loads a PackedScene from the given path, instantiates it, and safely downcasts
/// it to the requested type `T`. If the load or cast fails, it will free the 
/// instantiated node (if it was created) and return `null`.
pub fn instantiateAs(comptime T: type, comptime scene_path: [:0]const u8) ?*T {
    var pscene = load(class.PackedScene, scene_path) orelse return null;
    defer pscene.deinit();
    
    var instance = pscene.get().instantiate(.{}) orelse return null;
    if (class.castTo(T, instance)) |narrowed| {
        return narrowed;
    }
    
    instance.destroy();
    return null;
}

/// Safely calls an RPC on a node, automatically converting the method name to a StringName
/// and expanding the arguments tuple.
pub fn callRpc(self: anytype, comptime method_name: [:0]const u8, args: anytype) void {
    var method_sn = builtin.StringName.fromLatin1(method_name);
    defer method_sn.deinit();
    
    const node = class.castTo(class.Node, self.base) orelse return;
    _ = @call(.auto, class.Node.rpc, .{ node, method_sn } ++ args) catch {};
}

/// Safely calls an RPC on a specific peer, automatically converting the method name to a StringName
/// and expanding the arguments tuple.
pub fn callRpcId(self: anytype, peer_id: i64, comptime method_name: [:0]const u8, args: anytype) void {
    var method_sn = builtin.StringName.fromLatin1(method_name);
    defer method_sn.deinit();
    
    const node = class.castTo(class.Node, self.base) orelse return;
    _ = @call(.auto, class.Node.rpcId, .{ node, peer_id, method_sn } ++ args) catch {};
}

/// Creates or fetches an interned StringName from a comptime string.
pub inline fn name(comptime str: [:0]const u8) builtin.StringName {
    return builtin.StringName.interned(str);
}

/// Creates or fetches an interned NodePath from a comptime string.
pub inline fn path(comptime str: [:0]const u8) builtin.NodePath {
    return builtin.NodePath.interned(str);
}

/// A universal cleanup method. Safely calls `unreference`, `destroy`, or `deinit`
/// depending on the type of the object. Prevents memory leaks.
pub fn cleanup(obj: anytype) void {
    const T = @TypeOf(obj);
    if (@typeInfo(T) == .optional) {
        if (obj) |val| cleanup(val);
        return;
    }
    if (@typeInfo(T) == .pointer) {
        const ChildT = std.meta.Child(T);
        if (@typeInfo(ChildT) == .pointer or @typeInfo(ChildT) == .optional) {
            cleanup(obj.*);
            return;
        }
        
        switch (@typeInfo(ChildT)) {
            .@"struct", .@"union", .@"enum", .@"opaque" => {},
            else => return,
        }

        if (@hasDecl(ChildT, "unreference")) {
            if (obj.unreference()) {
                obj.destroy();
            }
            return;
        }
        if (@hasDecl(ChildT, "destroy")) {
            obj.destroy();
            return;
        }
        if (@hasDecl(ChildT, "deinit")) {
            obj.deinit();
            return;
        }
    } else {
        if (@hasDecl(T, "deinit")) {
            var o = obj;
            o.deinit();
        }
    }
}

/// A wrapper for ergonomic signal connection and emission.
pub fn SignalBinder(comptime OwnerT: type, comptime SignalT: type) type {
    return struct {
        owner: *OwnerT,

        pub inline fn init(owner: *OwnerT) @This() {
            return .{ .owner = owner };
        }

        pub inline fn connect(self: @This(), receiver: anytype, comptime method: anytype) void {
            self.owner.connect(SignalT, receiver, method);
        }

        pub inline fn connectCallable(self: @This(), callable: builtin.Callable) void {
            self.owner.connectCallable(SignalT, callable);
        }

        pub inline fn emit(self: @This(), args: SignalT) !void {
            return self.owner.emit(SignalT, args);
        }
    };
}

// Coercion helpers for implicit string conversions
pub const CoercedStringName = struct {
    value: builtin.StringName,
    allocates: bool,
    pub inline fn deinit(self: *const CoercedStringName) void {
        if (self.allocates) {
            // Need a mutable pointer to call deinit. But value is passed by value?
            // Actually, StringName.deinit takes *StringName, so we can cast it.
            var mut_val = self.value;
            mut_val.deinit();
        }
    }
};

pub fn coerceStringName(val: anytype) CoercedStringName {
    const T = @TypeOf(val);
    if (T == builtin.StringName) return .{ .value = val, .allocates = false };
    if (T == *builtin.StringName or T == *const builtin.StringName) return .{ .value = val.*, .allocates = false };
    if (comptime isStringish(T)) {
        return .{ .value = builtin.StringName.fromUtf8(val), .allocates = true };
    }
    @compileError("Cannot coerce " ++ @typeName(T) ++ " to StringName");
}

pub const CoercedString = struct {
    value: builtin.String,
    allocates: bool,
    pub inline fn deinit(self: *const CoercedString) void {
        if (self.allocates) {
            var mut_val = self.value;
            mut_val.deinit();
        }
    }
};

pub fn coerceString(val: anytype) CoercedString {
    const T = @TypeOf(val);
    if (T == builtin.String) return .{ .value = val, .allocates = false };
    if (T == *builtin.String or T == *const builtin.String) return .{ .value = val.*, .allocates = false };
    if (comptime isStringish(T)) {
        // `fromUtf8` fails on bytes the engine cannot decode. Nothing can be
        // returned here -- the generated setters that call this are `void` --
        // so report it and pass the empty string rather than something
        // half-decoded.
        const str = builtin.String.fromUtf8(val) catch |err| {
            std.log.err("gdzig: cannot coerce to String: {s}", .{@errorName(err)});
            return .{ .value = .empty, .allocates = false };
        };
        return .{ .value = str, .allocates = true };
    }
    @compileError("Cannot coerce " ++ @typeName(T) ++ " to String");
}

pub const CoercedNodePath = struct {
    value: builtin.NodePath,
    allocates: bool,
    pub inline fn deinit(self: *const CoercedNodePath) void {
        if (self.allocates) {
            var mut_val = self.value;
            mut_val.deinit();
        }
    }
};

pub fn coerceNodePath(val: anytype) CoercedNodePath {
    const T = @TypeOf(val);
    if (T == builtin.NodePath) return .{ .value = val, .allocates = false };
    if (T == *builtin.NodePath or T == *const builtin.NodePath) return .{ .value = val.*, .allocates = false };
    if (comptime isStringish(T)) {
        var str = builtin.String.fromUtf8(val) catch |err| {
            std.log.err("gdzig: cannot coerce to NodePath: {s}", .{@errorName(err)});
            return .{ .value = builtin.NodePath.fromString(builtin.String.empty), .allocates = true };
        };
        defer str.deinit();
        return .{ .value = builtin.NodePath.fromString(str), .allocates = true };
    }
    @compileError("Cannot coerce " ++ @typeName(T) ++ " to NodePath");
}


fn isStringish(comptime T: type) bool {
    switch (@typeInfo(T)) {
        .pointer => |p| {
            if (p.size == .slice and p.child == u8) return true;
            if (p.size == .one) {
                switch (@typeInfo(p.child)) {
                    .array => |a| if (a.child == u8) return true,
                    else => {}
                }
            }
        },
        else => {}
    }
    return false;
}
