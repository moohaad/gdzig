// @mixin start

/// Immediately destroys the object. Prefer `queueFree` in most situations.
pub fn destroy(self: *Self) void {
    if (DestroyInstanceBinding.get(Object.upcast(self))) |destroy_meta| {
        destroy_meta.assertNotDispatching();
        if (destroy_meta.engine_destroying) return;
        destroy_meta.user_destroying = true;
    }
    raw.objectDestroy(self.ptr());
}

/// Upcasts a child type to this type.
pub fn upcast(value: anytype) *Self {
    return class.upcast(*Self, value);
}

/// Downcasts a parent type to this type.
///
/// This operation will fail at compile time if Self does not inherit from `@TypeOf(value)`. However,
/// since there is no guarantee that `value` is this type at runtime, this function has a runtime cost
/// and may return `null`.
pub fn downcast(value: anytype) ?*Self {
    const T = comptime sw: switch (@typeInfo(@TypeOf(value))) {
        .optional => |info| continue :sw @typeInfo(info.child),
        .pointer => |info| break :sw info.child,
        else => @compileError("downcasted value should be a pointer, found '" ++ @typeName(@TypeOf(value)) ++ "'"),
    };
    comptime class.assertIsA(T, Self);
    const tag = raw.classdbGetClassTag(@ptrCast(StringName.fromComptimeLatin1(self_name)));
    const result = raw.objectCastTo(@ptrCast(value), tag);
    if (result) |p| {
        if (class.isOpaqueClass(T)) {
            return @ptrCast(@alignCast(p));
        } else {
            const object: *anyopaque = raw.objectGetInstanceBinding(p, raw.library, null) orelse return null;
            return @ptrCast(@alignCast(object));
        }
    } else {
        return null;
    }
}

/// Returns an opaque pointer to the object.
pub fn ptr(self: *Self) *anyopaque {
    return @ptrCast(self);
}

/// Returns a constant opaque pointer to the object.
pub fn constPtr(self: *const Self) *const anyopaque {
    return @ptrCast(self);
}

/// Bind an instance of an extension class to this engine class.
pub fn setInstance(self: *Self, comptime T: type, instance_: *T) void {
    comptime std.debug.assert(class.isA(Self, T));
    comptime std.debug.assert(class.isStructClass(T));

    raw.objectSetInstance(@ptrCast(self), @ptrCast(StringName.fromType(T)), @ptrCast(instance_));

    // One binding, under the library's own token. `set_instance_binding` takes
    // exactly one per object, so this cannot be per-type however much
    // `asInstance` would like it to be; the type lives on the record above
    // instead. `raw.library` is what the token means to the engine, and it is
    // what the struct arm of `downcast` already reads -- which until now did
    // not match what this wrote.
    raw.objectSetInstanceBinding(@ptrCast(self), raw.library, @ptrCast(instance_), &struct {
        const callbacks = c.GDExtensionInstanceBindingCallbacks{
            .create_callback = create_callback,
            .free_callback = free_callback,
            .reference_callback = reference_callback,
        };

        fn create_callback(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) ?*anyopaque {
            return null;
        }

        fn free_callback(_: ?*anyopaque, _: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {}

        fn reference_callback(_: ?*anyopaque, _: ?*anyopaque, _: c.GDExtensionBool) callconv(.c) c.GDExtensionBool {
            return 1;
        }
    }.callbacks);

    // After the binding, not before: `DestroyInstanceBinding.get` *creates* its
    // record through `get_instance_binding`, and Godot refuses
    // `set_instance_binding` once the object has any binding at all -- doing
    // this first silently left the instance unbound.
    //
    // What class this instance actually is. Nothing on the engine side records
    // it (see `extension.InstanceType`), and without it `asInstance` cannot
    // tell a narrowing cast that should succeed from one that should not.
    if (gdzig.extension.DestroyInstanceBinding.get(@ptrCast(self))) |record| {
        record.instance_type = gdzig.extension.instanceTypeOf(T);
    }
}

pub fn asInstance(self: *Self, comptime T: type) ?*T {
    comptime std.debug.assert(class.isA(Self, T));
    comptime std.debug.assert(class.isStructClass(T));

    const ptr_ = raw.objectGetInstanceBinding(@ptrCast(self), raw.library, null) orelse return null;

    // Ask what the instance is before believing it is a `T`.
    //
    // This used to be the whole function, keyed by a `typeToken(T)` that was
    // the address of a per-`T` zero-sized `var`. A zero-sized value has no
    // storage, so every one of those addresses was 1: all classes shared a
    // token, the lookup could not miss, and this returned a `*T` addressing an
    // object of an unrelated class.
    //
    // `narrow` also does the narrowing properly. Returning `ptr_` directly is
    // only right when the ancestor sits at offset 0 of the concrete class,
    // which Zig's field ordering does not promise.
    const record = gdzig.extension.DestroyInstanceBinding.get(@ptrCast(self)) orelse return null;
    const actual = record.instance_type orelse return null;
    const narrowed = actual.narrow(ptr_, gdzig.extension.instanceTypeOf(T).id) orelse return null;

    return @ptrCast(@alignCast(narrowed));
}

/// Connects a signal to a method on `receiver`.
///
/// ```zig
/// player.base.connect(Player.Hit, self, &gameOver);
/// ```
///
/// `method` points at one of `receiver`'s *public* declarations, which is how
/// the method name is recovered at comptime, and the method has to be
/// registered with `addMethod` so Godot knows it by that name. Both mistakes
/// fail the build.
///
/// The receiver is passed because it cannot be inferred: a function pointer
/// names a function, not an object, and Godot's callable is an object plus a
/// method name. Deriving it from the receiver would only be right when a class
/// connects its own signal to its own method, which is the rarer case -- the
/// emitter is usually some other node.
///
/// `connectCallable` takes a `Callable` you already hold.
///
/// A refused connection is logged, not returned. The error set had one member,
/// `AlreadyConnected`, and every call site answered it with `catch {}` -- which
/// is worse than not returning it, since a duplicate connection fires the
/// handler twice and the `catch` hides why. `tryConnect` returns it for the
/// caller that wants to branch.
///
/// Named `receiver` rather than `instance` because this mixin is merged into
/// every class, and singletons generate a class-level `pub var instance` that
/// a parameter of that name shadows.
pub fn connect(self: *Self, comptime S: type, receiver: anytype, comptime method: anytype) void {
    self.connectCallable(S, .fromClosure(receiver, method));
}

/// `connect`, for the caller that wants to handle a failed connection rather
/// than have it logged.
pub fn tryConnect(self: *Self, comptime S: type, receiver: anytype, comptime method: anytype) ConnectError!void {
    return self.tryConnectCallable(S, .fromClosure(receiver, method));
}

/// `connect` for a `Callable` you already have: one built elsewhere, or one
/// you keep in order to `disconnectCallable` the same value later.
pub fn connectCallable(self: *Self, comptime S: type, callable: Callable) void {
    report(S, "connect", self.connectRaw(StringName.fromSignal(S).*, callable, .{}));
}

/// `connectCallable`, returning the failure instead of logging it.
pub fn tryConnectCallable(self: *Self, comptime S: type, callable: Callable) ConnectError!void {
    const result = self.connectRaw(StringName.fromSignal(S).*, callable, .{});
    if (result != .ok) return ConnectError.AlreadyConnected;
}

/// Connects a signal to a callable for one emission, after which Godot
/// disconnects it.
///
/// This is the shape most "wait for X, then do Y" code wants, and the one
/// GDScript spells `await`. GDExtension has no `await` -- neither does the
/// engine's own C++, which uses signals throughout -- so a one-shot connection
/// is the primitive underneath it:
///
/// ```zig
/// var timer = tree.createTimer(2.0, .{}).?;
/// defer timer.deinit();
/// timer.get().once(SceneTreeTimer.Timeout, self, &showStartButton);
/// ```
///
/// A sequence of waits still needs explicit state, the way the engine does it.
/// That is the one case `await` genuinely buys something, and it is not worth a
/// coroutine runtime to get.
pub fn once(self: *Self, comptime S: type, receiver: anytype, comptime method: anytype) void {
    self.onceCallable(S, .fromClosure(receiver, method));
}

/// `once`, returning the failure instead of logging it.
pub fn tryOnce(self: *Self, comptime S: type, receiver: anytype, comptime method: anytype) ConnectError!void {
    return self.tryOnceCallable(S, .fromClosure(receiver, method));
}

/// `once` for a `Callable` you already have.
pub fn onceCallable(self: *Self, comptime S: type, callable: Callable) void {
    report(S, "once", self.connectOneShot(S, callable));
}

/// `onceCallable`, returning the failure instead of logging it.
pub fn tryOnceCallable(self: *Self, comptime S: type, callable: Callable) ConnectError!void {
    if (self.connectOneShot(S, callable) != .ok) return ConnectError.AlreadyConnected;
}

fn connectOneShot(self: *Self, comptime S: type, callable: Callable) gdzig.global.Error {
    const flags: Object.ConnectFlags = .{ .connect_one_shot = true };
    return self.connectRaw(StringName.fromSignal(S).*, callable, .{ .flags = @bitCast(flags) });
}

/// What the plain `connect`/`once` do with a refused connection.
///
/// Logged rather than returned, because the error set had exactly one member
/// and every call site in this repo and the demo answered it with `catch {}`
/// -- 54 of them. That is worse than not returning it at all: a duplicate
/// connection is a real bug, and it fires the handler twice while the `catch`
/// hides why. Naming the signal and the engine's own result makes it findable.
///
/// `tryConnect` and friends are there for the caller that genuinely wants to
/// branch on it.
fn report(comptime S: type, comptime what: []const u8, result: gdzig.global.Error) void {
    if (result == .ok) return;
    std.log.err(
        "{s}: {s} refused ({s}) -- already connected, or this object has no such signal",
        .{ @typeName(S), what, @tagName(result) },
    );
}

/// Disconnects a signal from a method on `receiver`.
///
/// Matches by object and method name rather than by the identity of the
/// `Callable` that made the connection, so this undoes a `connect` written the
/// same way without having kept anything.
pub fn disconnect(self: *Self, comptime S: type, receiver: anytype, comptime method: anytype) void {
    self.disconnectCallable(S, .fromClosure(receiver, method));
}

/// `disconnect` for a `Callable` you already have.
pub fn disconnectCallable(self: *Self, comptime S: type, callable: Callable) void {
    const signal_name = StringName.fromSignal(S);
    self.disconnectRaw(signal_name.*, callable);
}

/// Emits a signal. Guarantees no allocations when calling across the FFI. Passing Transform2D, AABB, Basis, Transform3D, or Projection is a compile error; use the Alloc variant.
///
/// The signal type parameter is named `S`, not `Signal`, to match `connect` and
/// to avoid shadowing the `Signal` builtin, which classes import whenever their
/// Calls a method dynamically and discards the return value. Handles string conversion and variant cleanup automatically.
pub fn callVoid(self: *Self, method_name: []const u8, args: anytype) void {
    var string_name = StringName.fromSlice(method_name);
    defer string_name.deinit();

    const fields = @typeInfo(@TypeOf(args)).@"struct".fields;
    var variant_args: [fields.len]Variant = undefined;
    var variant_ptrs: [fields.len]*const Variant = undefined;

    inline for (fields, 0..) |field, i| {
        variant_args[i] = Variant.init(field.type, @field(args, field.name));
        variant_ptrs[i] = &variant_args[i];
    }

    defer {
        inline for (fields, 0..) |field, i| {
            if (allocatesAsVariant(field.type)) variant_args[i].deinit();
        }
    }

    var self_variant = Variant.init(*Self, self);
    defer if (allocatesAsVariant(*Self)) self_variant.deinit();

    var result = self_variant.call(string_name, &variant_ptrs) catch |err| {
        std.log.err("callVoid failed on {s}.{s}: {}", .{ self_name, method_name, err });
        return;
    };
    defer if (result.tag.allocates()) result.deinit();
}

/// API mentions it (`Tween.tweenAwait` in Godot 4.7+).
pub fn emit(self: *Self, comptime S: type, signal: AssertNonAllocating(S)) EmitError!void {
    const signal_name = StringName.fromSignal(S);
    const fields = @typeInfo(S).@"struct".fields;
    var args: [fields.len]Variant = undefined;
    inline for (fields, 0..) |field, i| {
        args[i] = Variant.init(field.type, @field(signal, field.name));
    }
    // No defer needed - non-allocating types don't need cleanup
    return emitImpl(self, signal_name.*, args);
}

/// Emits a signal. Will necessarily allocate when calling across the FFI with Transform2d, Aabb, Basis, Transform3d, or Projection.
pub fn emitAlloc(self: *Self, comptime S: type, signal: S) EmitError!void {
    const signal_name = StringName.fromSignal(S);
    const fields = @typeInfo(S).@"struct".fields;
    var args: [fields.len]Variant = undefined;
    inline for (fields, 0..) |field, i| {
        args[i] = Variant.init(field.type, @field(signal, field.name));
    }
    defer inline for (&args, fields) |*arg, field| {
        if (allocatesAsVariant(field.type)) arg.deinit();
    };
    return emitImpl(self, signal_name.*, args);
}

fn emitImpl(self: *Self, signal_name: StringName, args: anytype) EmitError!void {
    switch (self.emitRaw(signal_name, args)) {
        .ok => {},
        .err_unavailable => {
            // Godot does not distinguish between "not a signal I handle" and "no one is listening to this signal"
            if (self.hasSignal(signal_name)) return;
            return EmitError.InvalidSignal;
        },
        .err_cant_acquire_resource => return EmitError.SignalsBlocked,
        .err_method_not_found => return EmitError.MethodNotFound,
        else => unreachable,
    }
}

/// Returns `S` if no fields allocate, otherwise generates a compile error.
fn AssertNonAllocating(comptime S: type) type {
    const fields = @typeInfo(S).@"struct".fields;
    inline for (fields) |field| {
        if (allocatesAsVariant(field.type)) {
            @compileError("Signal field '" ++ field.name ++ "' has type " ++ @typeName(field.type) ++
                " which allocates when wrapped in Variant. Use emitAlloc instead.");
        }
    }
    return S;
}

const allocatesAsVariant = Variant.Tag.allocatesForType;

const ConnectError = gdzig.ConnectError;
const EmitError = gdzig.EmitError;
const class = gdzig.class;

const DestroyInstanceBinding = gdzig.extension.DestroyInstanceBinding;

// @mixin stop

const Self = gdzig.class.Object;
const self_name = "Object";

const std = @import("std");

const c = @import("gdextension");

const gdzig = @import("gdzig");
const raw = &gdzig.raw;
const Callable = gdzig.builtin.Callable;
const Object = gdzig.class.Object;
const StringName = gdzig.builtin.StringName;
const Variant = gdzig.builtin.Variant;
