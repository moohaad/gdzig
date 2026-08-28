const std = @import("std");

pub fn assertSignalSignature(comptime S: type, comptime ReceiverType: type, comptime MethodType: type) void {
    _ = ReceiverType;
    const method_info = @typeInfo(MethodType);
    const fn_info: ?std.builtin.Type.Fn = switch (method_info) {
        .pointer => |p| if (p.size == .one and @typeInfo(p.child) == .@"fn") @typeInfo(p.child).@"fn" else null,
        .@"fn" => |f| f,
        else => null,
    };
    if (fn_info == null) {
        @compileError("method must be a function pointer, found " ++ @typeName(MethodType));
    }
    const final_fn_info = fn_info.?;
    
    // First parameter must be the receiver
    if (final_fn_info.params.len == 0) {
        @compileError("Signal handler must take a receiver (e.g. *Self) as its first argument.");
    }
    
    const receiver_param = final_fn_info.params[0];
    
    // It's acceptable for the receiver parameter to be a generic `anytype` or a specific pointer type.
    // If it's a specific type, we verify it roughly matches `ReceiverType`.
    if (receiver_param.type) |ReceiverParamType| {
        // We can optionally check if ReceiverType coerces to ReceiverParamType
        // For now, let's just make sure it's a pointer or an opaque type.
        if (@typeInfo(ReceiverParamType) != .pointer and @typeInfo(ReceiverParamType) != .@"opaque") {
            @compileError("Signal handler's first argument must be a pointer to the receiver object, found " ++ @typeName(ReceiverParamType));
        }
    }

    const signal_fields = @typeInfo(S).@"struct".fields;
    const expected_arg_count = signal_fields.len;
    const actual_arg_count = final_fn_info.params.len - 1;

    if (actual_arg_count != expected_arg_count) {
        @compileError(std.fmt.comptimePrint(
            "Signal handler argument count mismatch for signal '{s}'. Signal emits {} arguments, but handler accepts {}.",
            .{ @typeName(S), expected_arg_count, actual_arg_count }
        ));
    }

    // Verify each argument type
    inline for (signal_fields, 0..) |field, i| {
        const param = final_fn_info.params[i + 1];
        if (param.type) |ParamType| {
            if (field.type != ParamType) {
                // Check if they are loosely compatible (e.g., both are pointers to something similar, or one is a variant).
                // Godot passes arguments as Variant or exactly the type. For strictness, we check exact type match.
                @compileError(std.fmt.comptimePrint(
                    "Signal handler argument {} type mismatch for signal '{s}'. Expected '{s}', found '{s}'.",
                    .{ i + 1, @typeName(S), @typeName(field.type), @typeName(ParamType) }
                ));
            }
        } else {
             @compileError(std.fmt.comptimePrint(
                "Signal handler argument {} must have an explicit type (not anytype).",
                .{ i + 1 }
            ));
        }
    }
}
