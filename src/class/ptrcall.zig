/// Marshalling helpers for Godot's `ptrcall` ABI (used for virtual method
/// dispatch and for extension methods bound through ClassDB).
///
/// Per godot-cpp's `method_ptrcall.h` conventions, ptrcall does not pass
/// scalars at their declared C width. Instead:
///
/// - every integer type (bool included), and every enum or packed flag
///   struct narrower than 64 bits, travels as a full `int64_t` (8 bytes)
/// - `u64` (and enums/flags backed by `u64`) travels as `uint64_t`
/// - `bool` travels as `uint8_t`
/// - `f32` and `f64` both travel as `double` (8 bytes)
///
/// A Zig virtual method or bound method declared with a narrower type (say,
/// `i32` or `f32`) must still read/write the full slot width, or it will
/// read stack garbage out of the high bytes (params) or leave garbage in
/// the high bytes for the engine to read back (returns).
///
/// Non-scalar types (structs like `String`/`Vector2`, object pointers,
/// optionals of object pointers, etc.) are passed at their real, declared
/// layout and are read/written directly.
///
/// This is the runtime-side half of the ABI width rule; `wideSlot` in
/// `pkg/bindgen/codegen.zig` is the emission side, deciding which generated
/// call sites need a widened slot in the first place.
const std = @import("std");

const gd = @import("../gd.zig");
const gdzig = @import("gdzig");
const class = gdzig.class;

/// Reads a single ptrcall argument slot as `T`, applying the width conventions described
/// above. `raw_p_arg` accepts both the optional `GDExtensionConstTypePtr` the engine hands us
/// directly and the already-unwrapped `*const anyopaque` that higher-level callers may have
/// narrowed it to.
pub fn readArg(comptime T: type, raw_p_arg: ?*const anyopaque) T {
    const p_arg: *const anyopaque = @ptrCast(raw_p_arg);
    return switch (@typeInfo(T)) {
        .bool => @as(*const u8, @ptrCast(p_arg)).* != 0,
        .int => @intCast(readIntSlot(T, p_arg)),
        .float => @floatCast(@as(*const f64, @ptrCast(@alignCast(p_arg))).*),
        .@"enum" => |info| @enumFromInt(@as(info.tag_type, @intCast(readIntSlot(info.tag_type, p_arg)))),
        .@"struct" => |info| blk: {
            // An owning handle is not laid out like the object pointer the
            // engine puts in the slot: reading the struct raw would take the
            // pointer by luck and `released` from whatever follows it.
            if (comptime gd.isGd(T)) break :blk T.borrow(readArg(*T.Owns, p_arg));
            if (info.layout != .@"packed") break :blk @as(*const T, @ptrCast(@alignCast(p_arg))).*;
            const Backing = info.backing_integer.?;
            break :blk @bitCast(@as(Backing, @intCast(readIntSlot(Backing, p_arg))));
        },
        .optional => |info| blk: {
            if (comptime gd.OptionalGd(T)) |Handle| {
                const object = readArg(?*Handle.Owns, p_arg) orelse break :blk null;
                break :blk Handle.borrow(object);
            }
            if (comptime class.isStructClassPtr(info.child)) {
                const object = @as(*const ?*class.Object, @ptrCast(@alignCast(p_arg))).* orelse break :blk null;
                break :blk class.castTo(std.meta.Child(info.child), object);
            }
            break :blk @as(*const T, @ptrCast(@alignCast(p_arg))).*;
        },
        else => blk: {
            // The engine writes the *object* pointer into the slot. For an
            // engine class that is the declared pointer, so reading the slot as
            // `T` is right. For one of your classes it is not: the instance is
            // a Zig struct that holds the object, and reading the slot as `*T`
            // hands the method the engine object typed as its own class --
            // measured 1.5 MB apart, two separate allocations.
            if (comptime class.isStructClassPtr(T)) {
                const object = @as(*const ?*class.Object, @ptrCast(@alignCast(p_arg))).* orelse
                    @panic("gdzig: null object in a ptrcall slot declared non-optional");
                break :blk class.castTo(std.meta.Child(T), object) orelse
                    @panic("gdzig: ptrcall argument is not an instance of the declared class");
            }
            break :blk @as(*const T, @ptrCast(@alignCast(p_arg))).*;
        },
    };
}

/// Writes `value` (of declared type `T`) into a ptrcall return slot, applying the width
/// conventions described above. The full slot width is always written so no garbage remains
/// in the high bytes. `raw_p_ret` accepts both the optional `GDExtensionTypePtr` the engine
/// hands us directly and the already-unwrapped `*anyopaque` that higher-level callers may have
/// narrowed it to.
pub fn writeReturn(comptime T: type, raw_p_ret: ?*anyopaque, value: T) void {
    const p_ret: *anyopaque = @ptrCast(raw_p_ret);

    // An object return slot is one pointer wide whatever shape the declared
    // type has, and it wants the *engine object*.
    //
    // Two ways this went wrong. A `Gd(T)` is 16 bytes under safety checks and
    // 24 when optional, and the struct arm below wrote all of it into the
    // 8-byte slot -- the pointer landed by luck as the handle's first field and
    // the `released` flag overwrote the adjacent word. And a `*UserClass` is
    // the address of a Zig struct, not of the object the engine is expecting.
    if (comptime objectSlot(T)) |Kind| {
        const object: ?*class.Object = switch (Kind) {
            .handle => class.upcast(*class.Object, value.get()),
            .optional_handle => if (value) |handle| class.upcast(*class.Object, handle.get()) else null,
            .pointer => class.upcast(*class.Object, value),
            .optional_pointer => if (value) |ptr| class.upcast(*class.Object, ptr) else null,
        };
        @as(*?*class.Object, @ptrCast(@alignCast(p_ret))).* = object;
        return;
    }

    switch (@typeInfo(T)) {
        .bool => @as(*u8, @ptrCast(p_ret)).* = @intFromBool(value),
        .int => writeIntSlot(T, p_ret, value),
        .float => @as(*f64, @ptrCast(@alignCast(p_ret))).* = value,
        .@"enum" => |info| writeIntSlot(info.tag_type, p_ret, @intFromEnum(value)),
        .@"struct" => |info| {
            if (info.layout != .@"packed") {
                @as(*T, @ptrCast(@alignCast(p_ret))).* = value;
                return;
            }
            const Backing = info.backing_integer.?;
            writeIntSlot(Backing, p_ret, @as(Backing, @bitCast(value)));
        },
        else => @as(*T, @ptrCast(@alignCast(p_ret))).* = value,
    }
}

/// Which object-slot shape `T` is, or null if it is not an object at all.
///
/// Kept as one comptime question so `writeReturn` decides once, rather than
/// four `if`s that can drift apart.
const ObjectSlot = enum { handle, optional_handle, pointer, optional_pointer };

fn objectSlot(comptime T: type) ?ObjectSlot {
    if (gd.isGd(T)) return .handle;
    if (gd.OptionalGd(T) != null) return .optional_handle;
    // Optionals first: `isClassPtr` accepts `?*T` as well as `*T`, so asking it
    // about the bare type would classify an optional as `.pointer` and then
    // hand `upcast` a `?*T` where it wants a `*T`.
    if (@typeInfo(T) == .optional) {
        return if (class.isClassPtr(@typeInfo(T).optional.child)) .optional_pointer else null;
    }
    if (class.isClassPtr(T)) return .pointer;
    return null;
}

/// Reads an argument for a **virtual** ptrcall.
///
/// The mirror of `writeVirtualReturn`: a refcounted argument arrives as a
/// `Ref<T>*`, so the object has to be fetched with `ref_get_object` rather than
/// read as a plain `T**`. The reference belongs to the caller for the duration
/// of the call, so this hands back a borrowed `*T` and takes nothing.
pub fn readVirtualArg(comptime T: type, raw_p_arg: ?*const anyopaque) T {
    if (comptime class.isRefCountedPtr(T)) {
        return @ptrCast(gdzig.raw.refGetObject(@ptrCast(@constCast(raw_p_arg))).?);
    }
    if (comptime @typeInfo(T) == .optional and class.isRefCountedPtr(@typeInfo(T).optional.child)) {
        const obj = gdzig.raw.refGetObject(@ptrCast(@constCast(raw_p_arg)));
        return if (obj) |o| @ptrCast(o) else null;
    }
    return readArg(T, raw_p_arg);
}

/// Writes a return value for a **virtual** ptrcall.
///
/// Identical to `writeReturn` apart from refcounted objects, which Godot treats
/// differently in a virtual than in a standard ptrcall: the return slot is a
/// `Ref<T>*` rather than a `T**`, and it has to be populated through
/// `ref_set_object` so the engine takes its own reference. Writing the bare
/// pointer -- which is what `writeReturn` does, and what this used to do --
/// leaves the engine holding a `Ref` for a count nobody incremented, so the
/// object is freed the first time either side releases it.
///
/// See godot-cpp#954 for the upstream inconsistency; `readVirtualArg` is the
/// mirror of this on the way in.
///
/// Both ownership conventions are accepted, matching the rest of the API:
/// returning `*T` lends the engine an object you keep, and returning `Gd(T)`
/// hands yours over.
pub fn writeVirtualReturn(comptime T: type, raw_p_ret: ?*anyopaque, value: T) void {
    if (comptime @typeInfo(T) == .optional and isRefCounted(@typeInfo(T).optional.child)) {
        if (value) |present| {
            setRef(@typeInfo(T).optional.child, raw_p_ret, present);
        } else {
            gdzig.raw.refSetObject(@ptrCast(raw_p_ret), null);
        }
        return;
    }
    if (comptime isRefCounted(T)) {
        setRef(T, raw_p_ret, value);
        return;
    }
    writeReturn(T, raw_p_ret, value);
}

/// Whether `T` carries a reference-counted object, as either a borrowed `*R` or
/// an owning `Gd(R)`.
fn isRefCounted(comptime T: type) bool {
    if (comptime isOwningHandle(T)) return true;
    return comptime class.isRefCountedPtr(T);
}

/// Exact test for `Gd(R)`: it declares the type it owns, so this cannot be
/// fooled by an unrelated struct that happens to hold a `ptr` field.
fn isOwningHandle(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    if (!@hasDecl(T, "Owns")) return false;
    return T == gdzig.Gd(T.Owns);
}

fn setRef(comptime T: type, raw_p_ret: ?*anyopaque, value: T) void {
    if (comptime isOwningHandle(T)) {
        var owned = value;
        // `ref_set_object` takes the engine's own reference, so ours is now
        // surplus and releasing it completes the hand-over.
        gdzig.raw.refSetObject(@ptrCast(raw_p_ret), @ptrCast(class.upcast(*class.Object, owned.get())));
        owned.deinit();
    } else {
        // `upcast`, not a bare cast: for one of your own refcounted classes the
        // object lives at `base`, and `ref_set_object` dereferences what it is
        // given.
        gdzig.raw.refSetObject(@ptrCast(raw_p_ret), @ptrCast(class.upcast(*class.Object, value)));
    }
}

/// `u64` is the only integer width that gets its own native slot; every
/// other integer (regardless of signedness or width, up to 64 bits) travels
/// as `int64_t`.
fn isU64Like(bits: u16, signedness: std.builtin.Signedness) bool {
    return bits == 64 and signedness == .unsigned;
}

fn readIntSlot(comptime Int: type, p_arg: *const anyopaque) i128 {
    const info = @typeInfo(Int).int;
    if (comptime info.bits > 64) @compileError("ptrcall does not support integers wider than 64 bits");
    if (comptime isU64Like(info.bits, info.signedness)) {
        return @as(*const u64, @ptrCast(@alignCast(p_arg))).*;
    }
    return @as(*const i64, @ptrCast(@alignCast(p_arg))).*;
}

fn writeIntSlot(comptime Int: type, p_ret: *anyopaque, value: anytype) void {
    const info = @typeInfo(Int).int;
    if (comptime info.bits > 64) @compileError("ptrcall does not support integers wider than 64 bits");
    if (comptime isU64Like(info.bits, info.signedness)) {
        @as(*u64, @ptrCast(@alignCast(p_ret))).* = @intCast(value);
    } else {
        @as(*i64, @ptrCast(@alignCast(p_ret))).* = @intCast(value);
    }
}

test "a standard ptrcall object argument is one dereference away" {
    // Not real objects: this is pointer marshalling and nothing dereferences
    // the value, so a live engine is not needed.
    const object: *gdzig.class.Node = @ptrFromInt(0xDEAD_0000);
    const resource: *gdzig.class.Resource = @ptrFromInt(0xBEEF_0000);

    // Encoded the way the generated outgoing calls do it, which is what the
    // engine hands back on the way in: `args[0] = @ptrCast(&p_node)`.
    const node_slot: *gdzig.class.Node = object;
    const res_slot: *gdzig.class.Resource = resource;

    // Refcounted or not, a standard ptrcall passes `T**`. Returning the slot
    // address instead -- which is what the non-refcounted path used to do --
    // hands the callee a pointer to the caller's local variable.
    try std.testing.expectEqual(object, readArg(*gdzig.class.Node, @ptrCast(&node_slot)));
    try std.testing.expectEqual(resource, readArg(*gdzig.class.Resource, @ptrCast(&res_slot)));

    try std.testing.expect(@intFromPtr(&node_slot) != @intFromPtr(object));
}

test "an object return occupies one pointer of the slot, whatever shape it was declared" {
    // A canary either side, so a write that is too wide is visible rather than
    // merely wrong. `writeReturn` never dereferences these, so fabricated
    // addresses are enough and no engine is needed.
    const object: *class.Object = @ptrFromInt(0xDEAD_0000);
    const slot_only: [4]usize = .{ 0, 0xC0FFEE, 0xC0FFEE, 0xC0FFEE };

    {
        // A borrowed engine pointer: the case that already worked.
        var frame = slot_only;
        writeReturn(*class.Object, @ptrCast(&frame[0]), object);
        try std.testing.expectEqual(@intFromPtr(object), frame[0]);
        try std.testing.expectEqual(@as(usize, 0xC0FFEE), frame[1]);
    }

    {
        // An owning handle. `Gd` is two words under safety checks and three
        // when optional; the struct arm used to write all of them, so the
        // pointer landed by luck and `released` overwrote the next word.
        var frame = slot_only;
        const handle: gdzig.Gd(class.RefCounted) = .{ .ptr = @ptrFromInt(0xDEAD_0000) };
        writeReturn(gdzig.Gd(class.RefCounted), @ptrCast(&frame[0]), handle);
        try std.testing.expectEqual(@intFromPtr(object), frame[0]);
        try std.testing.expectEqual(@as(usize, 0xC0FFEE), frame[1]);
    }

    {
        var frame = slot_only;
        const handle: ?gdzig.Gd(class.RefCounted) = .{ .ptr = @ptrFromInt(0xDEAD_0000) };
        writeReturn(?gdzig.Gd(class.RefCounted), @ptrCast(&frame[0]), handle);
        try std.testing.expectEqual(@intFromPtr(object), frame[0]);
        try std.testing.expectEqual(@as(usize, 0xC0FFEE), frame[1]);

        frame = slot_only;
        writeReturn(?gdzig.Gd(class.RefCounted), @ptrCast(&frame[0]), null);
        try std.testing.expectEqual(@as(usize, 0), frame[0]);
        try std.testing.expectEqual(@as(usize, 0xC0FFEE), frame[1]);
    }
}

test "a user class returns its engine object, not its own address" {
    const object: *class.Object = @ptrFromInt(0xDEAD_0000);

    // The shape of one of your own classes: a Zig struct that *holds* the
    // engine object. Its address is not the object's, and the slot wants the
    // object.
    const UserClass = struct { base: *class.Object };
    var instance: UserClass = .{ .base = object };

    var frame: [2]usize = .{ 0, 0xC0FFEE };
    writeReturn(*UserClass, @ptrCast(&frame[0]), &instance);

    try std.testing.expectEqual(@intFromPtr(object), frame[0]);
    try std.testing.expect(frame[0] != @intFromPtr(&instance));
    try std.testing.expectEqual(@as(usize, 0xC0FFEE), frame[1]);
}
