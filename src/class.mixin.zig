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
///
/// ## Owning handles go in directly
///
/// A `Gd(T)` or `?Gd(T)` is accepted wherever the pointer is, so a handle needs
/// no `get()` to be passed:
///
/// ```zig
/// var tex = godot.load(Texture2d, "res://logo.png").?;
/// defer tex.deinit();
/// sprite.setTexture(tex);          // not tex.get()
/// ```
///
/// This **borrows**. The handle keeps its reference and still owes a `deinit`,
/// exactly as writing `tex.get()` would -- passing a handle never hands
/// ownership to the callee, because the generated parameter is a plain pointer
/// and Godot's own convention for a class argument is `const Ref<T>&`.
///
/// The unwrap goes through `get()`, so a handle used after release panics here
/// rather than passing a dangling pointer on to the engine.
pub inline fn upcast(comptime T: type, value: anytype) T {
    return oopz.upcast(T, asPtr(value));
}

/// The plain pointer inside `value`, which may already be one.
///
/// The one place an owning handle is turned back into a borrowed pointer for
/// the engine. Anything that accepts `anytype` and means "some object" should
/// run its argument through this rather than reaching for `std.meta.Child`,
/// which sees a `Gd(T)` as a struct and fails.
///
/// Borrows: the handle keeps its reference. Goes through `get()`, so using one
/// after release panics here instead of handing the engine a dangling pointer.
pub inline fn asPtr(value: anytype) PtrOf(@TypeOf(value)) {
    const V = @TypeOf(value);
    if (comptime gd.isGd(V)) return value.get();
    if (comptime gd.OptionalGd(V) != null) return if (value) |handle| handle.get() else null;
    return value;
}

/// What [`asPtr`](#asPtr) gives back for `V`: the pointer a handle wraps, or
/// `V` unchanged when it is not a handle.
pub fn PtrOf(comptime V: type) type {
    if (gd.isGd(V)) return *V.Owns;
    if (gd.OptionalGd(V)) |Handle| return ?*Handle.Owns;
    return V;
}

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

/// Reports a vararg call the engine refused.
///
/// Every generated `call`/`callAlloc`/`emit` fills a `GDExtensionCallError` and
/// used to drop it, so a rejected call returned `nil` and looked like a method
/// that did nothing. That is a bad half-hour: the call site is correct Zig, the
/// build is clean, and the only symptom is a null.
///
/// Logged rather than returned, for the same reason `connect` logs: these are
/// vararg entry points whose signatures cannot grow an error set without
/// touching every call site, and every failure here is a programming mistake
/// rather than a case to branch on.
pub fn reportCallError(comptime what: []const u8, err: c.GDExtensionCallError) void {
    if (err.@"error" == c.GDEXTENSION_CALL_OK) return;
    const reason: []const u8 = switch (err.@"error") {
        c.GDEXTENSION_CALL_ERROR_INVALID_METHOD => "no such method",
        c.GDEXTENSION_CALL_ERROR_INVALID_ARGUMENT => "wrong argument type",
        c.GDEXTENSION_CALL_ERROR_TOO_MANY_ARGUMENTS => "too many arguments",
        c.GDEXTENSION_CALL_ERROR_TOO_FEW_ARGUMENTS => "too few arguments",
        c.GDEXTENSION_CALL_ERROR_INSTANCE_IS_NULL => "instance is null",
        c.GDEXTENSION_CALL_ERROR_METHOD_NOT_CONST => "method is not const",
        else => "refused",
    };
    std.log.err(
        "{s}: {s} (code {d}, argument {d}, expected type {d}); the call returned nil",
        .{ what, reason, err.@"error", err.argument, err.expected },
    );
}

/// Narrows `value` to `*T`, whichever kind of class `T` is.
///
/// Engine classes are opaque and carry their own `downcast`; a class defined in
/// an extension is a plain struct reached through its instance binding. Callers
/// should not have to know which kind **`T`** is, and before this they did --
/// the same six lines were written out at every site that needed it.
///
/// Null when `value` is not a `T`.
///
/// ## The source side needs no such care, and here is why
///
/// Only the target's kind is branched on, which looks like an omission: for a
/// user class, `value`'s own address is not the engine object's, so handing it
/// to the engine unexamined would be wrong. It cannot happen. Narrowing means
/// `T` derives from what you are holding, and:
///
/// * `T` a user class takes the first arm, where `upcast` reads the `base`
///   field and finds the engine object. Correct.
/// * `T` an engine class cannot derive from a user class, so `T.downcast`'s
///   ancestry assertion rejects that pair at compile time -- verified:
///   `castTo(Node2d, some_user_ptr)` is `expected type 'ClassC', found
///   'Node2d'`, raised before any pointer is passed.
///
/// So the only source that reaches `T.downcast` is an engine pointer, where the
/// address is the same at every level and the cast is right. Widening is
/// `upcast`'s job, not this one's.
pub fn castTo(comptime T: type, value: anytype) ?*T {
    if (comptime isStructClass(T)) {
        return upcast(*Object, value).asInstance(T);
    }
    return T.downcast(value);
}

const std = @import("std");
const c = @import("gdextension");
const gd = @import("gd.zig");
const gdzig = @import("gdzig");

// @mixin stop

const Object = gdzig.class.Object;
const RefCounted = gdzig.class.RefCounted;
