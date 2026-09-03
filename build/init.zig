const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.page_allocator;

    var args_iter = try init.minimal.args.iterateAllocator(allocator);
    var args_iter_deinit = args_iter;
    defer args_iter_deinit.deinit();

    var project_name: []const u8 = "mygame";
    var out_path: ?[]const u8 = null;

    // Skip the first arg (executable name)
    _ = args_iter.next();

    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--name") or std.mem.eql(u8, arg, "-n")) {
            if (args_iter.next()) |val| {
                project_name = val;
            } else {
                std.debug.print("Error: expected value for {s}\n\n", .{arg});
                usage();
                std.process.exit(2);
            }
        } else if (std.mem.eql(u8, arg, "--out") or std.mem.eql(u8, arg, "-o")) {
            if (args_iter.next()) |val| {
                out_path = val;
            } else {
                std.debug.print("Error: expected value for {s}\n\n", .{arg});
                usage();
                std.process.exit(2);
            }
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            usage();
            return;
        } else {
            std.debug.print("Error: unrecognised argument '{s}'\n\n", .{arg});
            usage();
            std.process.exit(2);
        }
    }

    // Required, with no fallback. It used to default to the project name, so
    // `zig build init-gdzig` with nothing after it wrote a `mygame/` into
    // whatever directory the caller happened to be standing in -- for anyone
    // running the step to see what it does, that is this repository. A
    // scaffolder should write where it is told and nowhere else.
    const actual_out_path = out_path orelse {
        std.debug.print("Error: --out is required\n\n", .{});
        usage();
        std.process.exit(2);
    };

    // The name is emitted as a Zig enum literal, source filename, library
    // name, and exported entry symbol. Accept exactly the names that are valid
    // unquoted Zig identifiers so every one of those spellings agrees.
    if (!std.zig.isValidId(project_name)) {
        std.debug.print(
            "Error: project name '{s}' is not a valid Zig identifier; use letters, digits, and underscores, and do not start with a digit\n",
            .{project_name},
        );
        std.process.exit(2);
    }

    std.Io.Dir.createDirPath(.cwd(), init.io, actual_out_path) catch |err| {
        std.debug.print("Failed to create output directory {s}: {}\n", .{ actual_out_path, err });
        return err;
    };

    // Refuse to merge a scaffold into an existing tree. Several generated
    // filenames are conventional (`build.zig`, `project.godot`, `.gitignore`),
    // so overwriting just those files can silently damage an unrelated project.
    {
        var output_dir = try std.Io.Dir.openDir(.cwd(), init.io, actual_out_path, .{ .iterate = true });
        defer output_dir.close(init.io);
        var entries = output_dir.iterate();
        if (try entries.next(init.io) != null) {
            std.debug.print("Error: output directory '{s}' is not empty\n", .{actual_out_path});
            std.process.exit(2);
        }
    }

    // `zig init` has no `--name`: it takes the package name from the directory
    // it runs in, and the fingerprint it writes is bound to that name. Running
    // it directly in the output directory and then rewriting `.name` to
    // `--name` produced a manifest Zig rejects whenever the two differed --
    // `zig fetch --save` refused it, the project was written without its gdzig
    // dependency, and the run still reported success.
    //
    // So it runs one level down, in a throwaway directory that *is* the project
    // name. The fingerprint then comes back bound to the name about to be
    // written, and nothing else here needs the rest of what `zig init` makes.
    const seed_root = try std.fs.path.join(allocator, &.{ actual_out_path, ".gdzig-init" });
    defer allocator.free(seed_root);
    const seed_path = try std.fs.path.join(allocator, &.{ seed_root, project_name });
    defer allocator.free(seed_path);

    std.Io.Dir.cwd().deleteTree(init.io, seed_root) catch {};
    try std.Io.Dir.createDirPath(.cwd(), init.io, seed_path);
    defer std.Io.Dir.cwd().deleteTree(init.io, seed_root) catch {};

    _ = runCmd(init.io, seed_path, &.{ "zig", "init" }) catch |err| {
        std.debug.print("Failed to run zig init: {}\n", .{err});
        return err;
    };

    var dir = try std.Io.Dir.openDir(.cwd(), init.io, actual_out_path, .{});
    defer dir.close(init.io);

    // `zig init` used to make this on the way past.
    try dir.createDirPath(init.io, "src");

    // 2. Extract fingerprint from the seed's build.zig.zon
    var seed_dir = try std.Io.Dir.openDir(.cwd(), init.io, seed_path, .{});
    defer seed_dir.close(init.io);

    var fingerprint: []const u8 = "0x0";
    if (seed_dir.readFileAlloc(init.io, "build.zig.zon", allocator, @as(std.Io.Limit, @enumFromInt(1024 * 1024)))) |zon_content| {
        defer allocator.free(zon_content);
        if (std.mem.indexOf(u8, zon_content, ".fingerprint = ")) |idx| {
            const start = idx + 15;
            if (std.mem.indexOfScalarPos(u8, zon_content, start, ',')) |end| {
                fingerprint = try allocator.dupe(u8, zon_content[start..end]);
            }
        }
    } else |_| {}

    // 3. Write our own build.zig.zon (without dependencies, we'll fetch gdzig later)
    const build_zon = try std.fmt.allocPrint(allocator,
        \\.{{
        \\    .name = .{s},
        \\    .version = "0.0.0",
        \\    .fingerprint = {s},
        \\    .minimum_zig_version = "0.16.0",
        \\    .dependencies = .{{
        \\    }},
        \\    .paths = .{{ "build.zig", "build.zig.zon", "src" }},
        \\}}
        \\
    , .{ project_name, fingerprint });
    defer allocator.free(build_zon);
    try dir.writeFile(init.io, .{ .sub_path = "build.zig.zon", .data = build_zon });

    const build_zig = try std.fmt.allocPrint(allocator,
        \\const std = @import("std");
        \\const Build = std.Build;
        \\const gdzig = @import("gdzig");
        \\
        \\pub fn build(b: *Build) !void {{
        \\    const target = b.standardTargetOptions(.{{}});
        \\    const optimize = b.standardOptimizeOption(.{{}});
        \\    const godot_version = b.option([]const u8, "godot-version", "Godot version to download");
        \\    const godot_path = b.option([]const u8, "godot-path", "Path to a Godot executable");
        \\    const godot_classes = b.option([]const u8, "godot-classes", "Comma-separated Godot classes to generate");
        \\
        \\    const gdzig_dep = b.dependency("gdzig", .{{
        \\        .target = target,
        \\        .optimize = optimize,
        \\        .@"godot-version" = godot_version,
        \\        .@"godot-path" = godot_path,
        \\        .classes = godot_classes,
        \\        // Needed here as well as on `addExtension`, and not the same option:
        \\        // this one bakes the project's resource and Input Map names into the
        \\        // gdzig module. That lets `godot.res` reject a missing path and
        \\        // generates `godot.input.Action`. Absolute, because gdzig resolves it
        \\        // against its own build root rather than yours.
        \\        .godot_project = b.pathFromRoot("."),
        \\    }});
        \\
        \\    const mod = b.createModule(.{{
        \\        .root_source_file = b.path("src/{s}.zig"),
        \\        .target = target,
        \\        .optimize = optimize,
        \\        .imports = &.{{.{{ .name = "godot", .module = gdzig_dep.module("gdzig") }}}},
        \\    }});
        \\
        \\    const extension = gdzig.addExtension(b, .{{
        \\        .name = "{s}",
        \\        .root_module = mod,
        \\        .entry_symbol = "{s}_init",
        \\        .target = target,
        \\        .optimize = optimize,
        \\        .godot_project = ".",
        \\    }}) orelse return;
        \\
        \\    const install_library = b.addInstallFileWithDir(extension.output, .{{ .custom = "../lib" }}, extension.filename);
        \\    const install_manifest = b.addInstallFileWithDir(extension.manifest, .{{ .custom = ".." }}, extension.manifest_filename);
        \\    b.default_step.dependOn(&install_library.step);
        \\    b.default_step.dependOn(&install_manifest.step);
        \\
        \\    const watch_step = b.step("watch", "Watch for changes, clean stale artifacts, and rebuild");
        \\    const watch = gdzig.addWatchStep(b, .{{}});
        \\    watch.addArg("--run");
        \\    watch.addArg("godot"); // Assuming godot is in PATH
        \\    watch.addArgs(&.{{ "--path", "." }});
        \\    watch_step.dependOn(&watch.step);
        \\}}
        \\
    , .{ project_name, project_name, project_name });
    defer allocator.free(build_zig);
    try dir.writeFile(init.io, .{ .sub_path = "build.zig", .data = build_zig });

    // Without this there is no Godot project to open. Godot reads
    // `.godot/extension_list.cfg`, which only an import pass writes, and only a
    // real project can be imported. The scaffold is not usable without it.
    const project_godot = try std.fmt.allocPrint(allocator,
        \\; Written by `zig build init-gdzig`. Godot rewrites this file itself once
        \\; the project has been opened in the editor.
        \\
        \\config_version=5
        \\
        \\[application]
        \\
        \\config/name="{s}"
        \\config/features=PackedStringArray("4.7")
        \\run/main_scene="res://main.tscn"
        \\
    , .{project_name});
    defer allocator.free(project_godot);
    try dir.writeFile(init.io, .{ .sub_path = "project.godot", .data = project_godot });

    const entry_src =
        \\const godot = @import("godot");
        \\const Game = @import("Game.zig");
        \\
        \\const classes = .{Game};
        \\
        \\pub fn register(r: *godot.extension.Registry) void {
        \\    r.registerAll(classes);
        \\}
        \\
        \\pub fn unregister(r: *godot.extension.Registry) void {
        \\    r.unregisterAll(classes);
        \\}
        \\
    ;
    const src_filename = try std.fmt.allocPrint(allocator, "src/{s}.zig", .{project_name});
    defer allocator.free(src_filename);
    try dir.writeFile(init.io, .{ .sub_path = src_filename, .data = entry_src });

    // A scaffold should demonstrate the complete path from Zig type to a node
    // Godot can instantiate. Keep this deliberately small: it is useful on its
    // own and gives a newcomer an obvious place to add the first callback.
    const game_src =
        \\const std = @import("std");
        \\const godot = @import("godot");
        \\
        \\const Game = @This();
        \\
        \\allocator: std.mem.Allocator,
        \\base: *godot.class.Node,
        \\
        \\pub fn _ready(_: *Game) void {
        \\    godot.print("Hello from gdzig!", .{});
        \\}
        \\
    ;
    try dir.writeFile(init.io, .{ .sub_path = "src/Game.zig", .data = game_src });

    const main_scene =
        \\[gd_scene format=3]
        \\
        \\[node name="Game" type="Game"]
        \\
    ;
    try dir.writeFile(init.io, .{ .sub_path = "main.tscn", .data = main_scene });

    const gitignore =
        \\/.godot/
        \\/.zig-cache/
        \\/*.gdextension
        \\/lib/
        \\/zig-out/
        \\/zig-pkg/
        \\
    ;
    try dir.writeFile(init.io, .{ .sub_path = ".gitignore", .data = gitignore });

    // Reaching GitHub is the one step here that depends on something outside
    // this machine, and a blip in it leaves a manifest with no gdzig
    // dependency -- so the first `zig build` fails on the import, which looks
    // nothing like a network problem. Reporting success anyway is how someone
    // spends an evening on their own source. The run still exits 0: everything
    // that could be written was, and the remaining step is one command.
    const fetch_url = "git+https://github.com/moohaad/gdzig.git";
    var fetched = true;
    runCmd(init.io, actual_out_path, &.{ "zig", "fetch", "--save=gdzig", fetch_url }) catch {
        fetched = false;
    };

    if (fetched) {
        std.debug.print("Successfully scaffolded gdzig project '{s}' in {s}/\n", .{ project_name, actual_out_path });
    } else {
        std.debug.print(
            \\Scaffolded '{s}' in {s}/, but `zig fetch` did not succeed, so
            \\build.zig.zon has no gdzig dependency yet and `zig build` will fail on
            \\the import. Every file is written; run the fetch below first.
            \\
        , .{ project_name, actual_out_path });
    }

    // Without a build there is no library for the `.gdextension` to
    // point at; without an import pass Godot has no `.godot/extension_list.cfg`
    // to read and so loads no extension at all -- silently, every class simply
    // absent. Both are one command, and a reader who is told them here never
    // meets either failure.
    std.debug.print(
        \\
        \\Next:
        \\  cd {s}
        \\
    , .{actual_out_path});

    if (!fetched) std.debug.print("  zig fetch --save=gdzig {s}\n", .{fetch_url});

    std.debug.print(
        \\  zig build                             # compile the extension into lib/
        \\  godot --path . --headless --import    # once; without this Godot loads nothing
        \\  godot --path .                        # run the starter scene
        \\
        \\The import step is not optional and skipping it fails quietly: Godot reads
        \\.godot/extension_list.cfg to decide what to load, an unimported project has no
        \\such file, and your classes are then missing with nothing logged anywhere.
        \\Opening project.godot in the editor once does the same job.
        \\
    , .{});
}

/// What to pass, and why `--out` has no default.
fn usage() void {
    std.debug.print(
        \\Usage: init-gdzig --out <dir> [--name <project>]
        \\
        \\  -o, --out  <dir>      empty directory to create or populate
        \\  -n, --name <project>  Zig identifier used as the package name (default: mygame)
        \\  -h, --help            print this and exit
        \\
        \\The generated project includes a registered Game node and starter scene.
        \\Build it, then import it once so Godot will load the extension.
        \\
    , .{});
}
fn runCmd(io: std.Io, cwd_path: []const u8, argv: []const []const u8) !void {
    var cwd_dir = try std.Io.Dir.openDir(.cwd(), io, cwd_path, .{});
    defer cwd_dir.close(io);

    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .dir = cwd_dir },
    });
    const term = try child.wait(io);
    if (term != .exited or term.exited != 0) {
        return error.CommandFailed;
    }
}
