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

/// Returns the parent narrowed to an engine or user-defined class, or null
/// when unparented or of another type. The returned pointer is borrowed.
pub inline fn getParentAs(self: *const Self, comptime T: type) ?*T {
    const parent = self.getParent() orelse return null;
    return gdzig.class.castTo(T, parent);
}

/// Returns a borrowed child pointer narrowed to `T`, or null for an invalid
/// index or type mismatch. Negative indices count backward from the end.
/// Internal children are excluded unless requested, just like `getChild`.
pub inline fn getChildAs(self: *const Self, comptime T: type, index: i32, options: struct { include_internal: bool = false }) ?*T {
    const count = self.getChildCount(.{ .include_internal = options.include_internal });
    const resolved: i64 = if (index < 0) @as(i64, count) + index else index;
    if (resolved < 0 or resolved >= count) return null;
    const child = self.getChild(@intCast(resolved), .{ .include_internal = options.include_internal }) orelse return null;
    return gdzig.class.castTo(T, child);
}

/// The children that are a `T`, skipping the rest.
///
/// ```zig
/// var mobs = self.base.childrenAs(Mob);
/// while (mobs.next()) |mob| mob.hurt(1);
/// ```
///
/// The alternative is `getChildren`, which is an `Array` of `Variant`: unpack
/// each one, cast it, skip what does not match, free the array. This yields the
/// typed children directly and allocates nothing.
///
/// `T` may be an engine class or one of yours. Children of another type are
/// skipped rather than reported -- a mixed set of children is the normal case,
/// not a mistake.
pub inline fn childrenAs(self: *const Self, comptime T: type) gdzig.Children(T) {
    const owner = gdzig.class.upcast(*const gdzig.class.Node, self);
    return .{ .owner = owner, .count = owner.getChildCount(.{}) };
}

// @mixin stop

const Self = gdzig.class.Node;

const gdzig = @import("gdzig");
