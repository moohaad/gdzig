const std = @import("std");
const DeclEnum = std.meta.DeclEnum;

const casez = @import("casez");
const common = @import("common");
const godot_case = common.godot_case;

const gdzig = @import("gdzig");
const ptrcall = @import("../class/ptrcall.zig");
const classdb = gdzig.class.ClassDb;
const MethodFlags = gdzig.global.MethodFlags;
const StringName = gdzig.builtin.StringName;
const Variant = gdzig.builtin.Variant;

const DispatchGuard = gdzig.extension.DispatchGuard;
const Registry = @import("Registry.zig");

/// Registers a method on a class.
///
/// Example:
/// ```
/// godot.registerMethod(MyClass, .decl(.myMethod));
/// ```
/// A `Variant` argument or return is typed NIL, which Godot otherwise reads as
/// "no type" rather than "any type" -- the method then never gets called. The
/// flag is what distinguishes the two, and it is needed on the method's own
/// `PropertyInfo`s, not only on a property that happens to wrap them.
fn variantUsage(comptime T: type) gdzig.global.PropertyUsageFlags {
    if (T == gdzig.builtin.Variant) return .{ .property_usage_nil_is_variant = true };
    return .{};
}

pub fn registerMethod(comptime Class: type, comptime config: MethodConfig(Class)) void {
    const class_name = StringName.fromType(Class);
    const method_name = StringName.fromComptimeLatin1(config.name);

    classdb.registerMethod(Class, void, class_name, .{
        .name = method_name,
        .flags = config.flags,
        .return_value_info = config.return_value_info,
        .return_value_metadata = config.return_value_metadata,
        .argument_info = config.argument_info,
        .argument_metadata = config.argument_metadata,
        .default_arguments = config.default_arguments,
    }, .{
        .call = config.call,
        .ptr_call = config.ptr_call,
    });
}

pub fn MethodConfig(comptime Class: type) type {
    return struct {
        name: [:0]const u8,
        return_type: type = void,
        flags: MethodFlags = .{},
        return_value_info: ?*classdb.PropertyInfo = null,
        return_value_metadata: classdb.MethodArgumentMetadata = .none,
        argument_info: []const classdb.PropertyInfo = &.{},
        argument_metadata: []const classdb.MethodArgumentMetadata = &.{},
        default_arguments: []const *const Variant = &.{},
        call: ?classdb.Call(Class, void) = null,
        ptr_call: ?classdb.PtrCall(Class, void) = null,

        const Self = @This();

        /// Creates a MethodConfig from a method name and decl name.
        /// The name is what Godot sees (snake_case), decl_name is the Zig decl.
        pub fn fromName(comptime name: [:0]const u8, comptime decl_name: [:0]const u8, comptime options: Registry.Method(Class).CreateOptions) Self {
            const MethodType = @TypeOf(@field(Class, decl_name));
            const fn_info = @typeInfo(MethodType).@"fn";
            const Args = fn_info.params;
            const ReturnType = fn_info.return_type orelse void;
            const arg_count = Args.len - 1;

            const return_value: classdb.PropertyInfo = .{
                .type = .forType(ReturnType),
                .usage = variantUsage(ReturnType),
            };

            const arg_infos: [arg_count]classdb.PropertyInfo = comptime blk: {
                var infos: [arg_count]classdb.PropertyInfo = undefined;
                for (0..arg_count) |i| {
                    const ArgType = Args[i + 1].type.?;
                    infos[i] = .{ .type = .forType(ArgType), .usage = variantUsage(ArgType) };
                }
                break :blk infos;
            };

            const arg_metas: [arg_count]classdb.MethodArgumentMetadata = comptime blk: {
                var metas: [arg_count]classdb.MethodArgumentMetadata = undefined;
                for (0..arg_count) |i| {
                    metas[i] = .none;
                }
                break :blk metas;
            };

            const Callbacks = struct {
                const method = @field(Class, decl_name);

                fn call(instance: *Class, args: []const *const Variant) gdzig.CallError!Variant {
                    const guard = DispatchGuard.enter(instance);
                    defer guard.leave();
                    // Rejected rather than run short: a missing argument used to
                    // leave its slot `undefined`, which Debug fills with 0xAA.
                    // A method taking an `i64` then ran with a huge negative
                    // number and whatever it did with it -- add it to a score,
                    // index with it -- failed somewhere else entirely.
                    if (args.len < arg_count) return error.TooFewArguments;

                    var call_args: std.meta.ArgsTuple(MethodType) = undefined;
                    call_args[0] = instance;
                    inline for (1..Args.len) |i| {
                        const ArgType = Args[i].type.?;
                        call_args[i] = args[i - 1].as(ArgType) orelse return error.InvalidArgument;
                    }
                    if (ReturnType == void) {
                        @call(.auto, method, call_args);
                        return Variant.nil;
                    } else {
                        const result = @call(.auto, method, call_args);
                        return Variant.init(ReturnType, result);
                    }
                }

                fn ptrCall(instance: *Class, args: [*]const *const anyopaque, ret: ?*anyopaque) void {
                    const guard = DispatchGuard.enter(instance);
                    defer guard.leave();
                    var call_args: std.meta.ArgsTuple(MethodType) = undefined;
                    call_args[0] = instance;
                    inline for (1..Args.len) |i| {
                        const ArgType = Args[i].type.?;
                        call_args[i] = ptrToArg(ArgType, args[i - 1]);
                    }
                    if (ReturnType == void) {
                        @call(.auto, method, call_args);
                    } else {
                        const result = @call(.auto, method, call_args);
                        if (ret) |r| {
                            ptrcall.writeReturn(ReturnType, r, result);
                        }
                    }
                }

                /// A standard ptrcall hands every object argument over as
                /// `T**`, refcounted or not -- the `Ref<T>*` form is specific to
                /// virtuals, which go through `ptrcall.readVirtualArg` instead.
                /// `readArg` dereferences, which is the same thing the generated
                /// outgoing calls encode: `args[0] = @ptrCast(&p_node)`.
                fn ptrToArg(comptime ArgType: type, p_arg: *const anyopaque) ArgType {
                    return ptrcall.readArg(ArgType, p_arg);
                }
            };

            return .{
                .name = name,
                .return_type = ReturnType,
                .flags = options.flags,
                .return_value_info = if (ReturnType != void) @constCast(&return_value) else null,
                .argument_info = @constCast(&arg_infos),
                .argument_metadata = @constCast(&arg_metas),
                .default_arguments = options.default_arguments,
                .call = Callbacks.call,
                .ptr_call = Callbacks.ptrCall,
            };
        }

        /// Creates a getter method for a class field.
        /// name: the method name Godot sees (e.g., "get_health")
        /// field_name: the Zig field name (e.g., "health")
        pub fn getter(comptime name: [:0]const u8, comptime field_name: [:0]const u8) Self {
            const FieldType = @FieldType(Class, field_name);

            const return_value: classdb.PropertyInfo = .{
                .type = .forType(FieldType),
                .usage = variantUsage(FieldType),
            };

            const Callbacks = struct {
                fn call(instance: *Class, _: []const *const Variant) gdzig.CallError!Variant {
                    const guard = DispatchGuard.enter(instance);
                    defer guard.leave();
                    return Variant.init(FieldType, @field(instance, field_name));
                }

                fn ptrCall(instance: *Class, _: [*]const *const anyopaque, ret: ?*anyopaque) void {
                    const guard = DispatchGuard.enter(instance);
                    defer guard.leave();
                    if (ret) |r| {
                        ptrcall.writeReturn(FieldType, r, @field(instance, field_name));
                    }
                }
            };

            return .{
                .name = name,
                .return_type = FieldType,
                .return_value_info = @constCast(&return_value),
                .call = Callbacks.call,
                .ptr_call = Callbacks.ptrCall,
            };
        }

        /// Creates a setter method for a class field.
        /// name: the method name Godot sees (e.g., "set_health")
        /// field_name: the Zig field name (e.g., "health")
        pub fn setter(comptime name: [:0]const u8, comptime field_name: [:0]const u8) Self {
            const FieldType = @FieldType(Class, field_name);

            const arg_info: [1]classdb.PropertyInfo = .{.{
                .type = .forType(FieldType),
                .usage = variantUsage(FieldType),
            }};
            const arg_meta: [1]classdb.MethodArgumentMetadata = .{.none};

            const Callbacks = struct {
                fn call(instance: *Class, args: []const *const Variant) gdzig.CallError!Variant {
                    const guard = DispatchGuard.enter(instance);
                    defer guard.leave();
                    if (args.len < 1) return error.TooFewArguments;
                    const value = args[0].as(FieldType) orelse return error.InvalidArgument;
                    @field(instance, field_name) = value;
                    return Variant.nil;
                }

                fn ptrCall(instance: *Class, args: [*]const *const anyopaque, _: ?*anyopaque) void {
                    const guard = DispatchGuard.enter(instance);
                    defer guard.leave();
                    @field(instance, field_name) = ptrcall.readArg(FieldType, args[0]);
                }
            };

            return .{
                .name = name,
                .argument_info = @constCast(&arg_info),
                .argument_metadata = @constCast(&arg_meta),
                .call = Callbacks.call,
                .ptr_call = Callbacks.ptrCall,
            };
        }
    };
}
