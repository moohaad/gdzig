pub const VTable = @import("class/vtable.zig").VTable;

// oopz re-exports
const oopz = @import("oopz");
pub const assertIsA = oopz.assertIsA;
pub const assertIsAny = oopz.assertIsAny;
pub const isClass = oopz.isClass;
pub const isOpaqueClass = oopz.isOpaqueClass;
pub const isStructClass = oopz.isStructClass;
pub const isClassPtr = oopz.isClassPtr;
pub const isOpaqueClassPtr = oopz.isOpaqueClassPtr;
pub const isStructClassPtr = oopz.isStructClassPtr;
pub const BaseOf = oopz.BaseOf;
pub const depthOf = oopz.depthOf;
pub const ancestorsOf = oopz.ancestorsOf;
pub const selfAndAncestorsOf = oopz.selfAndAncestorsOf;
pub const isA = oopz.isA;
pub const isAny = oopz.isAny;
/// Reinterprets a class pointer as one of its ancestors, checked at comptime.
///
/// Free: it validates ancestry, constness and optionality and then emits
/// nothing. What it is not is a conversion you generally have to write.
///
/// **Usually unnecessary.** Every generated class parameter is `anytype` and
/// upcasts on the way in, so a derived pointer already fits:
///
/// ```zig
/// host.addChild(player, .{});     // `player` is a *CharacterBody2d
/// ```
///
/// **Necessary where a declared type demands it**, because Zig has no implicit
/// pointer coercion and only a parameter can be `anytype`:
///
/// ```zig
/// shooter: *Node,                                  // a struct field
/// const source: *Node = self.a_owner orelse Node.upcast(self.base);
/// var v: Variant = .init(?*Node, Node.upcast(self.base));  // the type is the argument
/// ```
///
/// A struct field cannot be `anytype`, an annotation is a promise about a
/// concrete type, and `Variant.init` takes the type as its first argument. Those
/// three are the whole remaining set; a call into a generated method is not one
/// of them.
pub const upcast = oopz.upcast;

/// Returns true if a type is a reference counted type.
///
/// Expects a class type, e.g. `Node` or `MyClass`, not `*Node` or `*MyClass`.
pub fn isRefCounted(comptime T: type) bool {
    return isA(RefCounted, T);
}

/// Returns true if a type is a pointer to a reference counted type.
///
/// Expects a pointer type, e.g. `*Node` or `*MyClass`, not `Node` or `MyClass`.
pub fn isRefCountedPtr(comptime T: type) bool {
    if (@typeInfo(T) != .pointer) return false;
    return isRefCounted(std.meta.Child(T));
}

/// Narrows `value` to `*T`, whichever kind of class `T` is.
///
/// Engine classes are opaque and carry their own `downcast`; a class defined in
/// an extension is a plain struct reached through its instance binding. Callers
/// should not have to know which they are holding, and before this they did --
/// the same six lines were written out at every site that needed it.
///
/// Null when `value` is not a `T`.
pub fn castTo(comptime T: type, value: anytype) ?*T {
    if (comptime isStructClass(T)) {
        return upcast(*Object, value).asInstance(T);
    }
    return T.downcast(value);
}

/// Downcast a value to a child type in the class hierarchy. Has some compile time checks, but returns null at runtime if the cast fails.
///
/// Expects pointer types, e.g `*Node` or `*MyClass`, not `Node` or `MyClass`.
pub fn downcast(comptime T: type, value: anytype) ?*std.meta.Child(T) {
    const Target = std.meta.Child(T);

    if (!isClassPtr(T)) {
        @compileError("downcast expects a class pointer type as the target type, found '" ++ @typeName(T) ++ "'");
    }

    const Source = switch (@typeInfo(@TypeOf(value))) {
        .optional => |info| std.meta.Child(info.child),
        .pointer => |info| info.child,
        else => @compileError("downcast expects a pointer type as the source value, found '" ++ @typeName(@TypeOf(value)) ++ "'"),
    };

    assertIsA(Source, Target);

    if (@typeInfo(@TypeOf(value)) == .optional and value == null) {
        return null;
    }

    const name = StringName.fromType(Target);
    const tag = raw.classdbGetClassTag(@ptrCast(name));
    const result = raw.objectCastTo(@ptrCast(value), tag);

    if (result) |ptr| {
        if (isOpaqueClassPtr(T)) {
            return @ptrCast(@alignCast(ptr));
        } else {
            const obj: *anyopaque = raw.objectGetInstanceBinding(ptr, raw.library, null) orelse return null;
            return @ptrCast(@alignCast(obj));
        }
    } else {
        return null;
    }
}

const std = @import("std");
const gdzig = @import("gdzig");
const raw = &gdzig.raw;
const StringName = gdzig.builtin.StringName;

// @mixin stop

const Object = gdzig.class.Object;
const RefCounted = gdzig.class.RefCounted;
