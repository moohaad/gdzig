//! Small helper shared by the four classes.
//!
//! godot-rust spells this `get_node_as::<T>("path")`. gdzig has `getNode`, which
//! returns `?*Node`, plus a downcast, so the demo would otherwise repeat the
//! same three lines everywhere.

/// The child at `path`, if it exists and is a `T`.
///
/// `parent` is `anytype` rather than `*Node` on purpose: gdzig flattens every
/// inherited method into each class, so `getNode` is already present on
/// `Area2d`, `CanvasLayer` and the rest. Taking `*Node` would force every call
/// site to write an upcast that buys nothing.
///
/// Null covers both "no such node" and "wrong type" -- for scene paths fixed in
/// the `.tscn`, either means the scene and the code disagree, which is worth
/// handling at the call site rather than asserting here.
pub fn nodeAs(comptime T: type, parent: anytype, comptime path: [:0]const u8) ?*T {
    var text: String = .fromLatin1(path);
    defer text.deinit();
    var node_path: NodePath = .fromString(text);
    defer node_path.deinit();

    const node = parent.getNode(node_path) orelse return null;

    // Engine classes are opaque and carry their own `downcast`; a class defined
    // here is a plain struct reached through its instance binding instead.
    if (comptime godot.class.isStructClass(T)) {
        const typed = Node.downcast(node) orelse return null;
        return typed.asInstance(T);
    }
    return T.downcast(node);
}

const godot = @import("godot");
const Node = godot.class.Node;
const NodePath = godot.builtin.NodePath;
const String = godot.builtin.String;
