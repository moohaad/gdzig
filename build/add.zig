const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;
    var args = try init.minimal.args.iterateAllocator(a);
    _ = args.next();
    _ = args.next();
    const kind = args.next() orelse return usage();
    if (std.mem.eql(u8, kind, "--help")) return usage();
    const plugin = std.mem.eql(u8, kind, "plugin");
    const resource = std.mem.eql(u8, kind, "resource");
    if (!plugin and !resource and !std.mem.eql(u8, kind, "node")) return error.UnknownTemplate;
    const name = args.next() orelse return error.MissingName;
    if (!std.zig.isValidId(name)) return error.InvalidClassName;
    for ([_][]const u8{ "std", "godot", "allocator", "base", "register", "unregister", "_ready", "_physics_process", "_enter_tree", "_exit_tree" }) |reserved| {
        if (std.mem.eql(u8, name, reserved)) return error.ReservedClassName;
    }
    var base: []const u8 = if (plugin) "EditorPlugin" else if (resource) "Resource" else "Node";
    var entry_path: ?[]const u8 = null;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--base")) {
            base = args.next() orelse return error.MissingBase;
        } else if (std.mem.eql(u8, arg, "--entry")) {
            entry_path = args.next() orelse return error.MissingEntry;
        } else return error.UnknownArgument;
    }
    const zig_base = baseName(kind, base) orelse {
        std.debug.print("Unsupported {s} base '{s}'; see gdzig add --help\n", .{ kind, base });
        return error.UnsupportedBase;
    };
    const cwd = std.Io.Dir.cwd();
    if (entry_path == null) {
        var src = try cwd.openDir(io, "src", .{ .iterate = true });
        defer src.close(io);
        var iter = src.iterate();
        while (try iter.next(io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".zig")) continue;
            const body = try src.readFileAlloc(io, entry.name, a, .limited(1 << 20));
            if (tupleEnd(body) == null) continue;
            if (entry_path != null) return error.AmbiguousEntryUseEntryOption;
            entry_path = try std.fs.path.join(a, &.{ "src", entry.name });
        }
    }
    const path = entry_path orelse {
        std.debug.print("No scaffold registration tuple found. Use --entry <file> with a top-level `const classes = .{{...}};` shared by registerAll and unregisterAll.\n", .{});
        return error.EntryNotFound;
    };
    const original = try cwd.readFileAlloc(io, path, a, .limited(1 << 20));
    if (std.mem.indexOf(u8, original, "r.registerAll(classes)") == null or
        std.mem.indexOf(u8, original, "r.unregisterAll(classes)") == null)
    {
        std.debug.print("Entry must use the scaffold's r.registerAll(classes) and r.unregisterAll(classes) calls.\n", .{});
        return error.UnsupportedRegistrationLayout;
    }
    const end = tupleEnd(original) orelse return error.UnsupportedRegistrationLayout;
    const filename = try std.fmt.allocPrint(a, "{s}.zig", .{name});
    const output_path = try std.fs.path.join(a, &.{ std.fs.path.dirname(path) orelse ".", filename });
    const insertion = try std.fmt.allocPrint(a, "{s}\n    @import(\"{s}\"),\n", .{ if (end.needs_comma) "," else "", filename });
    const edited = try std.mem.concat(a, u8, &.{ original[0..end.offset], insertion, original[end.offset..] });
    var tree = try std.zig.Ast.parse(a, try a.dupeZ(u8, edited), .zig);
    defer tree.deinit(a);
    if (tree.errors.len != 0) return error.InvalidEntrySyntax;
    var formatted: std.Io.Writer.Allocating = .init(a);
    defer formatted.deinit();
    try tree.render(a, &formatted.writer, .{});
    const updated = formatted.written();
    const source = try render(a, name, zig_base, plugin, resource);
    // Prepare the replacement before touching either user file. Exclusive
    // creation prevents replacing an existing class or another pending edit.
    const temporary = try std.fmt.allocPrint(a, "{s}.gdzig-add.tmp", .{path});
    const temp = try cwd.createFile(io, temporary, .{ .exclusive = true });
    defer cwd.deleteFile(io, temporary) catch {};
    {
        defer temp.close(io);
        try temp.writeStreamingAll(io, updated);
    }
    const output = try cwd.createFile(io, output_path, .{ .exclusive = true });
    errdefer cwd.deleteFile(io, output_path) catch {};
    {
        defer output.close(io);
        try output.writeStreamingAll(io, source);
    }
    const current = try cwd.readFileAlloc(io, path, a, .limited(1 << 20));
    if (!std.mem.eql(u8, original, current)) return error.EntryChangedDuringGeneration;
    try cwd.rename(temporary, cwd, path, io);
    std.debug.print("Created {s} and added it to {s}'s classes tuple.\n", .{ output_path, path });
}

fn baseName(kind: []const u8, base: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, kind, "resource")) return if (std.mem.eql(u8, base, "Resource")) "Resource" else null;
    if (std.mem.eql(u8, kind, "plugin")) return if (std.mem.eql(u8, base, "EditorPlugin")) "EditorPlugin" else null;
    const godot = [_][]const u8{ "Node", "Node2D", "Node3D", "CharacterBody2D", "CharacterBody3D", "Control", "Area2D", "Area3D", "RigidBody2D", "RigidBody3D" };
    const zig = [_][]const u8{ "Node", "Node2d", "Node3d", "CharacterBody2d", "CharacterBody3d", "Control", "Area2d", "Area3d", "RigidBody2d", "RigidBody3d" };
    for (godot, zig) |g, z| if (std.mem.eql(u8, base, g) or std.mem.eql(u8, base, z)) return z;
    return null;
}

const End = struct { offset: usize, needs_comma: bool };

// Tokenization keeps braces in comments and strings out of the edit decision.
// Accept only the scaffold's top-level literal tuple; never rewrite arbitrary
// registration logic or evaluate a build file.
fn tupleEnd(body: []const u8) ?End {
    const a = std.heap.page_allocator;
    const terminated = a.dupeZ(u8, body) catch return null;
    defer a.free(terminated);
    var tokens = std.zig.Tokenizer.init(terminated);
    var depth: usize = 0;
    while (true) {
        const token = tokens.next();
        if (token.tag == .eof) return null;
        if (token.tag == .l_brace) depth += 1;
        if (token.tag == .r_brace and depth > 0) depth -= 1;
        if (depth != 0 or token.tag != .keyword_const) continue;
        const identifier = tokens.next();
        if (identifier.tag != .identifier or !std.mem.eql(u8, body[identifier.loc.start..identifier.loc.end], "classes")) continue;
        if (tokens.next().tag != .equal or tokens.next().tag != .period or tokens.next().tag != .l_brace) return null;
        var nesting: usize = 1;
        var previous: std.zig.Token.Tag = .l_brace;
        while (true) {
            const item = tokens.next();
            if (item.tag == .eof) return null;
            if (item.tag == .l_brace) nesting += 1;
            if (item.tag == .r_brace) nesting -= 1;
            if (nesting == 0) {
                if (tokens.next().tag != .semicolon) return null;
                return .{ .offset = item.loc.start, .needs_comma = previous != .comma and previous != .l_brace };
            }
            previous = item.tag;
        }
    }
}

fn render(a: std.mem.Allocator, name: []const u8, base: []const u8, plugin: bool, resource: bool) ![]const u8 {
    const header = try std.fmt.allocPrint(a,
        \\const std = @import("std");
        \\const godot = @import("godot");
        \\const {s} = @This();
        \\
        \\allocator: std.mem.Allocator,
        \\base: *godot.class.{s},
        \\
    , .{ name, base });
    const hooks = if (plugin) try std.fmt.allocPrint(a,
        \\
        \\pub fn register(r: *godot.extension.Registry) void {{
        \\    r.addEditorPlugin({s}, r.allocator, .auto);
        \\}}
        \\pub fn unregister(r: *godot.extension.Registry) void {{
        \\    r.removeClass({s});
        \\}}
        \\pub fn _enter_tree(_: *{s}) void {{}}
        \\pub fn _exit_tree(_: *{s}) void {{}}
        \\
    , .{ name, name, name, name }) else if (resource) "" else try std.fmt.allocPrint(a,
        \\
        \\pub fn _ready(_: *{s}) void {{}}
        \\pub fn _physics_process(_: *{s}, delta: f64) void {{
        \\    _ = delta;
        \\}}
        \\
    , .{ name, name });
    return std.mem.concat(a, u8, &.{ header, hooks });
}

fn usage() void {
    std.debug.print(
        \\Usage: gdzig add <node|resource|plugin> <Name> [--base <GodotClass>] [--entry <file>]
        \\Run beside build.zig. Finds the classes tuple in src/, or use --entry.
        \\Creates the class beside that entry file and appends an inline import.
        \\Node bases: Node, Node2D/3D, CharacterBody2D/3D, Control, Area2D/3D,
        \\RigidBody2D/3D. Resource and plugin use Resource and EditorPlugin.
        \\Existing files are never overwritten. Custom registration layouts are refused.
        \\
    , .{});
}

test "tuple insertion ignores comments and nested literals" {
    const body = "// const classes = .{};\nconst classes = .{ @import(\"A.zig\"), };";
    const end = tupleEnd(body).?;
    try std.testing.expectEqual(@as(u8, '}'), body[end.offset]);
    try std.testing.expect(!end.needs_comma);
    try std.testing.expect(tupleEnd("const classes = makeClasses();") == null);
    try std.testing.expect(tupleEnd("const classes = .{Game};").?.needs_comma);
}
