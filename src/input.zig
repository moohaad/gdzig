const std = @import("std");
const gdzig = @import("gdzig");
const Input = gdzig.class.Input;

/// Validates that the provided action is an enum value, and checks if it's pressed.
pub fn isActionPressed(action: anytype) bool {
    return Input.isActionPressed(actionName(action), .{});
}

/// Validates that the provided action is an enum value, and checks if it was just pressed.
pub fn isActionJustPressed(action: anytype) bool {
    return Input.isActionJustPressed(actionName(action), .{});
}

/// Validates that the provided action is an enum value, and checks if it was just released.
pub fn isActionJustReleased(action: anytype) bool {
    return Input.isActionJustReleased(actionName(action), .{});
}

/// The four actions read as one 2D vector, with the deadzone applied. The Y
/// component maps onto Z in 3D, so `negative_y` is "forward".
pub fn getVector(
    negative_x: anytype,
    positive_x: anytype,
    negative_y: anytype,
    positive_y: anytype,
    opt: struct { deadzone: f64 = -1.0 },
) gdzig.builtin.Vector2 {
    return Input.getVector(
        actionName(negative_x),
        actionName(positive_x),
        actionName(negative_y),
        actionName(positive_y),
        .{ .deadzone = opt.deadzone },
    );
}

/// The interned `StringName` for an action variant. `@tagName` is comptime per
/// branch, so this interns at comptime rather than allocating per call.
inline fn actionName(action: anytype) gdzig.builtin.StringName {
    validateAction(@TypeOf(action));
    return switch (action) {
        inline else => |a| gdzig.name(@tagName(a)),
    };
}

inline fn validateAction(comptime T: type) void {
    if (@typeInfo(T) != .@"enum") {
        @compileError("Action must be an enum variant");
    }
}
