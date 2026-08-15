//! `fromClosure` must not destroy the `StringName` the cache handed it.
//!
//! `StringName.fromComptimeLatin1` interns a literal once and returns bitwise
//! copies of it forever. The cache holds exactly one engine reference and the
//! copies do not increment it -- which is why `fromLatin1` documents that a
//! destructor must never be called on a static `StringName`. Destroying a copy
//! releases the cache's own reference, and Godot says so:
//!
//!     ERROR: BUG: Unreferenced static string to 0: <name>
//!        at: unref (core/string/string_name.cpp:117)
//!
//! GDExtension can emit engine errors but not observe them, so that message
//! cannot be asserted on from here. What can be observed is the consequence:
//! the entry is freed, the next intern reuses the slot, and the cache is left
//! handing back a name that is now a *different string*.
//!
//! One `fromClosure` plus `Callable.deinit` pair nets -1 on the name while the
//! bug is present and 0 once it is not, so enough pairs drive a buggy build to
//! zero. How many depends on how many copies the engine keeps of a registered
//! method name, which is not ours to know: measured against 4.7.1, four cycles
//! were survivable and eight were not. The loop is therefore generous rather
//! than exact, because erring high keeps the test discriminating if a future
//! engine holds more copies, while erring low would let it pass in silence.
//!
//! Past the free the loop keeps calling `fromClosure`, which reads the dangling
//! cache -- so on a regression this crashes inside Godot rather than reaching
//! the assertion below. A crash here is the failure, not an unrelated fault.
//!
//! `fromComptimeLatin1` now returns `*const StringName`, so the form that
//! caused this -- calling `deinit` on the borrowed name -- no longer compiles.
//! What is left for this test to catch is the deliberate version, copying the
//! handle out with `.*` and destroying that. Kept because the type stops the
//! accident, not the intent.

const std = @import("std");
const testing = std.testing;

pub fn register(r: *gdzig.extension.Registry) void {
    const class = r.createClass(Beeper, {}, .auto);
    class.addMethod("on_beeped", .auto);
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

const Beeper = struct {
    base: *Node,

    pub fn create() !*Beeper {
        const self = try allocator.create(Beeper);
        self.* = .{ .base = Node.init() };
        self.base.setInstance(Beeper, self);
        return self;
    }
    pub fn destroy(self: *Beeper) void {
        allocator.destroy(self);
    }
    pub fn onBeeped(_: *Beeper) void {}
};

test "fromClosure leaves the cached method name intact" {
    ensureRegistered();

    const beeper = try Beeper.create();
    defer beeper.base.destroy();

    for (0..64) |_| {
        var cb: Callable = .fromClosure(beeper, &Beeper.onBeeped);
        cb.deinit();
    }

    // Interned after the cycles above. If "on_beeped" was freed by them, this
    // takes the vacated slot.
    var decoy: StringName = .fromLatin1("gdzig_static_strings_decoy", false);
    defer decoy.deinit();

    const cached = StringName.fromComptimeLatin1("on_beeped");
    try testing.expect(!cached.eql(decoy));
}

const gdzig = @import("gdzig");
const allocator = gdzig.testing.allocator;
const Callable = gdzig.builtin.Callable;
const Node = gdzig.class.Node;
const StringName = gdzig.builtin.StringName;
