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
//! An instanced sub-scene (`instance=ExtResource(...)`) gets the type of the
//! root in the referenced file. Inherited scenes recursively include the
//! children from every base scene as well as the nodes they add themselves.
//! Both need `.godot_project` on the gdzig dependency so the build can generate
//! the cross-file scene catalog.
//!
//! A type `gdzig.class` does not declare is one of your registered classes (or
//! a misspelling), and plain `Scene` falls back to `Node` for it. Use
//! `SceneWith` and a namespace mapping Godot class names to Zig types to retain
//! those concrete types too:
//!
//! ```zig
//! const Types = struct { pub const Player = @import("Player.zig"); };
//! children: SceneWith(@embedFile("Main.tscn"), Types) = .{},
//! ```
//!
//! ## Field names
//!
//! Taken verbatim from the scene, because that is the name you see in the
//! editor. Godot allows names that are not Zig identifiers, which need
//! `self.children.@"Some Node"`.
//!
const std = @import("std");

const casez = @import("casez");
const common = @import("common");
const gdzig_case = common.gdzig_case;

const gdzig = @import("gdzig");
const Child = @import("child.zig").Child;
const oopz = @import("oopz");
const project_scenes = @import("project_scenes");

const NoUserTypes = struct {};

/// A struct of `Child` fields, one per node in `tscn`.
pub fn Scene(comptime tscn: []const u8) type {
    return SceneWith(tscn, NoUserTypes);
}

/// Like `Scene`, with a namespace of user-defined Godot classes.
///
/// Each public type declaration is keyed by the class name stored in the
/// `.tscn`, including roots reached through instancing or inheritance.
pub fn SceneWith(comptime tscn: []const u8, comptime user_types: type) type {
    comptime {
        @setEvalBranchQuota(quotaFor(tscn, project_scenes.files));
        return build(parse(tscn), user_types);
    }
}

/// Resolves the exact type of a node at `path` in `tscn`.
/// If the node is missing, it emits a @compileError.
pub fn resolvePathType(comptime tscn: []const u8, comptime path: [:0]const u8) type {
    comptime {
        @setEvalBranchQuota(quotaFor(tscn, project_scenes.files));
        const entries = parse(tscn);
        for (entries) |entry| {
            if (std.mem.eql(u8, entry.path, path)) {
                return Resolve(entry.type_name, NoUserTypes);
            }
        }
        @compileError("Node path not found in scene: " ++ path);
    }
}

/// Verifies that a node exists at `path` in `tscn`, and that its type is a valid `T`.
pub fn verifyPathType(comptime tscn: []const u8, comptime path: [:0]const u8, comptime T: type) void {
    comptime {
        @setEvalBranchQuota(quotaFor(tscn, project_scenes.files));
        const entries = parse(tscn);
        for (entries) |entry| {
            if (std.mem.eql(u8, entry.path, path)) {
                if (entry.type_name == null) {
                    // With no project catalog a referenced scene cannot be
                    // opened. Preserve the safe `Node` fallback for callers
                    // that embed individual files by hand.
                    return;
                }
                const zig_name = casez.comptimeConvert(gdzig_case.type, entry.type_name.?);
                // A user class is not in gdzig.class. The caller supplied its
                // Zig type explicitly, so the scene name alone cannot prove or
                // disprove that mapping; runtime castTo remains the check.
                if (!@hasDecl(gdzig.class, zig_name)) return;
                if (@TypeOf(@field(gdzig.class, zig_name)) != type) return;
                const ActualType = Resolve(entry.type_name, NoUserTypes);
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
fn build(comptime entries: []const Entry, comptime user_types: type) type {
    comptime {
        var names: [entries.len][]const u8 = undefined;
        var types: [entries.len]type = undefined;
        var attrs: [entries.len]std.builtin.Type.StructField.Attributes = undefined;

        for (entries, 0..) |entry, i| {
            const F = Child(Resolve(entry.type_name, user_types), entry.path);
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
fn quotaFor(comptime tscn: []const u8, comptime catalog: anytype) u32 {
    var bytes = tscn.len;
    for (catalog) |scene| bytes += scene.contents.len;
    return 20_000 + @as(u32, @intCast(@min(bytes, 10_000_000))) * 32;
}

const Entry = struct {
    /// The node's name, used verbatim as the field name.
    field: []const u8,
    /// Path from the scene root, what `getNode` is given.
    path: [:0]const u8,
    /// Godot's class name, or null when a cross-file reference is unavailable.
    type_name: ?[]const u8,
};

fn parse(comptime tscn: []const u8) []const Entry {
    return parseFrom(tscn, project_scenes.files, &.{});
}

fn parseFrom(
    comptime tscn: []const u8,
    comptime catalog: anytype,
    comptime stack: []const []const u8,
) []const Entry {
    comptime {
        @setEvalBranchQuota(quotaFor(tscn, catalog));
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
                if (instanced) {
                    const base_path = instancePath(tscn, line) orelse @compileError(
                        "Scene: inherited root has no resolvable PackedScene resource:\n  " ++ line,
                    );
                    rejectCycle(base_path, stack);
                    const base = findScene(catalog, base_path) orelse @compileError(
                        "Scene: inherited scene '" ++ base_path ++ "' is not in the project " ++
                            "catalog. Pass .godot_project to the gdzig dependency so inherited " ++
                            "and instanced scenes can be followed.",
                    );
                    out = parseFrom(base, catalog, stack ++ &[_][]const u8{base_path});
                }
                continue;
            }

            const path = if (std.mem.eql(u8, parent.?, ""))
                @compileError("Scene: empty parent on:\n  " ++ line)
            else if (std.mem.eql(u8, parent.?, "."))
                name
            else
                parent.? ++ "/" ++ name;

            const type_name = if (instanced)
                instanceRootType(tscn, line, catalog, stack)
            else
                attr(line, "type");
            const entry: Entry = .{
                .field = name,
                // `comptimePrint` is how a comptime slice gets its sentinel.
                .path = std.fmt.comptimePrint("{s}", .{path}),
                .type_name = type_name,
            };

            // Inherited scenes write property overrides as untyped [node]
            // sections. The base entry already carries the actual type; an
            // untyped override must not replace it with Node.
            var replaced = false;
            for (out, 0..) |existing, i| {
                if (!std.mem.eql(u8, existing.path, entry.path)) continue;
                replaced = true;
                if (type_name != null) {
                    out = out[0..i] ++ &[_]Entry{entry} ++ out[i + 1 ..];
                }
                break;
            }
            if (!replaced) out = out ++ &[_]Entry{entry};
        }

        if (!root_seen) @compileError("Scene: no root [node] in this file; is it a .tscn?");
        return out;
    }
}

/// The project path behind `instance=ExtResource("id")` on a node line.
fn instancePath(comptime tscn: []const u8, comptime line: []const u8) ?[]const u8 {
    const id = callStringArg(line, "instance=ExtResource") orelse return null;
    var lines = std.mem.splitScalar(u8, tscn, '\n');
    while (lines.next()) |raw| {
        const resource = std.mem.trimEnd(u8, raw, "\r");
        if (!std.mem.startsWith(u8, resource, "[ext_resource ")) continue;
        const resource_id = attr(resource, "id") orelse continue;
        if (!std.mem.eql(u8, resource_id, id)) continue;
        return attr(resource, "path");
    }
    return null;
}

fn instanceRootType(
    comptime tscn: []const u8,
    comptime line: []const u8,
    comptime catalog: anytype,
    comptime stack: []const []const u8,
) ?[]const u8 {
    const path = instancePath(tscn, line) orelse return null;
    rejectCycle(path, stack);
    const source = findScene(catalog, path) orelse return null;
    return rootType(source, catalog, stack ++ &[_][]const u8{path});
}

fn rootType(
    comptime tscn: []const u8,
    comptime catalog: anytype,
    comptime stack: []const []const u8,
) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, tscn, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (!std.mem.startsWith(u8, line, "[node ")) continue;
        if (attr(line, "parent") != null) continue;
        if (attr(line, "type")) |type_name| return type_name;
        return instanceRootType(tscn, line, catalog, stack);
    }
    return null;
}

fn findScene(comptime catalog: anytype, comptime path: []const u8) ?[]const u8 {
    for (catalog) |scene| {
        if (std.mem.eql(u8, scene.path, path)) return scene.contents;
    }
    return null;
}

fn rejectCycle(comptime path: []const u8, comptime stack: []const []const u8) void {
    for (stack) |ancestor| {
        if (std.mem.eql(u8, ancestor, path))
            @compileError("Scene: inheritance or instancing cycle through '" ++ path ++ "'");
    }
}

fn callStringArg(comptime line: []const u8, comptime function: []const u8) ?[]const u8 {
    const needle = " " ++ function ++ "(\"";
    const start = std.mem.indexOf(u8, line, needle) orelse return null;
    const from = start + needle.len;
    const len = std.mem.indexOfScalar(u8, line[from..], '"') orelse
        @compileError("Scene: unterminated " ++ function ++ " on:\n  " ++ line);
    return line[from..][0..len];
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
fn Resolve(comptime type_name: ?[]const u8, comptime user_types: type) type {
    comptime {
        const godot_name = type_name orelse return gdzig.class.Node;
        if (@hasDecl(user_types, godot_name)) {
            const T = @field(user_types, godot_name);
            if (@TypeOf(T) != type)
                @compileError("SceneWith: '" ++ godot_name ++ "' must name a type");
            return T;
        }
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

test "an unavailable instanced sub-scene safely falls back to Node" {
    const tscn =
        \\[node name="Main" type="Node"]
        \\[node name="Player" parent="." instance=ExtResource("3")]
        \\
    ;
    const entries = comptime parse(tscn);
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expect(entries[0].type_name == null);
    try std.testing.expectEqual(gdzig.class.Node, Resolve(entries[0].type_name, NoUserTypes));
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
    try std.testing.expectEqual(gdzig.class.AnimatedSprite2d, Resolve("AnimatedSprite2D", NoUserTypes));
    try std.testing.expectEqual(gdzig.class.GpuParticles2d, Resolve("GPUParticles2D", NoUserTypes));
    try std.testing.expectEqual(gdzig.class.Marker2d, Resolve("Marker2D", NoUserTypes));
    // Not an engine class -- a node of one of your own registered classes.
    try std.testing.expectEqual(gdzig.class.Node, Resolve("SomeClassOfMine", NoUserTypes));
}

test "instanced roots are typed and inherited children are merged" {
    const base =
        \\[node name="Base" type="Node2D"]
        \\[node name="BaseSprite" type="Sprite2D" parent="."]
        \\[node name="Changed" type="Timer" parent="."]
        \\
    ;
    const actor =
        \\[node name="Actor" type="CharacterBody2D"]
        \\[node name="Shape" type="CollisionShape2D" parent="."]
        \\
    ;
    const derived =
        \\[gd_scene load_steps=3 format=3]
        \\[ext_resource type="PackedScene" path="res://base.tscn" id="1_base"]
        \\[ext_resource type="PackedScene" path="res://actor.tscn" id="2_actor"]
        \\[node name="Derived" instance=ExtResource("1_base")]
        \\[node name="Changed" parent="."]
        \\[node name="Actor" parent="." instance=ExtResource("2_actor")]
        \\[node name="Local" type="Camera2D" parent="."]
        \\
    ;
    const File = struct { path: []const u8, contents: []const u8 };
    const catalog = [_]File{
        .{ .path = "res://base.tscn", .contents = base },
        .{ .path = "res://actor.tscn", .contents = actor },
    };
    const entries = comptime parseFrom(derived, catalog, &.{});

    try std.testing.expectEqual(@as(usize, 4), entries.len);
    try std.testing.expectEqualStrings("BaseSprite", entries[0].path);
    try std.testing.expectEqualStrings("Sprite2D", entries[0].type_name.?);
    // An untyped property override keeps the inherited declaration's type.
    try std.testing.expectEqualStrings("Timer", entries[1].type_name.?);
    try std.testing.expectEqualStrings("CharacterBody2D", entries[2].type_name.?);
    try std.testing.expectEqualStrings("Camera2D", entries[3].type_name.?);
}

test "SceneWith maps user class names reached through instancing" {
    const UserPlayer = struct {};
    const Types = struct {
        pub const Player = UserPlayer;
    };
    try std.testing.expectEqual(UserPlayer, Resolve("Player", Types));
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
