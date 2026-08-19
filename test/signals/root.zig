pub fn register(r: *gdzig.extension.Registry) void {
    const emitter_class = r.createClass(SignalEmitter, {}, .auto);
    emitter_class.addSignal(TestSignal);

    const receiver_class = r.createClass(SignalReceiver, {}, .auto);
    receiver_class.addMethod("on_signal", .auto);
}

fn ensureRegistered() void {
    const S = struct {
        var done: bool = false;
    };
    if (!S.done) {
        S.done = true;
        gdzig.testing.loadModule(@This());
    }
}

test "signal connect and emit" {
    ensureRegistered();

    const emitter = try SignalEmitter.create();
    defer emitter.destroy();

    const receiver = try SignalReceiver.create();
    defer receiver.destroy();

    const callable: Callable = .fromClosure(receiver, &SignalReceiver.onSignal);

    emitter.base.connectCallable(TestSignal, callable);

    try testing.expectEqual(@as(i64, 0), receiver.count);
    try testing.expectEqual(@as(i64, 0), receiver.value);

    try emitter.base.emit(TestSignal, .{ .value = 42 });

    try testing.expectEqual(@as(i64, 1), receiver.count);
    try testing.expectEqual(@as(i64, 42), receiver.value);

    emitter.base.disconnectCallable(TestSignal, callable);

    try emitter.base.emit(TestSignal, .{ .value = 99 });

    try testing.expectEqual(@as(i64, 1), receiver.count);
    try testing.expectEqual(@as(i64, 42), receiver.value);
}

test "disconnect matches by receiver and method, not by Callable identity" {
    ensureRegistered();

    const emitter = try SignalEmitter.create();
    defer emitter.destroy();

    const receiver = try SignalReceiver.create();
    defer receiver.destroy();

    // Connect and disconnect without keeping anything in between. Each call
    // builds its own `Callable`, so this only works if Godot compares object
    // and method name rather than the value that made the connection -- which
    // is what lets `connect`/`disconnect` take a receiver and a method pointer
    // instead of a `Callable` the caller has to store.
    emitter.base.connect(TestSignal, receiver, &SignalReceiver.onSignal);
    try emitter.base.emit(TestSignal, .{ .value = 7 });
    try testing.expectEqual(@as(i64, 1), receiver.count);

    emitter.base.disconnect(TestSignal, receiver, &SignalReceiver.onSignal);
    try emitter.base.emit(TestSignal, .{ .value = 8 });

    // Still 1, and still holding the first value: the second emission was not
    // delivered. Without the disconnect this reads 2 and 8.
    try testing.expectEqual(@as(i64, 1), receiver.count);
    try testing.expectEqual(@as(i64, 7), receiver.value);
}

const TestSignal = struct {
    value: i64,
};

const SignalEmitter = struct {
    base: *Object,

    pub fn create() !*SignalEmitter {
        const self = try allocator.create(SignalEmitter);
        self.* = .{ .base = Object.init() };
        self.base.setInstance(SignalEmitter, self);
        return self;
    }

    pub fn destroy(self: *SignalEmitter) void {
        self.base.destroy();
        allocator.destroy(self);
    }
};

const SignalReceiver = struct {
    base: *Object,
    count: i64 = 0,
    value: i64 = 0,

    pub fn create() !*SignalReceiver {
        const self = try allocator.create(SignalReceiver);
        self.* = .{ .base = Object.init() };
        self.base.setInstance(SignalReceiver, self);
        return self;
    }

    pub fn destroy(self: *SignalReceiver) void {
        self.base.destroy();
        allocator.destroy(self);
    }

    pub fn onSignal(self: *SignalReceiver, value: i64) void {
        self.value = value;
        self.count += 1;
    }
};

const std = @import("std");
const testing = std.testing;

const gdzig = @import("gdzig");
const allocator = gdzig.testing.allocator;
const Callable = gdzig.builtin.Callable;

test "Callable.bind returns a Callable, not a mangled Variant" {
    // A builtin method always ptrcalls, even with varargs, and a ptrcall writes
    // the native return type. Generating the result slot as a `Variant` let
    // Godot write a `Callable` over it; `as(Callable)` then found an
    // incompatible tag and the `.?` behind it panicked. `bind` is reached by
    // anything that carries a value into a signal handler.
    const node = Node.init();
    defer node.destroy();

    const name = StringName.fromComptimeLatin1("free");
    var callable = Callable.initObjectMethod(Object.upcast(node), name.*);
    defer callable.deinit();
    try testing.expect(callable.isValid());

    var bound = callable.bind(.{@as(i64, 7)});
    defer bound.deinit();

    // A mangled result reads as invalid with no object behind it.
    try testing.expect(bound.isValid());
    try testing.expectEqual(@as(i64, 1), bound.getBoundArgumentsCount());
}

const Object = gdzig.class.Object;
const Node = gdzig.class.Node;
const StringName = gdzig.builtin.StringName;

test "a duplicate connection is refused, and tryConnect is how you hear about it" {
    ensureRegistered();

    const emitter = try SignalEmitter.create();
    defer emitter.destroy();

    const receiver = try SignalReceiver.create();
    defer receiver.destroy();

    const callable: Callable = .fromClosure(receiver, &SignalReceiver.onSignal);

    // The plain form logs a refusal rather than returning it, so the assertion
    // has to go through `try`. Connecting the same callable twice is the one
    // failure the engine reports here.
    try emitter.base.tryConnectCallable(TestSignal, callable);
    try testing.expectError(
        error.AlreadyConnected,
        emitter.base.tryConnectCallable(TestSignal, callable),
    );
}
