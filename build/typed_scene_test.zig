//! Checks cross-file scene typing through a scaffolded consumer project.
//!
//! Unit tests can feed the parser an in-memory catalog. This gate proves the
//! build actually catalogs every scene, follows a two-level inherited scene,
//! and invalidates the generated module when an instanced scene changes.

pub fn main(init: std.process.Init) !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = init.io;

    var args = try init.minimal.args.iterateAllocator(arena);
    _ = args.next();

    const scaffolder = args.next() orelse return fail("expected the init executable's path", .{});
    const out_path = args.next() orelse return fail("expected an output directory", .{});
    const dep_path = args.next() orelse return fail("expected a relative path to gdzig", .{});
    const godot_path = args.next();
    const godot_option = if (godot_path) |path|
        try std.fmt.allocPrint(arena, "-Dgodot-path={s}", .{path})
    else
        null;

    std.Io.Dir.cwd().deleteTree(io, out_path) catch {};
    try run(io, ".", &.{ scaffolder, "--name", "sceneprobe", "--out", out_path }, null);

    var dir = try std.Io.Dir.openDir(.cwd(), io, out_path, .{});
    defer dir.close(io);

    const manifest = try dir.readFileAlloc(io, "build.zig.zon", arena, @enumFromInt(1 << 20));
    const fingerprint = try between(manifest, ".fingerprint = ", ",");
    try dir.writeFile(io, .{ .sub_path = "build.zig.zon", .data = try std.fmt.allocPrint(arena,
        \\.{{
        \\    .name = .sceneprobe,
        \\    .version = "0.0.0",
        \\    .fingerprint = {s},
        \\    .minimum_zig_version = "0.16.0",
        \\    .dependencies = .{{
        \\        .gdzig = .{{ .path = "{s}" }},
        \\    }},
        \\    .paths = .{{ "build.zig", "build.zig.zon", "src" }},
        \\}}
        \\
    , .{ fingerprint, dep_path }) });

    try dir.createDirPath(io, ".godot");
    try dir.writeFile(io, .{
        .sub_path = ".godot/extension_list.cfg",
        .data = "res://sceneprobe.gdextension\n",
    });
    try dir.writeFile(io, .{ .sub_path = "ancestor.tscn", .data =
        \\[gd_scene format=3]
        \\
        \\[node name="Ancestor" type="Node2D"]
        \\[node name="DeepMarker" type="Marker2D" parent="."]
        \\
    });
    try dir.writeFile(io, .{ .sub_path = "base.tscn", .data =
        \\[gd_scene load_steps=2 format=3]
        \\
        \\[ext_resource type="PackedScene" path="res://ancestor.tscn" id="1_ancestor"]
        \\
        \\[node name="Base" instance=ExtResource("1_ancestor")]
        \\[node name="DeepMarker" parent="."]
        \\[node name="BaseSprite" type="Sprite2D" parent="."]
        \\
    });
    try dir.writeFile(io, .{ .sub_path = "actor.tscn", .data = actorScene("CharacterBody2D") });
    try dir.writeFile(io, .{ .sub_path = "derived.tscn", .data =
        \\[gd_scene load_steps=3 format=3]
        \\
        \\[ext_resource type="PackedScene" path="res://base.tscn" id="1_base"]
        \\[ext_resource type="PackedScene" path="res://actor.tscn" id="2_actor"]
        \\
        \\[node name="Derived" instance=ExtResource("1_base")]
        \\[node name="Actor" parent="." instance=ExtResource("2_actor")]
        \\[node name="LocalTimer" type="Timer" parent="."]
        \\
    });

    const entry = "src/sceneprobe.zig";
    try dir.writeFile(io, .{ .sub_path = entry, .data = probeSource() });
    try runBuild(io, out_path, godot_option, null);

    // The parent scene did not change. Changing only the referenced scene must
    // regenerate the catalog and make its old concrete-type assertion fail.
    try dir.writeFile(io, .{ .sub_path = "actor.tscn", .data = actorScene("Node3D") });
    var output: std.ArrayList(u8) = .empty;
    const failed = runBuild(io, out_path, godot_option, &output);
    if (failed) |_| return fail(
        "changing an instanced scene's root did not invalidate its inferred type",
        .{},
    ) else |_| {}
    if (std.mem.indexOf(u8, output.items, "Actor") == null or
        std.mem.indexOf(u8, output.items, "CharacterBody2d") == null)
    {
        return fail("the stale scene type error was not useful; got:\n{s}", .{output.items});
    }

    std.debug.print("typed scenes: followed instancing and two inherited levels\n", .{});
}

fn actorScene(comptime root_type: []const u8) []const u8 {
    return
    \\[gd_scene format=3]
    \\
    \\[node name="Actor" type="
    ++ root_type ++
        \\"]
        \\[node name="Shape" type="CollisionShape2D" parent="."]
        \\
    ;
}

fn probeSource() []const u8 {
    return
    \\pub fn register(r: *godot.extension.Registry) void {
    \\    _ = r;
    \\    comptime {
    \\        expectType("DeepMarker", godot.class.Marker2d);
    \\        expectType("BaseSprite", godot.class.Sprite2d);
    \\        expectType("Actor", godot.class.CharacterBody2d);
    \\        expectType("LocalTimer", godot.class.Timer);
    \\    }
    \\}
    \\
    \\const Children = godot.Scene(@embedFile("derived.tscn"));
    \\
    \\fn expectType(comptime name: []const u8, comptime Expected: type) void {
    \\    inline for (@typeInfo(Children).@"struct".fields) |field| {
    \\        if (comptime std.mem.eql(u8, field.name, name)) {
    \\            if (field.type.Resolves != Expected)
    \\                @compileError(name ++ " should resolve to " ++ @typeName(Expected));
    \\            return;
    \\        }
    \\    }
    \\    @compileError("scene has no generated field named " ++ name);
    \\}
    \\
    \\const std = @import("std");
    \\const godot = @import("godot");
    \\
    ;
}

fn runBuild(
    io: std.Io,
    cwd_path: []const u8,
    godot_option: ?[]const u8,
    collect: ?*std.ArrayList(u8),
) !void {
    if (godot_option) |option| return run(io, cwd_path, &.{ "zig", "build", option }, collect);
    return run(io, cwd_path, &.{ "zig", "build" }, collect);
}

fn run(io: std.Io, cwd_path: []const u8, argv: []const []const u8, collect: ?*std.ArrayList(u8)) !void {
    var cwd = try std.Io.Dir.openDir(.cwd(), io, cwd_path, .{});
    defer cwd.close(io);

    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .dir = cwd },
        .stderr = if (collect == null) .inherit else .pipe,
    });
    if (collect) |out| {
        var buf: [4096]u8 = undefined;
        var reader = child.stderr.?.readerStreaming(io, &buf);
        const captured = try reader.interface.allocRemaining(std.heap.page_allocator, .limited(1 << 22));
        defer std.heap.page_allocator.free(captured);
        try out.appendSlice(std.heap.page_allocator, captured);
    }

    const term = try child.wait(io);
    if (term != .exited or term.exited != 0) return error.CommandFailed;
}

fn between(haystack: []const u8, open: []const u8, close: []const u8) ![]const u8 {
    const start = std.mem.indexOf(u8, haystack, open) orelse
        return fail("generated build.zig.zon has no '{s}'", .{open});
    const from = start + open.len;
    const end = std.mem.indexOfScalarPos(u8, haystack, from, close[0]) orelse
        return fail("generated build.zig.zon has no '{s}' after '{s}'", .{ close, open });
    return haystack[from..end];
}

fn fail(comptime format: []const u8, args: anytype) error{TypedSceneCheckFailed} {
    std.debug.print("typed scene test: " ++ format ++ "\n", args);
    return error.TypedSceneCheckFailed;
}

const std = @import("std");
