const std = @import("std");
const gdzig = @import("gdzig.zig");
const Variant = gdzig.builtin.Variant;
const StringName = gdzig.builtin.StringName;

/// Automatically persist all supported Zig struct fields to Godot object metadata.
/// Call this during `destroy()` or `_exit_tree()`.
pub fn autoPersist(self: anytype) void {
    const T = @TypeOf(self.*);
    const info = @typeInfo(T);
    if (info != .@"struct") {
        @compileError("autoPersist expects a pointer to a struct, got " ++ @typeName(T));
    }

    if (!@hasField(T, "base")) {
        @compileError("autoPersist requires a 'base' field in the struct");
    }

    inline for (info.@"struct".fields) |field| {
        if (comptime (std.mem.eql(u8, field.name, "base") or std.mem.eql(u8, field.name, "children"))) continue;
        if (comptime std.mem.eql(u8, field.name, "allocator")) continue;
        if (comptime std.mem.startsWith(u8, field.name, "_")) continue;

        if (comptime Variant.Tag.forTypeOrNull(field.type) != null) {
            const key = StringName.fromComptimeLatin1("gdzig_persist_" ++ field.name);
            const val = Variant.init(field.type, @field(self, field.name));
            self.base.setMeta(key.*, val);
            val.deinit();
        }
    }
}

/// Automatically restore all supported Zig struct fields from Godot object metadata.
/// Call this during `create()` or `_enter_tree()`.
pub fn autoRestore(self: anytype) void {
    const T = @TypeOf(self.*);
    const info = @typeInfo(T);
    if (info != .@"struct") {
        @compileError("autoRestore expects a pointer to a struct, got " ++ @typeName(T));
    }

    if (!@hasField(T, "base")) {
        @compileError("autoRestore requires a 'base' field in the struct");
    }

    inline for (info.@"struct".fields) |field| {
        if (comptime (std.mem.eql(u8, field.name, "base") or std.mem.eql(u8, field.name, "children"))) continue;
        if (comptime std.mem.eql(u8, field.name, "allocator")) continue;
        if (comptime std.mem.startsWith(u8, field.name, "_")) continue;

        if (comptime Variant.Tag.forTypeOrNull(field.type) != null) {
            const key_str = "gdzig_persist_" ++ field.name;
            const key = StringName.fromComptimeLatin1(key_str);

            if (self.base.hasMeta(key.*)) {
                const val = self.base.getMeta(key.*, .{});
                defer val.deinit();

                if (val.as(field.type)) |decoded| {
                    @field(self, field.name) = decoded;
                }

                // Optional: remove meta to clean up engine state
                self.base.removeMeta(key.*);
            }
        }
    }
}
