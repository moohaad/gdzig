/// Instantiates the scene and narrows its root to `T`.
///
/// `instantiate` returns the root as `?*Node`, because that is all the engine
/// method promises. Every caller then has to narrow it and clean up if the cast
/// fails, which reads badly enough to be worth having once:
///
/// ```zig
/// const instance = scene.instantiate(.{}) orelse return;
/// const mob = (Node.downcast(instance) orelse {
///     instance.destroy();
///     return;
/// }).asInstance(Mob) orelse {
///     instance.destroy();
///     return;
/// };
/// ```
///
/// versus:
///
/// ```zig
/// const mob = scene.instantiateAs(Mob) orelse return;
/// ```
///
/// `T` may be an engine class or one defined in your extension; the difference
/// is handled for you. Null means the scene did not instantiate or its root is
/// not a `T`, and in the second case the freshly built node is freed rather
/// than leaked -- nothing else has a reference to it yet.
///
/// The root is not owned by anything until you parent it, so the caller is
/// responsible for it exactly as with `instantiate`.
pub inline fn instantiateAs(self: *const Self, comptime T: type) ?*T {
    const root = self.instantiate(.{}) orelse return null;
    if (gdzig.class.castTo(T, root)) |typed| return typed;

    root.destroy();
    return null;
}

// @mixin stop

const Self = gdzig.class.PackedScene;

const gdzig = @import("gdzig");
