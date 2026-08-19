/// A `Callable` for one of `p_instance`'s own methods, named by pointer rather
/// than by string.
///
/// Despite the name this captures nothing. It resolves `p_function_ptr` to the
/// method's registered name at comptime and returns an ordinary by-name
/// `Callable`, identical to writing:
///
/// ```zig
/// Callable.initObjectMethod(Object.upcast(self), .fromComptimeLatin1("game_over"))
/// ```
///
/// What it buys is the string: rename the method and every connection follows,
/// where a hand-written name would have failed at runtime.
///
/// The handler must be a `pub` method of `p_instance`'s type -- the scan reads
/// public declarations, so a private one is invisible to it -- and it must be
/// registered with `addMethod`, since Godot dispatches it by name. The first is
/// a compile error; the second cannot be, because registration happens at
/// runtime.
pub fn fromClosure(p_instance: anytype, comptime p_function_ptr: anytype) Callable {
    // Through `asPtr` first: `p_instance` may be an owning handle, and
    // `std.meta.Child` of a `Gd(T)` is a struct field's type, not the class.
    const instance = gdzig.class.asPtr(p_instance);
    const T = comptime std.meta.Child(@TypeOf(instance));

    // Which of `T`'s methods is this pointer? Entirely comptime, so a miss is a
    // mistake in the source and fails the build rather than waiting to panic at
    // the connection.
    const method_name: [:0]const u8 = comptime blk: {
        const wanted: *const anyopaque = @ptrCast(p_function_ptr);
        for (std.meta.declarations(T)) |decl| {
            const decl_value = @field(T, decl.name);
            if (@typeInfo(@TypeOf(decl_value)) != .@"fn") continue;
            if (@as(*const anyopaque, @ptrCast(&decl_value)) != wanted) continue;
            break :blk std.fmt.comptimePrint("{s}", .{casez.comptimeConvert(godot_case.method, decl.name)});
        }
        @compileError("'" ++ @typeName(T) ++ "' has no public method with that address. " ++
            "`fromClosure` matches the function pointer against public declarations, " ++
            "so a handler declared `fn` rather than `pub fn` cannot be found.");
    };

    // Borrowed from the intern cache, hence `*const` and hence not destroyed --
    // this once released a reference it never took. The two `.*` below copy the
    // handle for engine calls that take one by value; those copies are borrows
    // too, and go out of scope without being destroyed.
    const method_string_name = StringName.fromComptimeLatin1(method_name);

    const obj = gdzig.class.upcast(*Object, instance);

    if (!obj.hasMethod(method_string_name.*)) {
        std.debug.panic("Method '{s}' is not registered on type '{s}'. Did you forget to call godot.registerMethod?", .{ method_name, @typeName(T) });
    }

    return .initObjectMethod(obj, method_string_name.*);
}

const casez = @import("casez");
const common = @import("common");
const godot_case = common.godot_case;

// @mixin stop

const Self = gdzig.builtin.Callable;

const std = @import("std");

const gdzig = @import("gdzig");
const Callable = gdzig.builtin.Callable;
const StringName = gdzig.builtin.StringName;
const Object = gdzig.class.Object;
