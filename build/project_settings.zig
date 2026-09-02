//! Reads the small part of `project.godot` needed by build-time helpers.
//!
//! Godot's project file is a sectioned configuration format. Input actions are
//! top-level assignments in `[input]`; their dictionary bodies may span many
//! lines, but only the assignment line contains `=`. Preserve declaration
//! order so the generated enum is stable when unrelated project settings move.

const std = @import("std");

pub fn inputActions(
    allocator: std.mem.Allocator,
    project: []const u8,
) ![]const []const u8 {
    var actions: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (actions.items) |name| allocator.free(name);
        actions.deinit(allocator);
    }
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(allocator);
    var in_input = false;

    var lines = std.mem.splitScalar(u8, project, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == ';') continue;

        if (line[0] == '[') {
            in_input = std.mem.eql(u8, line, "[input]");
            continue;
        }
        if (!in_input) continue;

        const equal = assignmentEqual(line) orelse continue;
        const value = std.mem.trimStart(u8, line[equal + 1 ..], " \t");
        if (value.len == 0 or value[0] != '{') continue;

        const encoded_name = std.mem.trim(u8, line[0..equal], " \t");
        if (encoded_name.len == 0) return error.InvalidInputAction;

        const name = if (encoded_name[0] == '"')
            try std.zig.string_literal.parseAlloc(allocator, encoded_name)
        else
            try allocator.dupe(u8, encoded_name);

        if (name.len == 0 or std.mem.indexOfScalar(u8, name, 0) != null)
            return error.InvalidInputAction;

        const result = try seen.getOrPut(allocator, name);
        if (result.found_existing) {
            allocator.free(name);
            continue;
        }
        actions.append(allocator, name) catch |err| {
            allocator.free(name);
            return err;
        };
    }

    return actions.toOwnedSlice(allocator);
}

pub fn renderActionModule(
    allocator: std.mem.Allocator,
    actions: []const []const u8,
) ![]const u8 {
    var source: std.ArrayList(u8) = .empty;
    errdefer source.deinit(allocator);
    try source.appendSlice(allocator,
        \\/// Input Map actions read from `project.godot` by gdzig's build.
        \\pub const Action = enum {
        \\
    );
    for (actions) |action| {
        try source.print(allocator, "    {f},\n", .{std.zig.fmtId(action)});
    }
    try source.appendSlice(allocator, "};\n");
    return source.toOwnedSlice(allocator);
}

/// Finds the assignment separator without mistaking an `=` inside a quoted
/// action name for it.
fn assignmentEqual(line: []const u8) ?usize {
    var quoted = false;
    var escaped = false;
    for (line, 0..) |byte, i| {
        if (escaped) {
            escaped = false;
            continue;
        }
        if (quoted and byte == '\\') {
            escaped = true;
            continue;
        }
        if (byte == '"') {
            quoted = !quoted;
            continue;
        }
        if (!quoted and byte == '=') return i;
    }
    return null;
}

test "extract input actions and preserve their order" {
    const project =
        \\config_version=5
        \\
        \\[application]
        \\config/name="probe"
        \\
        \\[input]
        \\
        \\move_left={
        \\"deadzone": 0.5,
        \\"events": []
        \\}
        \\"menu accept"={
        \\"deadzone": 0.5,
        \\"events": []
        \\}
        \\
        \\[rendering]
        \\renderer/rendering_method="gl_compatibility"
    ;

    const actions = try inputActions(std.testing.allocator, project);
    defer {
        for (actions) |name| std.testing.allocator.free(name);
        std.testing.allocator.free(actions);
    }

    try std.testing.expectEqual(2, actions.len);
    try std.testing.expectEqualStrings("move_left", actions[0]);
    try std.testing.expectEqualStrings("menu accept", actions[1]);
}

test "ignore assignments outside input and equals inside quoted names" {
    const project =
        \\[application]
        \\config/name="not an action"
        \\[input]
        \\"axis=horizontal"={
        \\"deadzone": 0.5
        \\}
    ;

    const actions = try inputActions(std.testing.allocator, project);
    defer {
        for (actions) |name| std.testing.allocator.free(name);
        std.testing.allocator.free(actions);
    }

    try std.testing.expectEqual(1, actions.len);
    try std.testing.expectEqualStrings("axis=horizontal", actions[0]);
}

test "render actions as ordinary and quoted enum fields" {
    const source = try renderActionModule(std.testing.allocator, &.{ "jump", "menu accept" });
    defer std.testing.allocator.free(source);

    try std.testing.expect(std.mem.indexOf(u8, source, "    jump,") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "    @\"menu accept\",") != null);
}
