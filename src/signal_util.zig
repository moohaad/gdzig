const std = @import("std");

pub fn assertSignalSignature(comptime S: type, comptime ReceiverType: type, comptime MethodType: type) void {
    const context = " Receiver: " ++ @typeName(ReceiverType) ++ "; handler type: " ++ @typeName(MethodType) ++ ".";
    const method_info = @typeInfo(MethodType);
    const fn_info: ?std.builtin.Type.Fn = switch (method_info) {
        .pointer => |p| if (p.size == .one and @typeInfo(p.child) == .@"fn") @typeInfo(p.child).@"fn" else null,
        .@"fn" => |f| f,
        else => null,
    };
    if (fn_info == null) {
        @compileError("Signal handler must be a function or function pointer; pass the handler declaration, not its result." ++ context);
    }
    const final_fn_info = fn_info.?;

    // First parameter must be the receiver
    if (final_fn_info.param_types.len == 0) {
        @compileError("Signal handler must take a receiver (e.g. *Self) as its first argument." ++ context);
    }

    const receiver_param = final_fn_info.param_types[0];

    // It's acceptable for the receiver parameter to be a generic `anytype` or a specific pointer type.
    // If it's a specific type, we verify it roughly matches `ReceiverType`.
    if (receiver_param) |ReceiverParamType| {
        // We can optionally check if ReceiverType coerces to ReceiverParamType
        // For now, let's just make sure it's a pointer or an opaque type.
        if (@typeInfo(ReceiverParamType) != .pointer and @typeInfo(ReceiverParamType) != .@"opaque") {
            @compileError("Signal handler's first argument must be a pointer to the receiver object, found " ++ @typeName(ReceiverParamType));
        }
    }

    const signal_fields = @typeInfo(S).@"struct";
    const expected_arg_count = signal_fields.field_names.len;
    const actual_arg_count = final_fn_info.param_types.len - 1;

    if (actual_arg_count != expected_arg_count) {
        @compileError(std.fmt.comptimePrint("Signal handler argument count mismatch for signal '{s}'. Signal emits {} arguments, but handler accepts {}. Add or remove handler parameters after the receiver to match the signal.", .{ @typeName(S), expected_arg_count, actual_arg_count }) ++ context);
    }

    // Verify each argument type
    inline for (signal_fields.field_types, 0..) |FieldType, i| {
        const param = final_fn_info.param_types[i + 1];
        if (param) |ParamType| {
            if (FieldType != ParamType) {
                // Check if they are loosely compatible (e.g., both are pointers to something similar, or one is a variant).
                // Godot passes arguments as Variant or exactly the type. For strictness, we check exact type match.
                @compileError(std.fmt.comptimePrint("Signal handler argument {} type mismatch for signal '{s}'. Expected '{s}', found '{s}'. Change this handler parameter to the expected type.", .{ i + 1, @typeName(S), @typeName(FieldType), @typeName(ParamType) }) ++ context);
            }
        } else {
            @compileError(std.fmt.comptimePrint("Signal handler argument {} must have an explicit type (not anytype).", .{i + 1}));
        }
    }
}
