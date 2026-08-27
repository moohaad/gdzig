/// The node at `path`, narrowed to `T`, or null.
///
/// `getNode` hands back `?*Node`, because that is all the engine method
/// promises, so reaching a node at the type you actually want means a cast at
/// every call:
///
/// ```zig
/// const found = self.base.getNodeOrNull(path) orelse return;
/// const spawn = gdzig.class.castTo(Marker3d, found) orelse return;
/// ```
///
/// versus:
///
/// ```zig
/// const spawn = self.base.getNodeAs(Marker3d, path) orelse return;
/// ```
///
/// `T` may be an engine class or one of yours -- the difference is handled for
/// you. Null covers both "nothing at that path" and "not a `T`", and neither
/// prints an engine error: this goes through `get_node_or_null`, so an absent
/// node is a case rather than a complaint.
///
/// ## Prefer the field when the path is known
///
/// This exists for paths you do not have at comptime -- built from a name, read
/// from a property, chosen at runtime. When you *do* know the path, declare it:
///
/// ```zig
/// spawn: Child(Marker3d, "Spawn") = .pending,
/// ```
///
/// `Child` resolves once before `_ready` and tells you in the log if the scene
/// and the declaration disagree, where this walks the tree on every call and
/// returns a null you have to handle each time.
pub inline fn getNodeAs(self: *const Self, comptime T: type, path: anytype) ?*T {
    const node = self.getNodeOrNull(path) orelse return null;
    return gdzig.class.castTo(T, node);
}

// @mixin stop

const Self = gdzig.class.Node;

const gdzig = @import("gdzig");
