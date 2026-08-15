//! Scene children declared as fields and resolved before `_ready`.
//!
//! Reaching a child normally means writing the lookup by hand in `_ready`, once
//! per child, and finding somewhere to keep the result:
//!
//! ```zig
//! hud: Weak(Hud) = .empty,
//!
//! pub fn _ready(self: *Main) void {
//!     if (nodeAs(Hud, self.base, "Hud")) |h| self.hud = .init(h);
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
                std.log.err(
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

    const node = owner.getNode(node_path) orelse return null;
    return class.castTo(T, node);
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
