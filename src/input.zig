const std = @import("std");
const gdzig = @import("gdzig");
const Input = gdzig.class.Input;

/// Validates that the provided action is an enum value, and checks if it's pressed.
pub fn isActionPressed(action: anytype) bool {
    validateAction(@TypeOf(action));
    const name_sn = switch (action) {
        inline else => |a| gdzig.name(@tagName(a)),
    };
    return Input.isActionPressed(name_sn, .{});
}

/// Validates that the provided action is an enum value, and checks if it was just pressed.
pub fn isActionJustPressed(action: anytype) bool {
    validateAction(@TypeOf(action));
    const name_sn = switch (action) {
        inline else => |a| gdzig.name(@tagName(a)),
    };
    return Input.isActionJustPressed(name_sn, .{});
}

/// Validates that the provided action is an enum value, and checks if it was just released.
pub fn isActionJustReleased(action: anytype) bool {
    validateAction(@TypeOf(action));
    const name_sn = switch (action) {
        inline else => |a| gdzig.name(@tagName(a)),
    };
    return Input.isActionJustReleased(name_sn, .{});
}

inline fn validateAction(comptime T: type) void {
    if (@typeInfo(T) != .@"enum") {
        @compileError("Action must be an enum variant");
    }
}
