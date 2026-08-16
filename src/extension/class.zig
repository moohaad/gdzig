pub fn registerClass(comptime T: type, info: ClassInfo4(ClassUserdataOf(T))) void {
    const class_name = StringName.fromType(T);
    const base_name = StringName.fromType(class.BaseOf(T));
    const callbacks = comptime makeClassCallbacks(T);
    const Userdata = ClassUserdataOf(T);

    // gdzig targets Godot 4.7, so only the newest registration entry point is
    // reachable. `registerClass1` through `registerClass3` remain available in
    // `ClassDb.mixin.zig` as bindings to the corresponding engine functions.
    classdb.registerClass4(T, Userdata, void, class_name, base_name, if (Userdata != void) .{
        .userdata = info.userdata,
        .is_virtual = info.is_virtual,
        .is_abstract = info.is_abstract,
        .is_exposed = info.is_exposed,
        .is_runtime = info.is_runtime,
    } else .{
        .is_virtual = info.is_virtual,
        .is_abstract = info.is_abstract,
        .is_exposed = info.is_exposed,
        .is_runtime = info.is_runtime,
    }, callbacks);
}

/// Extracts the `ClassUserdata` type from a type `T` by inspecting its `create` function.
pub fn ClassUserdataOf(comptime T: type) type {
    if (!@hasDecl(T, "create")) {
        @compileError("Type '" ++ @typeName(T) ++ "' must have a 'create' function");
    }
    const params = @typeInfo(@TypeOf(T.create)).@"fn".params;
    return switch (params.len) {
        0 => void,
        1 => params[0].type.?,
        inline else => @compileError("Type '" ++ @typeName(T) ++ "'.create must take zero or one parameters"),
    };
}

/// Whether dispatches are counted so that freeing an object out from under one
/// can be caught. Enabled where the other safety checks are.
pub const track_dispatch = switch (builtin.mode) {
    .Debug, .ReleaseSafe => true,
    .ReleaseFast, .ReleaseSmall => false,
};

/// Tracks destruction state to prevent double-free.
pub const DestroyInstanceBinding = struct {
    user_destroying: bool = false,
    engine_destroying: bool = false,
    /// How many gdzig dispatches -- bound methods and virtual overrides -- are
    /// currently executing on this instance. Freeing the object while this is
    /// non-zero means the dispatch is about to return into freed memory.
    ///
    /// Atomic because Godot dispatches from whichever thread makes the call; a
    /// torn counter would turn a debugging aid into a source of false panics.
    dispatch_depth: std.atomic.Value(u16) = .init(0),

    var gpa: GeneralPurposeAllocator = .init;
    const allocator = gpa.allocator();
    var pool: MemoryPool(DestroyInstanceBinding) = .empty;

    /// Guards `pool` and `gpa`, neither of which locks. Godot creates and frees
    /// instance bindings from whichever thread touches or drops the object, so
    /// two concurrent frees would corrupt the pool's free list.
    ///
    /// A spin lock rather than a blocking one because Zig 0.16 has no io-free
    /// blocking mutex: `std.Io.Mutex` wants an `Io`, which a shared library with
    /// no `main` does not have, and `std.atomic.Mutex` is try-only. The critical
    /// section is a pool alloc or free, so spinning is the right trade anyway.
    var pool_lock: std.atomic.Mutex = .unlocked;

    fn lockPool() void {
        while (!pool_lock.tryLock()) std.atomic.spinLoopHint();
    }

    pub const callbacks: c.GDExtensionInstanceBindingCallbacks = .{
        .create_callback = &create,
        .free_callback = &free,
    };

    fn create(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) ?*anyopaque {
        lockPool();
        defer pool_lock.unlock();

        const self = pool.create(allocator) catch return null;
        // `MemoryPool.create` hands back raw storage; the field defaults above
        // are declarations, not an initializer, so without this every binding
        // starts as whatever the pool last held. Both destruction flags were
        // reading that garbage.
        self.* = .{};
        return @ptrCast(self);
    }

    fn free(_: ?*anyopaque, _: ?*anyopaque, binding: ?*anyopaque) callconv(.c) void {
        lockPool();
        defer pool_lock.unlock();

        if (binding) |self| pool.destroy(@ptrCast(@alignCast(self)));
    }

    pub fn get(obj: *Object) ?*DestroyInstanceBinding {
        const raw_ptr = gdzig.raw.objectGetInstanceBinding(obj, @ptrCast(@constCast(&callbacks)), &callbacks);
        return @ptrCast(@alignCast(raw_ptr));
    }

    /// Panics if a dispatch into this object is still on the stack. Called from
    /// both destruction paths, so it fires whether the free came from your
    /// `destroy` or from the engine.
    ///
    /// There is no legitimate case here. `queueFree` defers, so it never trips
    /// this; what does is destroying an object from inside one of its own
    /// methods, or from a signal handler while the emitter's method is still
    /// running. Either way the dispatch returns into freed memory.
    pub fn assertNotDispatching(self: *const DestroyInstanceBinding) void {
        if (!track_dispatch) return;
        if (self.dispatch_depth.load(.monotonic) == 0) return;
        @panic("object freed while one of its methods was still running; use queueFree to defer the free until the call has returned");
    }

    pub fn cleanup() void {
        lockPool();
        defer pool_lock.unlock();

        pool.deinit(allocator);
        assert(gpa.deinit() == .ok);
    }
};

/// Marks an instance as being dispatched into for the lifetime of the guard.
///
/// The binding is looked up once on entry and reused on exit, so a dispatch
/// costs one `object_get_instance_binding` rather than two. That is safe
/// because the only way the binding could go away mid-dispatch is the object
/// being freed, which `assertNotDispatching` turns into a panic first.
pub const DispatchGuard = struct {
    binding: ?*DestroyInstanceBinding,

    /// Takes the instance in whatever form the dispatch site has it -- a user
    /// class pointer -- and finds the engine object behind it.
    pub fn enter(instance: anytype) DispatchGuard {
        if (!track_dispatch) return .{ .binding = null };
        // `vtable.zig` exercises the dispatch machinery in its own unit tests
        // with plain structs that are not classes and have no engine object
        // behind them. Nothing to track there.
        if (comptime !class.isClassPtr(@TypeOf(instance))) return .{ .binding = null };
        const binding = DestroyInstanceBinding.get(Object.upcast(instance));
        if (binding) |b| _ = b.dispatch_depth.fetchAdd(1, .monotonic);
        return .{ .binding = binding };
    }

    pub fn leave(self: DispatchGuard) void {
        if (!track_dispatch) return;
        if (self.binding) |b| _ = b.dispatch_depth.fetchSub(1, .monotonic);
    }
};

fn makeClassCallbacks(comptime T: type) classdb.ClassCallbacks4(T, ClassUserdataOf(T), void) {
    comptime {
        if (!@hasDecl(T, "create")) {
            @compileError("Type '" ++ @typeName(T) ++ "' must have a 'create' function");
        }
        if (!@hasDecl(T, "destroy")) {
            @compileError("Type '" ++ @typeName(T) ++ "' must have a 'destroy' function");
        }
    }

    const Userdata = ClassUserdataOf(T);

    const Callbacks = struct {
        /// Wraps `create` to bind the instance and send the POSTINITIALIZE notification.
        ///
        /// @since 4.4
        fn create2(userdata: Userdata, notify: bool) anyerror!*T {
            return create2Impl(userdata, notify);
        }

        /// Wraps `create` to bind the instance and send the POSTINITIALIZE notification (no userdata version).
        ///
        /// @since 4.4
        fn create2NoUserdata(notify: bool) anyerror!*T {
            return create2Impl({}, notify);
        }

        fn create2Impl(userdata: Userdata, notify: bool) anyerror!*T {
            const self = if (Userdata == void)
                try T.create()
            else
                try T.create(userdata);

            const obj = Object.upcast(self);

            if (notify) {
                obj.notification(Object.NOTIFICATION_POSTINITIALIZE, .{
                    .reversed = false,
                });
            }

            return self;
        }

        /// Wraps `destroy` to set `base` to `undefined`.
        ///
        /// Godot's ownership rules of the base object are broken; they expect you
        /// to create the Base type `create()`, but not to destroy it in `destroy()`.
        ///
        /// Setting it to `undefined` will make it extremely obvious to the user that
        /// they made a mistake in Debug/ReleaseSafe builds.
        ///
        /// @since 4.1
        fn destroy(self: *T, userdata: Userdata) void {
            destroyImpl(self, userdata);
        }

        /// Wraps `destroy` (no userdata version).
        ///
        /// @since 4.1
        fn destroyNoUserdata(self: *T) void {
            destroyImpl(self, {});
        }

        fn destroyImpl(self: *T, userdata: Userdata) void {
            const obj = Object.upcast(self);
            if (DestroyInstanceBinding.get(obj)) |destroy_meta| {
                destroy_meta.assertNotDispatching();
                if (destroy_meta.user_destroying) return;
                destroy_meta.engine_destroying = true;
            }
            if (Userdata == void) {
                T.destroy(self);
            } else {
                T.destroy(self, userdata);
            }
        }

        fn getVirtualImpl(name: *const StringName) ?*const classdb.CallVirtual(T) {
            const UserVTable = comptime UserClassVTable(T);
            var buf: [256]u8 = undefined;
            const name_str = String.fromStringName(name.*).toLatin1Buf(buf[0..]);
            const result = UserVTable.get(name_str);
            return @ptrCast(result);
        }

        fn getVirtual2(userdata: Userdata, name: *const StringName, hash: u32) ?*const classdb.CallVirtual(T) {
            _ = hash;
            _ = userdata;
            return getVirtualImpl(name);
        }

        fn getVirtual2NoUserdata(name: *const StringName, hash: u32) ?*const classdb.CallVirtual(T) {
            _ = hash;
            return getVirtualImpl(name);
        }
    };

    return .{
        .create = if (Userdata != void) Callbacks.create2 else Callbacks.create2NoUserdata,
        .destroy = if (Userdata != void) Callbacks.destroy else Callbacks.destroyNoUserdata,
        .recreate = if (@hasDecl(T, "recreate")) T.recreate else null,

        .get_virtual = if (Userdata != void) Callbacks.getVirtual2 else Callbacks.getVirtual2NoUserdata,
        // .get_virtual_call_data - not yet supported
        // .call_virtual_with_data - not yet supported

        .set = if (@hasDecl(T, "_set")) T._set else null,
        .get = if (@hasDecl(T, "_get")) T._get else null,
        .get_property_list = if (@hasDecl(T, "_getPropertyList")) T._getPropertyList else null,
        .destroy_property_list = if (@hasDecl(T, "_destroyPropertyList")) T._destroyPropertyList else null,
        .property_can_revert = if (@hasDecl(T, "_propertyCanRevert")) T._propertyCanRevert else null,
        .property_get_revert = if (@hasDecl(T, "_propertyGetRevert")) T._propertyGetRevert else null,
        .validate_property = if (@hasDecl(T, "_validateProperty")) T._validateProperty else null,
        .notification = if (@hasDecl(T, "_notification")) T._notification else null,
        .to_string = if (@hasDecl(T, "_toString")) T._toString else null,
        .reference = if (@hasDecl(T, "_reference")) T._reference else null,
        .unreference = if (@hasDecl(T, "_unreference")) T._unreference else null,
    };
}

fn virtualMethodNames(comptime T: type) []const []const u8 {
    const callbacks = [_][]const u8{
        "_destroyPropertyList",
        "_get",
        "_getPropertyList",
        "_getRid",
        "_notification",
        "_propertyCanRevert",
        "_propertyGetRevert",
        "_reference",
        "_set",
        "_toString",
        "_unreference",
        "_validateProperty",
    };

    const decls = @typeInfo(T).@"struct".decls;

    // The quota is a budget for a whole comptime evaluation, not for one loop,
    // and registering a real class spends it from three directions at once:
    // width (a few dozen properties, methods and signals), depth (a base seven
    // levels down chains that many vtable extensions), and the scan below,
    // where every `_`-prefixed decl is compared against every callback name.
    // Together they pass the default 1000, and it surfaces here because this is
    // simply where the counter runs out.
    @setEvalBranchQuota(@max(1000, decls.len * callbacks.len * 4));

    var names: [decls.len][]const u8 = undefined;
    var count: usize = 0;

    for (decls) |decl| {
        // Must start with _
        if (decl.name.len == 0 or decl.name[0] != '_') continue;

        // Must be a function
        const field = @field(T, decl.name);
        const field_type_info = @typeInfo(@TypeOf(field));
        if (field_type_info != .@"fn") continue;

        // Must have at least one parameter (self) to be a virtual method
        if (field_type_info.@"fn".params.len == 0) continue;

        // Must not be a callback
        const is_callback = for (callbacks) |cb| {
            if (std.mem.eql(u8, decl.name, cb)) break true;
        } else false;
        if (is_callback) continue;

        names[count] = decl.name;
        count += 1;
    }

    return names[0..count];
}

/// Build a VTable for a user-defined class by chaining `.extend()` calls
/// from the nearest Godot (opaque) ancestor through each intermediate user
/// struct class. For example, given ClassC -> ClassB -> ClassA -> Object:
///
///   Object.VTable.extend(ClassA, ...).extend(ClassB, ...).extend(ClassC, ...)
///
/// This ensures that each level's virtual methods are accumulated and any
/// class can override methods defined by any ancestor.
fn UserClassVTable(comptime T: type) type {
    comptime {
        const ancestors = class.selfAndAncestorsOf(T);

        // Find the nearest opaque (Godot) ancestor — it has the root VTable.
        var godot_idx: usize = 0;
        for (ancestors, 0..) |Ancestor, i| {
            if (class.isOpaqueClass(Ancestor)) {
                godot_idx = i;
                break;
            }
        } else {
            @compileError("Type '" ++ @typeName(T) ++ "' has no Godot (opaque) class in its ancestry");
        }

        // Chain .extend() calls from the Godot class back down to T.
        // ancestors is [T, ..., GodotClass, ...] so we iterate from
        // godot_idx-1 down to 0 (inclusive).
        var Result = ancestors[godot_idx].VTable;
        var i: usize = godot_idx;
        while (i > 0) {
            i -= 1;
            Result = Result.extend(ancestors[i], virtualMethodNames(ancestors[i]));
        }
        return Result;
    }
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const MemoryPool = std.heap.MemoryPool;
const assert = std.debug.assert;

const builtin = @import("builtin");

const c = @import("gdextension");
const common = @import("common");
const gdzig = @import("gdzig");
const class = gdzig.class;
const classdb = gdzig.class.ClassDb;
const ClassInfo4 = gdzig.class.ClassDb.ClassInfo4;
const String = gdzig.builtin.String;
const StringName = gdzig.builtin.StringName;
const Object = gdzig.class.Object;
const GeneralPurposeAllocator = gdzig.heap.GeneralPurposeAllocator;
