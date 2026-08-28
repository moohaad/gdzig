//! Scene children as fields, read from the `.tscn` at comptime.
//!
//! [`Child(T, path)`](child.zig) puts one child next to the field that holds
//! it. `Scene` does the whole file at once, so the paths live in the scene
//! rather than being copied into the code:
//!
//! ```zig
//! children: Scene(@embedFile("../godot/Player.tscn")) = .{},
//!
//! pub fn onHit(self: *Player) void {
//!     if (self.children.CollisionShape2D.get()) |shape| shape.setDisabled(true);
//! }
//! ```
//!
//! Each node in the file becomes a field of the same name holding a
//! `Child(T, path)`, so `get`, `expect` and the liveness check come from there
//! unchanged, and resolution still happens once before `_ready`.
//!
//! Renaming a node in the editor now breaks the build instead of logging at
//! runtime, which is the point: the struct is derived from the file, so the
//! code cannot drift from it.
//!
//! ## Types
//!
//! A node's `type="AnimatedSprite2D"` becomes `gdzig.class.AnimatedSprite2d`.
//! Two cases fall back to `Node`, because neither names a type this can look
//! up:
//!
//! * an instanced sub-scene (`instance=ExtResource(...)`), which has no `type`
//!   at all -- the type lives in the other file
//! * a type `gdzig.class` does not declare, which is what a node of one of
//!   *your* registered classes looks like from here
//!
//! `Child(Node, path)` still resolves and still checks liveness; narrow it with
//! `gdzig.class.castTo` at the use site. The cost of the fallback is that a
//! misspelled engine type reads as a custom class and quietly becomes a `Node`.
//!
//! ## Field names
//!
//! Taken verbatim from the scene, because that is the name you see in the
//! editor. Godot allows names that are not Zig identifiers, which need
//! `self.children.@"Some Node"`.
//!
//! ## Inherited scenes
//!
//! Rejected at compile time. An inherited scene lists only the nodes it adds,
//! so the struct would silently be missing everything it got from its base.
//! Declare those with `Child(T, path)`, which says what it is looking for.

const std = @import("std");

const casez = @import("casez");
const common = @import("common");
const gdzig_case = common.gdzig_case;

const gdzig = @import("gdzig");
const Child = @import("child.zig").Child;
const oopz = @import("oopz");

/// A struct of `Child` fields, one per node in `tscn`.
pub fn Scene(comptime tscn: []const u8) type {
    comptime {
        @setEvalBranchQuota(quotaFor(tscn));
        return build(parse(tscn));
    }
}

/// Resolves the exact type of a node at `path` in `tscn`.
/// If the node is missing, it emits a @compileError.
/// If it's an instanced sub-scene, it resolves to `Node`.
pub fn resolvePathType(comptime tscn: []const u8, comptime path: [:0]const u8) type {
    comptime {
        const entries = parse(tscn);
        for (entries) |entry| {
            if (std.mem.eql(u8, entry.path, path)) {
                return Resolve(entry.type_name);
            }
        }
        @compileError("Node path not found in scene: " ++ path);
    }
}

/// Verifies that a node exists at `path` in `tscn`, and that its type is a valid `T`.
pub fn verifyPathType(comptime tscn: []const u8, comptime path: [:0]const u8, comptime T: type) void {
    comptime {
        const entries = parse(tscn);
        for (entries) |entry| {
            if (std.mem.eql(u8, entry.path, path)) {
                if (entry.type_name == null) {
                    // Instanced sub-scene; we can't strict verify without loading the other file.
                    // Just verify that T is at least an Object (which Child already does).
                    return;
                }
                const ActualType = Resolve(entry.type_name);
                oopz.assertIsA(T, ActualType);
                return;
            }
        }
        @compileError("Node path not found in scene: " ++ path);
    }
}

/// Split out from `Scene` so the scene text is not one of this function's
/// arguments. A generated type is named after the call that made it, and a
/// whole `.tscn` rendered into that name turns "no field named 'X'" -- the
/// error a renamed node produces, which is the point of the feature -- into
/// two kilobytes of scrollback.
fn build(comptime entries: []const Entry) type {
    comptime {
        var names: [entries.len][]const u8 = undefined;
        var types: [entries.len]type = undefined;
        var attrs: [entries.len]std.builtin.Type.StructField.Attributes = undefined;

        for (entries, 0..) |entry, i| {
            const F = Child(Resolve(entry.type_name), entry.path);
            names[i] = entry.field;
            types[i] = F;
            attrs[i] = .{ .default_value_ptr = @ptrCast(&F.pending) };
        }

        const n = names;
        const t = types;
        const a = attrs;
        return @Struct(.auto, null, &n, &t, &a);
    }
}

/// Parsing a scene is a comptime string scan, so the default 1000-branch
/// budget runs out on the first real file. Scaled to the input rather than
/// picked, so a big scene does not quietly need the number raised again.
fn quotaFor(comptime tscn: []const u8) u32 {
    return 10_000 + @as(u32, @intCast(tscn.len)) * 32;
}

const Entry = struct {
    /// The node's name, used verbatim as the field name.
    field: []const u8,
    /// Path from the scene root, what `getNode` is given.
    path: [:0]const u8,
    /// The `type=` attribute, or null when the node is an instanced sub-scene.
    type_name: ?[]const u8,
};

fn parse(comptime tscn: []const u8) []const Entry {
    comptime {
        @setEvalBranchQuota(quotaFor(tscn));
        var out: []const Entry = &.{};
        var root_seen = false;

        var lines = std.mem.splitScalar(u8, tscn, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, "\r");
            if (!std.mem.startsWith(u8, line, "[node ")) continue;

            const name = attr(line, "name") orelse
                @compileError("Scene: [node] with no name:\n  " ++ line);
            const parent = attr(line, "parent");
            const instanced = std.mem.indexOf(u8, line, " instance=") != null;

            // No `parent` means the scene root, which is the class this struct
            // is a field of rather than one of its children.
            if (parent == null) {
                if (root_seen)
                    @compileError("Scene: more than one root node, second is:\n  " ++ line);
                root_seen = true;
                if (instanced) @compileError(
                    "Scene: inherited scenes are not supported. The file lists only the " ++
                        "nodes it adds, so every child it inherits would be missing from the " ++
                        "struct without saying so. Use Child(T, path) for those instead.\n  " ++ line,
                );
                continue;
            }

            const path = if (std.mem.eql(u8, parent.?, ""))
                @compileError("Scene: empty parent on:\n  " ++ line)
            else if (std.mem.eql(u8, parent.?, "."))
                name
            else
                parent.? ++ "/" ++ name;

            out = out ++ &[_]Entry{.{
                .field = name,
                // `comptimePrint` is how a comptime slice gets its sentinel.
                .path = std.fmt.comptimePrint("{s}", .{path}),
                .type_name = if (instanced) null else attr(line, "type"),
            }};
        }

        if (!root_seen) @compileError("Scene: no root [node] in this file; is it a .tscn?");
        return out;
    }
}

/// The value of `key="..."` on a `[node]` line, or null if absent. Matched with
/// a leading space so `name` cannot hit the tail of another attribute.
fn attr(comptime line: []const u8, comptime key: []const u8) ?[]const u8 {
    comptime {
        const needle = " " ++ key ++ "=\"";
        const start = std.mem.indexOf(u8, line, needle) orelse return null;
        const from = start + needle.len;
        const len = std.mem.indexOfScalar(u8, line[from..], '"') orelse
            @compileError("Scene: unterminated " ++ key ++ " on:\n  " ++ line);
        return line[from..][0..len];
    }
}

/// Godot's type name to the gdzig class, falling back to `Node`. See the
/// module docs for why the fallback is silent.
fn Resolve(comptime type_name: ?[]const u8) type {
    comptime {
        const godot_name = type_name orelse return gdzig.class.Node;
        const zig_name = casez.comptimeConvert(gdzig_case.type, godot_name);
        if (!@hasDecl(gdzig.class, zig_name)) return gdzig.class.Node;
        const T = @field(gdzig.class, zig_name);
        if (@TypeOf(T) != type) return gdzig.class.Node;
        return T;
    }
}

test "parses children, paths and types" {
    const tscn =
        \\[gd_scene load_steps=2 format=3 uid="uid://abc"]
        \\
        \\[ext_resource type="Texture2D" path="res://art/x.png" id="1"]
        \\
        \\[node name="Player" type="Area2D"]
        \\[node name="AnimatedSprite2D" type="AnimatedSprite2D" parent="."]
        \\[node name="MobPath" type="Path2D" parent="."]
        \\[node name="MobSpawnLocation" type="PathFollow2D" parent="MobPath"]
        \\
    ;
    const entries = comptime parse(tscn);

    try std.testing.expectEqual(@as(usize, 3), entries.len);
    try std.testing.expectEqualStrings("AnimatedSprite2D", entries[0].field);
    try std.testing.expectEqualStrings("AnimatedSprite2D", entries[0].path);
    try std.testing.expectEqualStrings("MobSpawnLocation", entries[2].field);
    // Nested nodes carry the parent, which is what `getNode` needs.
    try std.testing.expectEqualStrings("MobPath/MobSpawnLocation", entries[2].path);
}

test "an instanced sub-scene has no type of its own" {
    const tscn =
        \\[node name="Main" type="Node"]
        \\[node name="Player" parent="." instance=ExtResource("3")]
        \\
    ;
    const entries = comptime parse(tscn);
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expect(entries[0].type_name == null);
    try std.testing.expectEqual(gdzig.class.Node, Resolve(entries[0].type_name));
}

test "groups and other attributes do not confuse the name" {
    const tscn =
        \\[node name="Mob" type="Node" groups=["mobs"]]
        \\[node name="Sprite" type="Sprite2D" parent="." groups=["a", "b"]]
        \\
    ;
    const entries = comptime parse(tscn);
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("Sprite", entries[0].field);
    try std.testing.expectEqualStrings("Sprite2D", entries[0].type_name.?);
}

test "type names convert to gdzig casing" {
    try std.testing.expectEqual(gdzig.class.AnimatedSprite2d, Resolve("AnimatedSprite2D"));
    try std.testing.expectEqual(gdzig.class.GpuParticles2d, Resolve("GPUParticles2D"));
    try std.testing.expectEqual(gdzig.class.Marker2d, Resolve("Marker2D"));
    // Not an engine class -- a node of one of your own registered classes.
    try std.testing.expectEqual(gdzig.class.Node, Resolve("SomeClassOfMine"));
}

test "the generated struct has a field per child" {
    const tscn =
        \\[node name="Player" type="Area2D"]
        \\[node name="AnimatedSprite2D" type="AnimatedSprite2D" parent="."]
        \\[node name="CollisionShape2D" type="CollisionShape2D" parent="."]
        \\
    ;
    const S = Scene(tscn);
    const fields = @typeInfo(S).@"struct".fields;

    try std.testing.expectEqual(@as(usize, 2), fields.len);
    try std.testing.expectEqualStrings("AnimatedSprite2D", fields[0].name);
    try std.testing.expectEqual(
        Child(gdzig.class.CollisionShape2d, "CollisionShape2D"),
        fields[1].type,
    );

    // Every field defaults, so the whole thing is `= .{}` at the use site.
    const s: S = .{};
    try std.testing.expect(s.CollisionShape2D.get() == null);
}
