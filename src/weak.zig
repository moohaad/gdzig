//! Liveness-checked handles to Godot objects.
//!
//! A bare `*Node` says nothing about whether the node still exists. Free it --
//! `destroy`, `queueFree`, or the scene tree tearing down around you -- and the
//! pointer is dangling with no way to tell. `Weak(T)` pairs the pointer with the
//! object's instance ID, which Godot can resolve independently, so asking
//! whether the object is still there costs a lookup instead of a crash.
//!
//! ```zig
//! var handle: Weak(Node) = .init(node);
//! node.queueFree();
//! // ... a frame later ...
//! if (handle.get()) |live| live.setName(name);   // skipped; the node is gone
//! ```
//!
//! ## Why this and not a borrow checker
//!
//! godot-rust guards the same territory with `godot-cell`, which lets a `&mut`
//! be reborrowed during re-entrant engine calls by marking the outer reference
//! *inaccessible* for the duration. That construction is only sound because Rust
//! can guarantee an inaccessible reference is never read or written. Zig has no
//! such notion and no way to intercept a dereference, so the technique does not
//! port, and this is deliberately the smaller guarantee:
//!
//! * **Covered:** the object was freed and you still hold a pointer. This is the
//!   failure that actually corrupts memory, and it is now a `null` you can
//!   branch on rather than undefined behaviour.
//! * **Not covered:** two live pointers to one object during re-entrancy. Godot
//!   re-enters routinely and legitimately -- emit a signal, and a handler can
//!   call straight back into the emitting object -- so flagging it would be
//!   noise, and Zig cannot make the outer pointer unusable the way Rust can.
//!
//! ## What it costs and does not do
//!
//! `get` is an `object_get_instance_from_id` lookup, so it is not free; hold the
//! result for the duration of a call rather than re-checking per field access.
//!
//! A `Weak(T)` does not keep anything alive. On a `RefCounted` it is genuinely
//! weak -- if the last [`Gd`](gd.zig) releases, the handle goes dead, which is
//! what you want for a back-reference that must not form a cycle. Use `Gd(T)`
//! when you need the object to stay.
//!
//! Validity is a snapshot. `get` tells you the object was alive at that moment;
//! anything you call afterwards can still free it.

const std = @import("std");

const oopz = @import("oopz");

const gdzig = @import("gdzig");
const class = @import("class.zig");
const Object = class.Object;

/// A non-owning handle to a `T` that knows whether the object is still alive.
///
/// `T` may be any class. Unlike [`Gd`](gd.zig) this does not require
/// `RefCounted`, because it holds no reference -- which is the point, since
/// `Node` and friends are exactly the types with no refcount to lean on.
pub fn Weak(comptime T: type) type {
    comptime oopz.assertIsA(Object, T);

    return struct {
        const Self = @This();

        ptr: *T,
        /// The engine object behind `ptr`. For an opaque class that is `ptr`
        /// itself; for a class defined in an extension it is the `base` field,
        /// since the surrounding struct is not a Godot object and casting it to
        /// one yields a garbage instance ID and a handle that is dead the
        /// moment it is made.
        obj: *Object,
        /// Godot's ID for the object, unique among *live* objects. Recorded at
        /// construction, when the object is known good.
        id: u64,

        /// Records `ptr` and its current instance ID. The object must be alive
        /// now; reading the ID is a dereference.
        pub fn init(ptr: *T) Self {
            const obj = oopz.upcast(*Object, ptr);
            return .{
                .ptr = ptr,
                .obj = obj,
                .id = gdzig.raw.objectGetInstanceId(@ptrCast(obj)),
            };
        }

        /// The pointer if the object is still alive, otherwise null.
        pub fn get(self: Self) ?*T {
            const live = gdzig.raw.objectGetInstanceFromId(self.id) orelse return null;

            // Belt and braces. Godot packs a validator counter into the high
            // bits of an instance ID, so a freed ID is not handed out again --
            // measured at zero collisions over repeated create/destroy cycles,
            // with each new ID a fixed step above the last. The lookup alone is
            // therefore enough today; comparing the pointer costs nothing and
            // keeps this correct if that ever stops being true.
            if (@intFromPtr(live) != @intFromPtr(self.obj)) return null;

            return self.ptr;
        }

        /// The pointer, panicking if the object has been freed. For call sites
        /// where a dead object is a bug rather than a case to handle.
        pub fn expect(self: Self) *T {
            return self.get() orelse @panic("Weak handle used after the object was freed");
        }

        /// Whether the object is still alive.
        pub fn isValid(self: Self) bool {
            return self.get() != null;
        }

        /// The recorded instance ID, live or not. Stays readable after the
        /// object is gone, which makes it usable as a key or for logging.
        pub fn instanceId(self: Self) u64 {
            return self.id;
        }

        /// Reinterprets the handle as one for an ancestor type. Compile error if
        /// `U` is not a base of `T`.
        pub fn upcast(self: Self, comptime U: type) Weak(U) {
            comptime oopz.assertIsA(U, T);
            return .{ .ptr = oopz.upcast(*U, self.ptr), .obj = self.obj, .id = self.id };
        }
    };
}

test "a weak handle needs no live engine to be constructed comptime-correct" {
    // Behaviour against a real object is covered in test/weak, which has an
    // engine; this only pins the type-level contract.
    std.testing.refAllDecls(@This());
    comptime {
        const W = Weak(gdzig.class.Node);
        if (@FieldType(W, "ptr") != *gdzig.class.Node) @compileError("ptr field changed shape");
        if (@FieldType(W, "obj") != *Object) @compileError("obj field changed shape");
        if (@FieldType(W, "id") != u64) @compileError("id field changed shape");
    }
}
