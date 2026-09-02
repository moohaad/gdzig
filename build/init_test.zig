//! Scaffolds a project with `init-gdzig` and builds it.
//!
//! `init-gdzig` is the first thing a newcomer runs, and until now nothing
//! checked that what it produces compiles. It writes interlocking files -- the
//! module has to point at the source it also writes, and the build has to
//! install both the library and its generated descriptor -- and a mistake in
//! any of them surfaces as a build failure in someone else's project.
//!
//! The scaffolder ends by fetching gdzig from GitHub. This replaces that with a
//! path dependency on the working tree, for two reasons: the test then needs no
//! network, and it checks *this* gdzig rather than whatever is published, which
//! is the only version that can be broken by a change under test.
//!
//! Rewriting the manifest is also an assertion. It carries over the name and
//! fingerprint the scaffolder produced, so a fingerprint left at `0x0` -- which
//! is what happens if the `zig init` step it shells out to fails -- stops the
//! nested build with the same error a user would see.

pub fn main(init: std.process.Init) !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = init.io;

    var args = try init.minimal.args.iterateAllocator(arena);
    _ = args.next(); // argv[0]

    const scaffolder = args.next() orelse return fail("expected the init executable's path", .{});
    const out_path = args.next() orelse return fail("expected an output directory", .{});
    const dep_path = args.next() orelse return fail("expected a relative path to gdzig", .{});

    // A previous run's output would make `zig init` refuse, and a stale tree
    // would let a broken scaffolder pass on last time's files.
    std.Io.Dir.cwd().deleteTree(io, out_path) catch {};

    // Invalid names used to be copied directly into Zig syntax and exported
    // symbols, producing a project which only failed later during its build.
    const invalid_out = try std.fmt.allocPrint(arena, "{s}-invalid", .{out_path});
    std.Io.Dir.cwd().deleteTree(io, invalid_out) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, invalid_out) catch {};
    try runFails(io, ".", &.{ scaffolder, "--name", "not-a-zig-id", "--out", invalid_out });
    if (std.Io.Dir.openDir(.cwd(), io, invalid_out, .{})) |created| {
        var created_dir = created;
        created_dir.close(io);
        return fail("invalid project name still created its output directory", .{});
    } else |_| {}

    // A scaffolder must not overwrite an existing project. Leave a sentinel in
    // the target, verify the command refuses it, then verify the sentinel and
    // absence of generated files.
    const occupied_out = try std.fmt.allocPrint(arena, "{s}-occupied", .{out_path});
    std.Io.Dir.cwd().deleteTree(io, occupied_out) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, occupied_out) catch {};
    try std.Io.Dir.createDirPath(.cwd(), io, occupied_out);
    var occupied = try std.Io.Dir.openDir(.cwd(), io, occupied_out, .{});
    try occupied.writeFile(io, .{ .sub_path = "keep.txt", .data = "do not replace" });
    occupied.close(io);
    try runFails(io, ".", &.{ scaffolder, "--name", "gadget", "--out", occupied_out });
    occupied = try std.Io.Dir.openDir(.cwd(), io, occupied_out, .{});
    defer occupied.close(io);
    const sentinel = try occupied.readFileAlloc(io, "keep.txt", arena, @enumFromInt(1024));
    if (!std.mem.eql(u8, sentinel, "do not replace")) return fail("scaffolder changed an existing file", .{});
    if (occupied.statFile(io, "build.zig", .{})) |_| {
        return fail("scaffolder wrote build.zig into a non-empty directory", .{});
    } else |_| {}

    // Deliberately not the basename of the output directory. `zig init` takes
    // the package name from the directory it runs in and binds the fingerprint
    // it generates to that name, so a scaffolder that renames the package
    // afterwards produces a manifest Zig rejects. Naming the probe after its
    // directory hid that for as long as this gate has existed.
    const name = "gadget";

    try run(io, ".", &.{ scaffolder, "--name", name, "--out", out_path });

    var dir = std.Io.Dir.openDir(.cwd(), io, out_path, .{}) catch |err| {
        return fail("'{s}' was not created: {s}", .{ out_path, @errorName(err) });
    };
    defer dir.close(io);

    // Every file the scaffolder promises. Checked by name before building, so a
    // missing one is reported as missing rather than as a compile error.
    for ([_][]const u8{
        "build.zig",
        "build.zig.zon",
        // The quickstart tells the reader to open this in Godot. Without it
        // there is no project to open and the scaffold is unusable, so it is
        // checked like any other file the scaffolder promises.
        "project.godot",
        "main.tscn",
        ".gitignore",
        "src/" ++ name ++ ".zig",
        "src/Game.zig",
    }) |wanted| {
        _ = dir.statFile(io, wanted, .{}) catch |err| {
            return fail("scaffolder did not write '{s}': {s}", .{ wanted, @errorName(err) });
        };
    }

    const entry_source = try dir.readFileAlloc(io, "src/" ++ name ++ ".zig", arena, @enumFromInt(1 << 20));
    if (std.mem.indexOf(u8, entry_source, "r.registerAll(classes)") == null or
        std.mem.indexOf(u8, entry_source, "r.unregisterAll(classes)") == null)
    {
        return fail("generated entry does not symmetrically register the starter class", .{});
    }
    const game_source = try dir.readFileAlloc(io, "src/Game.zig", arena, @enumFromInt(1 << 20));
    if (std.mem.indexOf(u8, game_source, "pub fn _ready") == null) {
        return fail("generated Game class has no _ready callback", .{});
    }
    const project_source = try dir.readFileAlloc(io, "project.godot", arena, @enumFromInt(1 << 20));
    if (std.mem.indexOf(u8, project_source, "run/main_scene=\"res://main.tscn\"") == null) {
        return fail("generated Godot project does not select the starter scene", .{});
    }
    const build_source = try dir.readFileAlloc(io, "build.zig", arena, @enumFromInt(1 << 20));
    if (std.mem.indexOf(u8, build_source, "extension.manifest") == null) {
        return fail("generated build does not install addExtension's manifest", .{});
    }

    const manifest = dir.readFileAlloc(io, "build.zig.zon", arena, @enumFromInt(1 << 20)) catch |err| {
        return fail("cannot read the generated build.zig.zon: {s}", .{@errorName(err)});
    };

    const fingerprint = try between(manifest, ".fingerprint = ", ",");
    if (std.mem.eql(u8, fingerprint, "0x0")) {
        return fail("fingerprint is still 0x0, so `zig init` did not run; the nested build cannot succeed", .{});
    }

    // Rewritten rather than patched: `zig fetch --save` may or may not have
    // reached GitHub, so the dependency block is not known in advance.
    const rewritten = try std.fmt.allocPrint(arena,
        \\.{{
        \\    .name = .{s},
        \\    .version = "0.0.0",
        \\    .fingerprint = {s},
        \\    .minimum_zig_version = "0.16.0",
        \\    .dependencies = .{{
        \\        .gdzig = .{{ .path = "{s}" }},
        \\    }},
        \\    .paths = .{{ "build.zig", "build.zig.zon", "src" }},
        \\}}
        \\
    , .{ name, fingerprint, dep_path });
    try dir.writeFile(io, .{ .sub_path = "build.zig.zon", .data = rewritten });

    // Godot writes this during its import pass, and `addExtension` warns when
    // it is missing -- correctly, since a project without it loads no extension
    // at all. Nothing here ever opens Godot, so that warning is noise on every
    // run of a passing gate, and a warning nobody reads is worse than none.
    // Writing it also walks the branch where the file exists and names the
    // extension, which no other test reaches.
    try dir.createDirPath(io, ".godot");
    try dir.writeFile(io, .{ .sub_path = ".godot/extension_list.cfg", .data = "res://" ++ name ++ ".gdextension\n" });

    // A second extension from the same build.zig. `addExtension` declares the
    // `log-registration` option, and `b.option` panics when a name is declared
    // twice, so a second call used to bring the configure phase down. That was
    // invisible for as long as every build.zig in the tree built exactly one
    // library. Nothing is installed from it -- surviving configure is the whole
    // assertion.
    {
        const build_zig = try dir.readFileAlloc(io, "build.zig", arena, @enumFromInt(1 << 20));
        const close = std.mem.lastIndexOfScalar(u8, build_zig, '}') orelse
            return fail("generated build.zig has no closing brace", .{});
        try dir.writeFile(io, .{ .sub_path = "build.zig", .data = try std.fmt.allocPrint(arena,
            \\{s}    _ = gdzig.addExtension(b, .{{
            \\        .name = "{s}2",
            \\        .root_module = mod,
            \\        .entry_symbol = "{s}_init2",
            \\        .target = target,
            \\        .optimize = optimize,
            \\    }});
            \\{s}
        , .{ build_zig[0..close], name, name, build_zig[close..] }) });
    }
    try run(io, out_path, &.{ "zig", "build" });

    const descriptor_name = name ++ ".gdextension";
    const descriptor = dir.readFileAlloc(io, descriptor_name, arena, @enumFromInt(1 << 20)) catch |err| {
        return fail("build did not install generated '{s}': {s}", .{ descriptor_name, @errorName(err) });
    };
    if (std.mem.indexOf(u8, descriptor, "entry_symbol = \"" ++ name ++ "_init\"") == null) {
        return fail("generated descriptor does not use addExtension's entry symbol", .{});
    }
    if (std.mem.indexOf(u8, descriptor, ".debug.") == null or
        std.mem.indexOf(u8, descriptor, ".release.") == null)
    {
        return fail("generated descriptor does not cover both Godot build modes", .{});
    }
    if (std.mem.indexOf(u8, descriptor, "= \"lib/") == null) {
        return fail("generated descriptor does not point at the installed lib/ directory", .{});
    }

    // The point of the whole exercise: a library where the generated
    // `.gdextension` says one will be.
    var lib = dir.openDir(io, "lib", .{ .iterate = true }) catch |err| {
        return fail("no lib/ directory after building the scaffolded project: {s}", .{@errorName(err)});
    };
    defer lib.close(io);

    var found = false;
    var iter = lib.iterate();
    while (iter.next(io) catch null) |entry| {
        if (entry.kind == .file and std.mem.indexOf(u8, entry.name, name) != null) found = true;
    }
    if (!found) return fail("built, but produced no library named for '{s}' in lib/", .{name});

    // The scaffolder produces the flat layout, so `zig-pkg/` lands inside the
    // Godot project and the editor would walk every fetched dependency --
    // including gdzig's own checkout, whose example/project has a project.godot
    // of its own. `.gdignore` is what stops that, and nothing but this checks
    // that the build writes it.
    _ = dir.statFile(io, "zig-pkg/.gdignore", .{}) catch |err| {
        return fail("no zig-pkg/.gdignore after building a flat-layout project: {s}", .{@errorName(err)});
    };
    std.debug.print("init-gdzig: scaffolded '{s}' and built it\n", .{name});
}

fn run(io: std.Io, cwd_path: []const u8, argv: []const []const u8) !void {
    var cwd_dir = try std.Io.Dir.openDir(.cwd(), io, cwd_path, .{});
    defer cwd_dir.close(io);

    var child = try std.process.spawn(io, .{ .argv = argv, .cwd = .{ .dir = cwd_dir } });
    const term = try child.wait(io);
    if (term != .exited or term.exited != 0) {
        return fail("'{s}' failed in {s}", .{ argv[0], cwd_path });
    }
}

fn runFails(io: std.Io, cwd_path: []const u8, argv: []const []const u8) !void {
    var cwd_dir = try std.Io.Dir.openDir(.cwd(), io, cwd_path, .{});
    defer cwd_dir.close(io);

    var child = try std.process.spawn(io, .{ .argv = argv, .cwd = .{ .dir = cwd_dir } });
    const term = try child.wait(io);
    if (term == .exited and term.exited == 0) {
        return fail("'{s}' unexpectedly succeeded in {s}", .{ argv[0], cwd_path });
    }
}

/// The text between two markers, or an error naming the one that was missing.
fn between(haystack: []const u8, open: []const u8, close: []const u8) ![]const u8 {
    const start = std.mem.indexOf(u8, haystack, open) orelse
        return fail("generated build.zig.zon has no '{s}'", .{open});
    const from = start + open.len;
    const end = std.mem.indexOfScalarPos(u8, haystack, from, close[0]) orelse
        return fail("generated build.zig.zon has no '{s}' after '{s}'", .{ close, open });
    return haystack[from..end];
}

fn fail(comptime fmt: []const u8, args: anytype) error{InitScaffoldFailed} {
    std.debug.print("init-gdzig test: " ++ fmt ++ "\n", args);
    return error.InitScaffoldFailed;
}

const std = @import("std");
