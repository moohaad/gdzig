//! Scene children declared as fields and resolved before `_ready`.
//!
//! Reaching a child normally means writing the lookup by hand in `_ready`, once
//! per child, and finding somewhere to keep the result:
//!
//! ```zig
//! hud: Weak(Hud) = .empty,
//!
//! pub fn _ready(self: *Main) void {
//!     var path: NodePath = .fromString(.fromLatin1("Hud"));
//!     defer path.deinit();
//!     if (self.base.getNode(path)) |node| {
//!         if (gdzig.class.castTo(Hud, node)) |hud| self.hud = .init(hud);
//!     }
//! }
//! ```
//!
//! `Child` moves the path next to the field and does the lookup for you:
//!
//! ```zig
//! hud: Child(Hud, "Hud") = .pending,
//!
//! pub fn doThing(self: *Main) void {
//!     if (self.hud.get()) |hud| hud.showGameOver();
//! }
//! ```
//!
//! This is gdzig's answer to godot-rust's `OnReady<Gd<T>>`, and it shares the
//! same premise: the node does not exist when the struct is built, so the field
//! cannot be initialised there.
//!
//! ## When resolution happens
//!
//! Immediately before your `_ready`, walking the struct's fields once. A class
//! with `Child` fields gets a `_ready` in its vtable whether or not it declares
//! one, so the fields are populated either way.
//!
//! ## What happens when the node is missing
//!
//! `get` returns null and an error is logged naming the field and path. A
//! missing child means the scene and the code disagree, which is worth seeing
//! rather than crashing on -- and since the result is a [`Weak`](weak.zig)
//! handle, `get` stays honest afterwards if the node is freed later.
//!
//! ## Autoloads
//!
//! [`Autoload(T, "Name")`](#Autoload) is the same field at `/root/Name`,
//! for the singletons `project.godot` loads before the main scene.
//!
//! ## Or let the scene declare them
//!
//! [`Scene(@embedFile("Main.tscn"))`](scene.zig) builds a struct of these from
//! the file, so the paths are not written out at all and a rename fails the
//! build. `Child` remains the right tool for what a scene file cannot type: an
//! instanced sub-scene, a node inherited from a base scene, or one added at
//! runtime.

const std = @import("std");

const oopz = @import("oopz");

const gdzig = @import("gdzig");
const class = @import("class.zig");
const Node = class.Node;
const NodePath = gdzig.builtin.NodePath;
const String = gdzig.builtin.String;
const Weak = @import("weak.zig").Weak;

/// A field holding the child at `path`, resolved before `_ready`.
pub fn Child(comptime T: type, comptime path: [:0]const u8) type {
    comptime oopz.assertIsA(class.Object, T);

    return struct {
        const Self = @This();

        /// Marks this as a resolvable field and says what to look for. Read by
        /// `resolveAll` at comptime; not part of the API.
        pub const Resolves = T;
        pub const node_path: [:0]const u8 = path;

        handle: Weak(T) = .empty,

        /// Not yet looked up. The only value you should write.
        pub const pending: Self = .{ .handle = .empty };

        /// The child, or null if the scene did not have it or it has since been
        /// freed.
        pub fn get(self: Self) ?*T {
            return self.handle.get();
        }

        /// The child, panicking if it is absent. For a node the scene is
        /// required to have, where a null is a bug rather than a case.
        pub fn expect(self: Self) *T {
            return self.get() orelse
                @panic("child '" ++ path ++ "' of type " ++ @typeName(T) ++ " is missing or freed");
        }
    };
}

/// A field holding the child at `path`, resolved before `_ready`.
/// The type `T` is automatically inferred from the `.tscn` file at compile time.
pub fn SceneNode(comptime tscn: []const u8, comptime path: [:0]const u8) type {
    const ExactType = @import("scene.zig").resolvePathType(tscn, path);
    return Child(ExactType, path);
}

/// A field holding the child at `path`, resolved before `_ready`.
/// It verifies at compile time that the node at `path` in `tscn` is of type `T`.
pub fn SceneNodeAs(comptime tscn: []const u8, comptime path: [:0]const u8, comptime T: type) type {
    @import("scene.zig").verifyPathType(tscn, path, T);
    return Child(T, path);
}

/// The autoload named `name`, resolved before `_ready` like any other field.
///
/// Godot puts an autoload under `/root` before the main scene loads, so it is
/// reachable by absolute path from anywhere in the tree -- which makes it a
/// `Child` whose path happens to start at the root, and this is that spelling:
///
/// ```zig
/// bus: Autoload(EventBusNode, "EventBus") = .pending,
/// ```
///
/// `name` is the one in `project.godot`'s `[autoload]` section, and the
/// `/root/` prefix is added here rather than at each use site. `T` may be one
/// of your registered classes or an engine class; an autoload still written in
/// GDScript resolves as `Node`, which is all `call` and `emit` need.
///
/// Ordering is what makes this safe, including the case that looks unsafe:
/// one autoload reaching another. Godot has every autoload in the tree before
/// it runs `_ready` on any of them, so resolution does not depend on the order
/// they are listed in -- measured with an autoload declared *first* resolving
/// one declared after it, which fails loudly if that ever stops holding.
pub fn Autoload(comptime T: type, comptime name: [:0]const u8) type {
    // `comptimePrint` is how a comptime slice gets its sentinel, the same way
    // `Scene` builds its paths.
    return Child(T, std.fmt.comptimePrint("/root/{s}", .{name}));
}

/// The node this one is parented to, resolved before `_ready` like any other
/// field:
///
/// ```zig
/// target: Parent(Node3d) = .pending,
/// ```
///
/// `..` is Godot's own spelling for the parent in a NodePath, so this is a
/// `Child` pointed one level up.
///
/// It exists to delete a cast. Reaching a parent otherwise means `getParent()`,
/// which returns `?*Node` because that is all Godot promises, and then a
/// `castTo` at every use site. Naming the type here does that narrowing once,
/// at `_ready`, and turns "I assume my parent is a Node3D" from a cast repeated
/// every tick into a declaration that says so and logs if it is wrong.
pub fn Parent(comptime T: type) type {
    return Child(T, "..");
}

/// Walks a node's children, yielding only the ones that are a `T`.
///
/// Returned by `Node.childrenAs`; there is no reason to name this type.
///
/// `get_children` hands back an `Array` of `Variant`, so doing this by hand
/// means unpacking each element, casting it, deciding what to do with the ones
/// that do not match, and freeing the array. This walks by index instead: no
/// array is built, so there is nothing to free.
///
/// The child count is read once. Adding or removing children while iterating is
/// therefore on you -- `queueFree` is deferred and safe, `removeChild` is not.
pub fn Children(comptime T: type) type {
    comptime oopz.assertIsA(class.Object, T);

    return struct {
        const Self = @This();

        owner: *const Node,
        count: i32,
        index: i32 = 0,
        include_internal: bool = false,

        /// The next child that is a `T`, or null at the end.
        pub fn next(self: *Self) ?*T {
            while (self.index < self.count) {
                const child = self.owner.getChild(self.index, .{ .include_internal = self.include_internal });
                self.index += 1;
                if (child) |node| {
                    if (class.castTo(T, node)) |typed| return typed;
                }
            }
            return null;
        }
    };
}

/// Whether `T` declares any `Child` fields, and so needs a `_ready` even if the
/// user did not write one.
pub fn hasAny(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (comptime isChild(field.type)) return true;
        if (comptime isGroup(field.type)) return true;
    }
    return false;
}

/// Fills in every `Child` field on `instance`. Called from the vtable's
/// `_ready` wrapper, before the user's own `_ready`.
pub fn resolveAll(comptime T: type, instance: *T) void {
    const owner = oopz.upcast(*Node, instance);
    resolveInto(T, @typeName(T), instance, owner);
}

/// One level of the walk. Paths stay relative to `owner`, the node the class
/// itself is, however deeply the field is nested.
fn resolveInto(comptime S: type, comptime label: []const u8, target: *S, owner: *Node) void {
    inline for (@typeInfo(S).@"struct".fields) |field| {
        if (comptime isChild(field.type)) {
            const Target = field.type.Resolves;
            const found = lookup(Target, owner, field.type.node_path);
            if (found) |node| {
                @field(target, field.name) = .{ .handle = .init(node) };
            } else {
                // Godot's Debugger panel rather than the process's stderr,
                // which the engine does not capture: an editor session is
                // where a scene and a declaration disagree, and stderr is
                // not where anyone is looking. `bind_nodes` reports the
                // same way, so the two spellings fail alike.
                gdzig.pushWarning(
                    "{s}.{s}: no child '{s}' of type {s}",
                    .{ label, field.name, field.type.node_path, @typeName(Target) },
                );
            }
        } else if (comptime isGroup(field.type)) {
            resolveInto(
                field.type,
                label ++ "." ++ field.name,
                &@field(target, field.name),
                owner,
            );
        }
    }
}

/// A struct whose fields are all `Child`, which is what `Scene` builds and what
/// hand-grouping them looks like. Recognised structurally because a type made
/// by `@Struct` cannot carry a marker declaration.
///
/// Deliberately narrow: descending into *any* struct would walk every `Vector2`
/// and `String` on the class looking for something that cannot be there.
fn isGroup(comptime F: type) bool {
    const info = @typeInfo(F);
    if (info != .@"struct") return false;
    if (info.@"struct".layout != .auto) return false;
    if (info.@"struct".fields.len == 0) return false;
    if (isChild(F)) return false;
    inline for (info.@"struct".fields) |field| {
        if (!isChild(field.type)) return false;
    }
    return true;
}

/// Exact test for `Child(U, p)`, so an unrelated struct that happens to declare
/// `Resolves` cannot be mistaken for one.
fn isChild(comptime F: type) bool {
    if (@typeInfo(F) != .@"struct") return false;
    if (!@hasDecl(F, "Resolves") or !@hasDecl(F, "node_path")) return false;
    return F == Child(F.Resolves, F.node_path);
}

fn lookup(comptime T: type, owner: *Node, comptime path: [:0]const u8) ?*T {
    var text: String = .fromLatin1(path);
    defer text.deinit();
    var node_path: NodePath = .fromString(text);
    defer node_path.deinit();

    // `getNode` prints an engine error of its own when the path is empty, so a
    // missing child reported two ways: Godot's ERROR and then ours. The
    // or-null form asks the same question without complaining, which leaves the
    // one warning below -- the same one `bind_nodes` produces.
    const node = owner.getNodeOrNull(node_path) orelse return null;
    return class.castTo(T, node);
}

test "an autoload is a child at an absolute path" {
    try std.testing.expectEqual(
        Child(gdzig.class.Node, "/root/EventBus"),
        Autoload(gdzig.class.Node, "EventBus"),
    );

    // The part worth pinning: a class whose only resolvable field is an
    // `Autoload` still gets a `_ready` in its vtable, so the field is filled.
    const Holder = struct { bus: Autoload(gdzig.class.Node, "EventBus") = .pending };
    try std.testing.expect(hasAny(Holder));
}

test "Child is recognised only as itself" {
    const Impostor = struct {
        pub const Resolves = gdzig.class.Node;
        pub const node_path: [:0]const u8 = "X";
        handle: u8 = 0,
    };
    try std.testing.expect(isChild(Child(gdzig.class.Node, "X")));
    try std.testing.expect(!isChild(Impostor));
    try std.testing.expect(!isChild(u32));
}
