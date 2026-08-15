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

    const token = comptime typeToken(T);

    raw.objectSetInstance(@ptrCast(self), @ptrCast(StringName.fromType(T)), @ptrCast(instance_));
    raw.objectSetInstanceBinding(@ptrCast(self), token, @ptrCast(instance_), &struct {
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
}

pub fn asInstance(self: *Self, comptime T: type) ?*T {
    comptime std.debug.assert(class.isA(Self, T));
    comptime std.debug.assert(class.isStructClass(T));

    const token = comptime typeToken(T);

    const ptr_ = raw.objectGetInstanceBinding(@ptrCast(self), token, null) orelse return null;

    return @ptrCast(@alignCast(ptr_));
}

fn typeToken(comptime T: type) *anyopaque {
    return @ptrCast(&struct {
        var token: void = {};
        comptime {
            _ = T;
        }
    }.token);
}

/// Connects a signal to a method on `receiver`.
///
/// ```zig
/// try player.base.connect(Player.Hit, self, &gameOver);
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
/// Named `receiver` rather than `instance` because this mixin is merged into
/// every class, and singletons generate a class-level `pub var instance` that
/// a parameter of that name shadows.
pub fn connect(self: *Self, comptime S: type, receiver: anytype, comptime method: anytype) ConnectError!void {
    return self.connectCallable(S, .fromClosure(receiver, method));
}

/// `connect` for a `Callable` you already have: one built elsewhere, or one
/// you keep in order to `disconnectCallable` the same value later.
pub fn connectCallable(self: *Self, comptime S: type, callable: Callable) ConnectError!void {
    const signal_name = StringName.fromSignal(S);
    const result = self.connectRaw(signal_name.*, callable, .{});
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
/// try timer.get().once(SceneTreeTimer.Timeout, self, &showStartButton);
/// ```
///
/// A sequence of waits still needs explicit state, the way the engine does it.
/// That is the one case `await` genuinely buys something, and it is not worth a
/// coroutine runtime to get.
pub fn once(self: *Self, comptime S: type, receiver: anytype, comptime method: anytype) ConnectError!void {
    return self.onceCallable(S, .fromClosure(receiver, method));
}

/// `once` for a `Callable` you already have.
pub fn onceCallable(self: *Self, comptime S: type, callable: Callable) ConnectError!void {
    const signal_name = StringName.fromSignal(S);
    const flags: Object.ConnectFlags = .{ .connect_one_shot = true };
    const result = self.connectRaw(signal_name.*, callable, .{ .flags = @bitCast(flags) });
    if (result != .ok) return ConnectError.AlreadyConnected;
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
