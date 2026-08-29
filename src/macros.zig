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
    const formatted = render(&buf, fmt, args);

    var gd_str = String.fromLatin1(formatted);
    defer gd_str.deinit();

    const variant = Variant.init(String, gd_str);
    defer variant.deinit();

    gdzig.general.printAlloc(variant, .{});
}

/// Formats into `buf`, or says why it could not.
///
/// Split out from `print` so it can be tested without an engine, and because
/// the overflow case is easy to get wrong: `bufPrint` does not report how much
/// it wrote before running out, so everything past that point is `undefined`.
/// Returning the whole buffer -- which is what "print as much as fits" turns
/// into -- puts uninitialised stack bytes in the console. Measuring first
/// avoids ever reading them.
fn render(buf: []u8, comptime fmt: []const u8, args: anytype) []const u8 {
    const needed = std.fmt.count(fmt, args);
    if (needed <= buf.len) {
        return std.fmt.bufPrint(buf, fmt, args) catch unreachable;
    }
    return std.fmt.bufPrint(
        buf,
        "<gdzig.print: {d}-byte message does not fit in {d} bytes>",
        .{ needed, buf.len },
    ) catch buf[0..0];
}

test "render formats, and refuses to hand back uninitialised bytes" {
    var buf: [64]u8 = undefined;

    try std.testing.expectEqualStrings("health 42", render(&buf, "health {d}", .{42}));

    // Too long to fit. The result must be the notice, not the buffer: returning
    // `buf[0..buf.len]` here is what the original did, and it leaks whatever was
    // on the stack.
    const long = "x" ** 500;
    const got = render(&buf, "{s}", .{long});
    try std.testing.expect(got.len < buf.len);
    try std.testing.expect(std.mem.startsWith(u8, got, "<gdzig.print:"));
    try std.testing.expect(std.mem.indexOf(u8, got, "500") != null);
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
            
            // `return_type` is `?type`: null for a generic function, which
            // cannot be wrapped because there is nothing to convert.
            const Ret = comptime func_info.return_type orelse
                @compileError("godot.callable needs a function with a concrete return type");
            if (Ret != void) {
                const ret_variant: *Variant = @ptrCast(@alignCast(ret));
                ret_variant.* = Variant.init(Ret, result);
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
            if (gdzig.class.castTo(T, node)) |instance| {
                try list.append(allocator, instance);
            }
        }
    }
    return list;
}

pub fn getNodeAs(
    node: anytype,
    comptime T: type,
    path: []const u8,
) !?*T {
    var string = gdzig.builtin.String.fromLatin1(path);
    defer string.deinit();

    var p = gdzig.builtin.NodePath.fromString(string);
    defer p.deinit();

    if (node.getNodeOrNull(p)) |child| {
        if (gdzig.class.castTo(T, child)) |instance| {
            return instance;
        }
    }
    return null;
}

pub fn Pool(comptime T: type) type {
    return struct {
        const Self = @This();
        available: std.ArrayList(*T),
        allocator: std.mem.Allocator,
        
        pub fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
            var available = try std.ArrayList(*T).initCapacity(allocator, capacity);
            var alloc = allocator;
            for (0..capacity) |_| {
                if (comptime gdzig.class.isStructClass(T)) {
                    const item = try T.create(&alloc);
                    available.appendAssumeCapacity(item);
                } else {
                    const item = T.init();
                    available.appendAssumeCapacity(item);
                }
            }
            return .{
                .available = available,
                .allocator = allocator,
            };
        }
        
        pub fn acquire(self: *Self) !*T {
            if (self.available.pop()) |item| return item;
            if (comptime gdzig.class.isStructClass(T)) {
                return try T.create(&self.allocator);
            } else {
                return T.init();
            }
        }
        
        pub fn release(self: *Self, item: *T) void {
            self.available.append(self.allocator, item) catch {};
        }
        
        pub fn deinit(self: *Self) void {
            self.available.deinit(self.allocator);
        }
    };
}

pub fn EventBus(comptime SignalsTuple: anytype) type {
    return struct {
        const Self = @This();
        allocator: std.mem.Allocator,
        base: *gdzig.class.Node,
        
        pub const signals = SignalsTuple;
        
        pub fn create(allocator: *std.mem.Allocator) !*Self {
            const self = try allocator.create(Self);
            self.* = .{ 
                .allocator = allocator.*,
                .base = gdzig.class.Node.init() 
            };
            self.base.setInstance(Self, self);
            return self;
        }
        
        pub fn destroy(self: *Self, allocator: *std.mem.Allocator) void {
            self.base.destroy();
            allocator.destroy(self);
        }
    };
}

pub fn tween(node: anytype) ?TweenBuilder {
    if (node.createTween()) |tw| {
        return TweenBuilder{ .tween_inst = tw.get() };
    }
    return null;
}

pub const TweenBuilder = struct {
    tween_inst: *gdzig.class.Tween,

    pub fn property(self: @This(), target: anytype, property_name: anytype, final_val: anytype, duration: f64) @This() {
        var v = gdzig.builtin.Variant.init(@TypeOf(final_val), final_val);
        defer v.deinit();
        _ = self.tween_inst.tweenProperty(target, property_name, v, duration);
        return self;
    }

    pub fn propertyEx(self: @This(), target: anytype, property_name: anytype, final_val: anytype, duration: f64, trans: gdzig.class.Tween.TransitionType, ease: gdzig.class.Tween.EaseType) @This() {
        var v = gdzig.builtin.Variant.init(@TypeOf(final_val), final_val);
        defer v.deinit();
        if (self.tween_inst.tweenProperty(target, property_name, v, duration)) |pt| {
            _ = pt.get().setTrans(trans);
            _ = pt.get().setEase(ease);
        }
        return self;
    }

    pub fn interval(self: @This(), time: f64) @This() {
        _ = self.tween_inst.tweenInterval(time);
        return self;
    }

    pub fn callback(self: @This(), receiver: anytype, comptime method: anytype) @This() {
        const cb = gdzig.builtin.Callable.fromClosure(receiver, method);
        _ = self.tween_inst.tweenCallback(cb);
        return self;
    }
};

pub fn bindNodes(self: anytype) void {
    const Self = @TypeOf(self.*);
    if (!@hasDecl(Self, "bind_nodes")) return;
    
    inline for (Self.bind_nodes) |node_def| {
        const field_name = node_def[0];
        const path = node_def[1];
        
        const FieldType = @TypeOf(@field(self.*, field_name));
        const TargetType = if (@typeInfo(FieldType) == .optional) @typeInfo(FieldType).optional.child else FieldType;
        const StructType = if (@typeInfo(TargetType) == .pointer) @typeInfo(TargetType).pointer.child else TargetType;
        
        if (getNodeAs(self.base, StructType, path)) |child_opt| {
            if (child_opt) |child| {
                @field(self.*, field_name) = child;
            } else {
                gdzig.print("Warning: Auto-bind node not found at path '{s}'", .{path});
            }
        } else |err| {
            gdzig.print("Error auto-binding node at path '{s}': {}", .{path, err});
        }
    }
}

pub fn inEditor() bool {
    return gdzig.class.Engine.isEditorHint();
}

pub fn inGame() bool {
    return !inEditor();
}
