//! Extracts explicitly marked Zig fences from Markdown and compiles the text
//! readers actually see. Repeating a marker name concatenates the blocks, so a
//! guide may explain one source file in several pieces without maintaining a
//! hidden, different copy for CI.

const std = @import("std");
const Build = std.Build;
const Step = Build.Step;

pub const Options = struct {
    files: []const []const u8,
    godot_module: *Build.Module,
    target: Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
};

pub fn add(b: *Build, options: Options) !*Step.Run {
    var examples: std.StringArrayHashMapUnmanaged(std.ArrayList(u8)) = .empty;

    for (options.files) |path| {
        const markdown = try b.build_root.handle.readFileAlloc(
            b.graph.io,
            path,
            b.allocator,
            @enumFromInt(8 << 20),
        );
        try collect(b, path, markdown, &examples);
    }

    if (examples.count() == 0) {
        std.log.err("documentation example gate found no `gdzig-doctest` markers", .{});
        return error.NoDocumentationExamples;
    }

    const generated = b.addWriteFiles();
    var root_source: std.ArrayList(u8) = .empty;
    try root_source.appendSlice(b.allocator, "const std = @import(\"std\");\n");

    for (examples.keys(), 0..) |name, i| {
        try root_source.print(
            b.allocator,
            "const example_{d} = @import(\"doc_example_{d}\"); // {s}\n",
            .{ i, i, name },
        );
    }
    try root_source.appendSlice(b.allocator, "\ntest \"documentation examples compile\" {\n");
    for (examples.keys(), 0..) |_, i| {
        try root_source.print(b.allocator, "    std.testing.refAllDecls(example_{d});\n", .{i});
    }
    try root_source.appendSlice(b.allocator, "}\n");

    const root = b.createModule(.{
        .root_source_file = generated.add("doc_examples_root.zig", root_source.items),
        .target = options.target,
        .optimize = options.optimize,
    });

    for (examples.keys(), examples.values(), 0..) |name, source, i| {
        const example_module = b.createModule(.{
            .root_source_file = generated.add(b.fmt("{s}.zig", .{name}), source.items),
            .target = options.target,
            .optimize = options.optimize,
            .imports = &.{.{ .name = "godot", .module = options.godot_module }},
        });
        root.addImport(b.fmt("doc_example_{d}", .{i}), example_module);
    }

    return b.addRunArtifact(b.addTest(.{ .root_module = root }));
}

fn collect(
    b: *Build,
    path: []const u8,
    markdown: []const u8,
    examples: *std.StringArrayHashMapUnmanaged(std.ArrayList(u8)),
) !void {
    const marker = "<!-- gdzig-doctest:";
    var cursor: usize = 0;

    while (std.mem.indexOfPos(u8, markdown, cursor, marker)) |marker_start| {
        const name_start = marker_start + marker.len;
        const marker_end = std.mem.indexOfPos(u8, markdown, name_start, "-->") orelse {
            std.log.err("{s}: unterminated gdzig-doctest marker", .{path});
            return error.InvalidDocumentationExample;
        };
        const name = std.mem.trim(u8, markdown[name_start..marker_end], " \t\r\n");
        if (!std.zig.isValidId(name)) {
            std.log.err("{s}: doctest name '{s}' is not a Zig identifier", .{ path, name });
            return error.InvalidDocumentationExample;
        }

        var fence_start = marker_end + "-->".len;
        while (fence_start < markdown.len and
            (markdown[fence_start] == '\r' or markdown[fence_start] == '\n'))
        {
            fence_start += 1;
        }
        if (!std.mem.startsWith(u8, markdown[fence_start..], "```zig")) {
            std.log.err("{s}: doctest '{s}' is not immediately followed by a Zig fence", .{ path, name });
            return error.InvalidDocumentationExample;
        }
        const content_start = (std.mem.indexOfScalarPos(u8, markdown, fence_start, '\n') orelse {
            std.log.err("{s}: doctest '{s}' has no content", .{ path, name });
            return error.InvalidDocumentationExample;
        }) + 1;
        const content_end = std.mem.indexOfPos(u8, markdown, content_start, "\n```") orelse {
            std.log.err("{s}: doctest '{s}' has no closing fence", .{ path, name });
            return error.InvalidDocumentationExample;
        };

        const owned_name = b.dupe(name);
        const result = try examples.getOrPut(b.allocator, owned_name);
        if (!result.found_existing) result.value_ptr.* = .empty;
        try result.value_ptr.appendSlice(b.allocator, markdown[content_start..content_end]);
        try result.value_ptr.append(b.allocator, '\n');

        cursor = content_end + "\n```".len;
    }
}
