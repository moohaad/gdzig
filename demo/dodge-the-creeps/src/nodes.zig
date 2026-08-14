//! Small helper shared by the four classes.
//!
//! godot-rust spells this `get_node_as::<T>("path")`. gdzig has `getNode`,
//! which returns `?*Node`, plus `downcast`, so the demo would otherwise repeat
//! the same three lines everywhere.

/// The child at `path`, if it exists and is a `T`.
///
/// Null covers both "no such node" and "wrong type" -- for scene paths that are
/// fixed in the `.tscn`, either one means the scene and the code disagree,
/// which is worth handling at the call site rather than asserting here.
pub fn nodeAs(comptime T: type, parent: *const Node, comptime path: [:0]const u8) ?*T {
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
