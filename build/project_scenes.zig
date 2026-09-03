//! Generates the scene source catalog consumed by `gdzig.Scene`.
//!
//! `@embedFile` gives the scene parser the file being declared, but an
//! instanced or inherited scene names another `res://` file. The dependency
//! build already walks the whole Godot project, so keep those sources in one
//! generated module rather than asking application code to embed every edge in
//! the scene graph by hand.

const std = @import("std");

pub const Source = struct {
    path: []const u8,
    contents: []const u8,
};

pub fn renderModule(allocator: std.mem.Allocator, scenes: []const Source) ![]const u8 {
    var source: std.ArrayList(u8) = .empty;
    errdefer source.deinit(allocator);

    try source.appendSlice(allocator,
        \\/// A text scene read from the configured Godot project.
        \\pub const SceneFile = struct {
        \\    path: []const u8,
        \\    contents: []const u8,
        \\};
        \\
        \\/// All source `.tscn` files, keyed by their `res://` path.
        \\pub const files = [_]SceneFile{
        \\
    );

    for (scenes) |scene| {
        try source.print(
            allocator,
            "    .{{ .path = \"{f}\", .contents = \"{f}\" }},\n",
            .{ std.zig.fmtString(scene.path), std.zig.fmtString(scene.contents) },
        );
    }
    try source.appendSlice(allocator, "};\n");
    return source.toOwnedSlice(allocator);
}

test "renders paths and arbitrary scene text as Zig strings" {
    const rendered = try renderModule(std.testing.allocator, &.{.{
        .path = "res://levels/quoted scene.tscn",
        .contents = "[node name=\"Root\" type=\"Node\"]\r\n",
    }});
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(
        u8,
        rendered,
        ".path = \"res://levels/quoted scene.tscn\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        rendered,
        ".contents = \"[node name=\\\"Root\\\" type=\\\"Node\\\"]\\r\\n\"",
    ) != null);
}
