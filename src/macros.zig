const std = @import("std");
const gdzig = @import("gdzig.zig");
const NodePath = gdzig.builtin.NodePath;
const String = gdzig.builtin.String;
const Callable = gdzig.builtin.Callable;
const Variant = gdzig.builtin.Variant;

/// Formats a Zig string and prints it to the Godot console.
/// Uses a 16KB static buffer, so it is allocation-free and very fast!
pub fn print(comptime fmt: []const u8, args: anytype) void {
    var buf: [16384]u8 = undefined;
    const formatted = std.fmt.bufPrint(&buf, fmt, args) catch |err| switch (err) {
        error.NoSpaceLeft => blk: {
            // If it overflows, just print as much as we can fit.
            break :blk buf[0..buf.len];
        },
    };

    var gd_str = String.fromLatin1(formatted);
    defer gd_str.deinit();

    const variant = Variant.init(String, gd_str);
    defer variant.deinit();

    gdzig.general.printAlloc(variant, .{});
}

/// Creates a Godot Callable from an arbitrary Zig function.
/// The context struct must be allocated on the heap (using the provided allocator) 
/// because Godot takes ownership of its lifetime and will free it when the Callable is destroyed.
pub fn callable(allocator: std.mem.Allocator, ctx: anytype, comptime func: anytype) Callable {
    const ContextType = @TypeOf(ctx);
    
    const Wrapper = struct {
        allocator: std.mem.Allocator,
        user_ctx: ContextType,

        fn call(
            userdata: ?*anyopaque,
            argv: [*c]const gdzig.c.GDExtensionConstVariantPtr,
            argc: gdzig.c.GDExtensionInt,
            ret: gdzig.c.GDExtensionVariantPtr,
            err: [*c]gdzig.c.GDExtensionCallError,
        ) callconv(.c) void {
            if (err) |e| e.* = .{ .@"error" = gdzig.c.GDEXTENSION_CALL_OK, .argument = 0, .expected = 0 };

            const self: *@This() = @ptrCast(@alignCast(userdata.?));
            
            // Unpack arguments
            const FuncType = @TypeOf(func);
            const func_info = @typeInfo(FuncType).@"fn";
            const params = func_info.params;
            
            // Expected params: [0] context, [1..] args
            if (argc != params.len - 1) {
                if (err) |e| e.* = .{ .@"error" = gdzig.c.GDEXTENSION_CALL_ERROR_INVALID_ARGUMENT, .argument = 0, .expected = @intCast(params.len - 1) };
                return;
            }

            var args: std.meta.ArgsTuple(FuncType) = undefined;
            args[0] = self.user_ctx;
            
            inline for (params[1..], 0..) |param, i| {
                const arg_variant: *const Variant = @ptrCast(@alignCast(argv[i]));
                args[i + 1] = arg_variant.as(param.type orelse @compileError("missing arg type")) orelse return; // In case of failed cast, abort
            }

            const result = @call(.auto, func, args);
            
            if (func_info.return_type != void) {
                const ret_variant: *Variant = @ptrCast(@alignCast(ret));
                // we assume return type can be converted to Variant via init
                ret_variant.* = Variant.init(func_info.return_type, result);
            }
        }

        fn isValid(userdata: ?*anyopaque) callconv(.c) gdzig.c.GDExtensionBool {
            _ = userdata;
            return 1;
        }

        fn free(userdata: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(userdata.?));
            self.allocator.destroy(self);
        }
    };

    const wrapper = allocator.create(Wrapper) catch @panic("OOM");
    wrapper.* = .{
        .allocator = allocator,
        .user_ctx = ctx,
    };

    var info: gdzig.c.GDExtensionCallableCustomInfo2 = std.mem.zeroes(gdzig.c.GDExtensionCallableCustomInfo2);
    info.callable_userdata = @ptrCast(wrapper);
    info.token = gdzig.raw.library;
    info.call_func = Wrapper.call;
    info.is_valid_func = Wrapper.isValid;
    info.free_func = Wrapper.free;

    var out_callable: Callable = undefined;
    gdzig.raw.callableCustomCreate2.?(@ptrCast(&out_callable), &info);
    return out_callable;
}

/// Queries the SceneTree for nodes in the given group, filters out any nodes that
/// are not instances of `T`, and returns them as a strongly-typed ArrayList.
pub fn getNodesInGroupAs(
    tree: *gdzig.class.SceneTree,
    comptime T: type,
    group: [:0]const u8,
    allocator: std.mem.Allocator,
) !std.ArrayList(*T) {
    var group_name = gdzig.builtin.StringName.fromLatin1(group, false);
    defer group_name.deinit();

    var array = tree.getNodesInGroup(group_name);
    defer array.deinit();

    var list: std.ArrayList(*T) = .empty;
    errdefer list.deinit(allocator);

    var i: i64 = 0;
    while (i < array.size()) : (i += 1) {
        var variant = array.get(i);
        defer variant.deinit();

        if (variant.as(*gdzig.class.Node)) |node| {
            if (node.asInstance(T)) |instance| {
                try list.append(allocator, instance);
            }
        }
    }

    return list;
}
