//! Owning handles for reference-counted Godot objects.
//!
//! `Gd(T)` pairs a `*T` with the reference it holds, so the
//! `if (obj.unreference()) obj.destroy()` dance lives in one place instead of at
//! every call site. Ownership also becomes visible in signatures: a `Gd(T)`
//! owns a reference, a plain `*T` borrows one.
//!
//! The generated bindings follow that convention, which mirrors what the engine
//! itself does across the ptrcall boundary:
//!
//! * A method **returning** a refcounted class returns `?Gd(T)`. Godot hands
//!   back a `Ref<T>` whose count it has already incremented for us, so the
//!   handle adopts that reference and the caller owes a `deinit`.
//! * A **constructor** for a refcounted class returns `Gd(T)`, owning the
//!   initial reference. Non-refcounted `T.init()` still returns `*T`; those
//!   objects are freed with `destroy`, not released.
//! * A method **taking** a refcounted class takes `*T`. Godot takes
//!   `const Ref<T>&`, which borrows; the caller keeps ownership.
//! * A **virtual you override** may return either. `*T` lends the engine an
//!   object you go on owning; `Gd(T)` hands yours over, which is what a virtual
//!   like `_instantiate_playback` that creates its result wants.
//!
//! ```zig
//! var tex = ResourceLoader.load(path, .{}).?;
//! defer tex.deinit();
//! tex.get().someMethod();
//! ```
//!
//! `release` is the way back out where a handle cannot go — a plain pointer
//! field, or an engine call that takes ownership:
//!
//! ```zig
//! var tex = ResourceLoader.load(path, .{}).?;
//! someOwningSink(tex.release());
//! ```
//!
//! One place it is *not* the answer is a registered class's `base` field. That
//! object goes straight back to Godot, which takes the first reference itself,
//! so referencing it here leaves one nobody drops. Let gdzig write `create`, or
//! call `extension.baseForEngine(Resource)`, which documents why.
//!
//! ## What this does not do
//!
//! Zig has no destructors and no way to intercept a struct copy, so this is a
//! discipline aid, not a safety guarantee like Rust's `Gd<T>`:
//!
//! * Release is not automatic. Every handle needs a matching `deinit`, normally
//!   via `defer`. Forgetting one leaks.
//! * Copying a handle copies the pointer without taking a reference, so both
//!   copies will release the same one. Use `clone` to share ownership, and pass
//!   handles by pointer rather than by value when handing them to a callee.
//!
//! In `Debug` and `ReleaseSafe` builds a handle tracks whether it has been
//! released and panics on any later use of *that same handle*:
//!
//! ```zig
//! var tex = ResourceLoader.load(path, .{}).?;
//! tex.deinit();
//! tex.get(); // panics, located
//! ```
//!
//! Be clear about what that does not cover: **it does not catch the copy
//! mistake above.** The flag lives in the handle, and a copy gets its own, so
//! `copy.deinit()` leaves the original reading un-released and its `deinit`
//! releases a second time with no panic -- measured, the reference count goes
//! to -1. Catching that needs state keyed on the object rather than the handle,
//! which is a side table this deliberately does not have.
//!
//! So: the tracking finds a handle used after you released it, not two handles
//! releasing the same object. Leaks are not detected here either.

const std = @import("std");
const builtin = @import("builtin");

const oopz = @import("oopz");

const class = @import("class.zig");
const RefCounted = class.RefCounted;

/// Whether handles carry release tracking. Enabled where safety checks are.
const track_release = switch (builtin.mode) {
    .Debug, .ReleaseSafe => true,
    .ReleaseFast, .ReleaseSmall => false,
};

/// Whether `T` is some `Gd(U)`.
///
/// Marshalling has to tell an owning handle from a borrowed pointer, because
/// the two mean opposite things about who owes a release. The cheap checks
/// come first so an unrelated struct that happens to declare `Owns` is
/// rejected before `Gd` is instantiated on it -- instantiating asserts
/// `RefCounted` ancestry, which would be a compile error rather than a false.
pub fn isGd(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    if (!@hasDecl(T, "Owns") or !@hasField(T, "ptr")) return false;
    if (@TypeOf(T.Owns) != type) return false;
    return T == Gd(T.Owns);
}

/// `Gd(U)` for a `?Gd(U)`, else null. The optional form is what a property
/// field wants, since Godot can hand it nothing.
pub fn OptionalGd(comptime T: type) ?type {
    const info = @typeInfo(T);
    if (info != .optional) return null;
    return if (isGd(info.optional.child)) info.optional.child else null;
}

/// Releases whatever an owning field holds, and leaves it holding nothing.
///
/// For where gdzig owns a reference on the user's behalf: a property field it
/// filled from a Variant, and that same field again at teardown. Clearing the
/// optional is the point -- a user `destroy` that also releases must find
/// nothing left to release. A non-optional `Gd` cannot be cleared, so a second
/// release there trips the use-after-release panic rather than corrupting,
/// which is the loudest outcome available.
pub fn releaseField(comptime T: type, field: *T) void {
    if (comptime isGd(T)) {
        field.deinit();
    } else if (comptime OptionalGd(T) != null) {
        if (field.*) |*handle| {
            handle.deinit();
            field.* = null;
        }
    }
}

/// The object inside an optional owning field, or null.
///
/// An exported resource is a `?Gd(T)`: gdzig references what it is given and
/// releases it at teardown. Reading one is almost always "the object, if there
/// is one", and a handle cannot say that itself -- `get` is a method, so the
/// optional has to be unwrapped before it can be called, and every read site
/// says so twice:
///
/// ```zig
/// if (self.enemy_data) |handle| {
///     const data = handle.get();
///     self.speed = data.speed;
/// }
/// ```
///
/// This is the same thing once:
///
/// ```zig
/// if (gd.get(self.enemy_data)) |data| self.speed = data.speed;
/// ```
///
/// The result borrows: it is valid while the field still holds the handle, and
/// must not be released. Deliberately named after the method it stands in for,
/// since it means exactly what that means.
pub fn get(handle: anytype) ?*Owned(@TypeOf(handle)) {
    const live = handle orelse return null;
    return live.get();
}

/// `T` for a `?Gd(T)`, and a diagnosis for anything else. Split out so the
/// error names the type the caller passed rather than failing inside
/// `@typeInfo` on a field access that does not exist.
fn Owned(comptime T: type) type {
    const handle = OptionalGd(T) orelse @compileError(
        "gd.get expects a ?Gd(T), got " ++ @typeName(T) ++
            (if (isGd(T))
                ". That handle is not optional, so it already has .get() on it."
            else
                ""),
    );
    return handle.Owns;
}

/// An owning handle to a reference-counted `T`.
///
/// `T` must inherit from `RefCounted`; anything else is a compile error, since
/// non-refcounted objects have no reference for this handle to own.
pub fn Gd(comptime T: type) type {
    comptime oopz.assertIsA(RefCounted, T);

    return struct {
        const Self = @This();

        /// The type this handle owns a reference to. Lets code that has to tell
        /// an owning handle from a borrowed pointer -- the virtual-return
        /// marshalling, for one -- recognise `Gd(T)` exactly, rather than by
        /// guessing from its shape.
        pub const Owns = T;

        ptr: *T,
        released: if (track_release) bool else void = if (track_release) false else {},

        /// Takes ownership of a pointer that already holds a reference, such as
        /// one returned by an engine call. Does not take an additional
        /// reference.
        pub fn adopt(ptr: *T) Self {
            return .{ .ptr = ptr };
        }

        /// Takes a new reference to `ptr` and returns a handle owning it. Use
        /// this for a borrowed pointer that must outlive its current owner.
        ///
        /// Takes `anytype` and upcasts, so holding a derived object at a base
        /// handle -- `Gd(Resource).borrow(some_texture)` -- needs no upcast
        /// spelled out. That matches the generated methods, which take
        /// `anytype` for every class parameter and upcast on the way in.
        /// `adopt` cannot follow: it is called as `Gd(T).adopt(@ptrCast(p))`
        /// throughout the generated bindings, and `@ptrCast` has no result
        /// type to infer once the parameter stops being `*T`.
        pub fn borrow(ptr: anytype) Self {
            const obj: *T = class.upcast(*T, ptr);
            _ = RefCounted.upcast(obj).reference();
            return .{ .ptr = obj };
        }

        /// Returns a second handle to the same object, taking a reference for
        /// it. Both handles must be released.
        pub fn clone(self: Self) Self {
            self.assertLive();
            _ = RefCounted.upcast(self.ptr).reference();
            return .{ .ptr = self.ptr };
        }

        /// Releases this handle's reference, destroying the object if it was
        /// the last one.
        pub fn deinit(self: *Self) void {
            self.assertLive();
            if (track_release) self.released = true;
            if (RefCounted.upcast(self.ptr).unreference()) {
                // Through the object, not `T.destroy`: for one of your own
                // registered classes that is the user's function and takes an
                // allocator, so calling it here would not compile. Freeing the
                // object runs it, with the allocator the registry holds. For an
                // engine class this is the same call `T.destroy` resolves to.
                class.Object.upcast(self.ptr).destroy();
            }
        }

        /// Borrows the pointer. The result is valid only while this handle is,
        /// and must not be released by the caller.
        pub fn get(self: Self) *T {
            self.assertLive();
            return self.ptr;
        }

        /// Gives up ownership and returns the pointer, which the caller becomes
        /// responsible for releasing. The handle must not be used afterwards.
        pub fn release(self: *Self) *T {
            self.assertLive();
            if (track_release) self.released = true;
            return self.ptr;
        }

        /// Reinterprets this handle as one for an ancestor type, keeping
        /// ownership. Fails at compile time if `U` is not a base of `T`.
        pub fn upcast(self: *Self, comptime U: type) Gd(U) {
            comptime oopz.assertIsA(U, T);
            self.assertLive();
            if (track_release) self.released = true;
            return .{ .ptr = @ptrCast(self.ptr) };
        }

        fn assertLive(self: Self) void {
            if (track_release and self.released) {
                @panic("Gd handle used after release; a copy of it was probably deinited");
            }
        }
    };
}

test "adopt and release a reference" {
    // Exercised against the engine in test/, since constructing a RefCounted
    // requires a live Godot process.
    std.testing.refAllDecls(@This());
}

test "reading an optional handle" {
    // Only the empty case can be built without a live Godot; the type is the
    // other half of the contract, and that is checkable here.
    const empty: ?Gd(RefCounted) = null;
    try std.testing.expectEqual(@as(?*RefCounted, null), get(empty));
    try std.testing.expectEqual(?*RefCounted, @TypeOf(get(empty)));
}
