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
//! * A method **taking** a refcounted class takes `*T`. Godot takes
//!   `const Ref<T>&`, which borrows; the caller keeps ownership.
//!
//! ```zig
//! var tex = ResourceLoader.load(path, .{}).?;
//! defer tex.deinit();
//! tex.get().someMethod();
//! ```
//!
//! Constructors are the exception: `T.init()` still returns `*T`, even for a
//! refcounted `T`. Wrap one with `Gd(T).adopt` if you want a handle.
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
//! released and panics on a second `deinit`, which turns the copy mistake above
//! from silent corruption into an immediate, located failure. Leaks are not
//! detected here.

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

/// An owning handle to a reference-counted `T`.
///
/// `T` must inherit from `RefCounted`; anything else is a compile error, since
/// non-refcounted objects have no reference for this handle to own.
pub fn Gd(comptime T: type) type {
    comptime oopz.assertIsA(RefCounted, T);

    return struct {
        const Self = @This();

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
        pub fn borrow(ptr: *T) Self {
            _ = RefCounted.upcast(ptr).reference();
            return .{ .ptr = ptr };
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
            if (RefCounted.upcast(self.ptr).unreference()) self.ptr.destroy();
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
