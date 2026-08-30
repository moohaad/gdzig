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
                std.debug.print("Error: expected value for {s}\n", .{arg});
                return error.InvalidArgs;
            }
        } else if (std.mem.eql(u8, arg, "--out") or std.mem.eql(u8, arg, "-o")) {
            if (args_iter.next()) |val| {
                out_path = val;
            } else {
                std.debug.print("Error: expected value for {s}\n", .{arg});
                return error.InvalidArgs;
            }
        }
    }

    const actual_out_path = out_path orelse project_name;

    std.Io.Dir.createDirPath(.cwd(), init.io, actual_out_path) catch |err| {
        std.debug.print("Failed to create output directory {s}: {}\n", .{ actual_out_path, err });
        return err;
    };
    
    _ = runCmd(init.io, actual_out_path, &.{ "zig", "init" }) catch |err| {
        std.debug.print("Failed to run zig init: {}\n", .{err});
        return err;
    };

    var dir = try std.Io.Dir.openDir(.cwd(), init.io, actual_out_path, .{});
    defer dir.close(init.io);

    // 2. Extract fingerprint from generated build.zig.zon
    var fingerprint: []const u8 = "0x0";
    if (dir.readFileAlloc(init.io, "build.zig.zon", allocator, @as(std.Io.Limit, @enumFromInt(1024 * 1024)))) |zon_content| {
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
        \\
        \\    const gdzig_dep = b.dependency("gdzig", .{{
        \\        .target = target,
        \\        .optimize = optimize,
        \\        // Needed here as well as on `addExtension`, and not the same option:
        \\        // this one bakes the project's resource list into the gdzig module,
        \\        // which is what lets `godot.res` reject a `res://` path the project
        \\        // does not have. Absolute, because gdzig resolves it against its own
        \\        // build root rather than yours.
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
        \\    const install = b.addInstallFileWithDir(extension.output, .{{ .custom = "../lib" }}, extension.filename);
        \\    b.default_step.dependOn(&install.step);
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

    // 4. Delete src/main.zig and src/root.zig from `zig init`, and write our extension entry
    dir.deleteFile(init.io, "src/main.zig") catch {};
    dir.deleteFile(init.io, "src/root.zig") catch {};


    const extension = try std.fmt.allocPrint(allocator,
        \\[configuration]
        \\
        \\entry_symbol = "{s}_init"
        \\compatibility_minimum = "4.7"
        \\reloadable = true
        \\
        \\[libraries]
        \\
        \\windows.debug.x86_64 = "lib/{s}.dll"
        \\windows.release.x86_64 = "lib/{s}.dll"
        \\linux.debug.x86_64 = "lib/lib{s}.so"
        \\linux.release.x86_64 = "lib/lib{s}.so"
        \\macos.debug = "lib/lib{s}.dylib"
        \\macos.release = "lib/lib{s}.dylib"
        \\
    , .{ project_name, project_name, project_name, project_name, project_name, project_name, project_name });
    defer allocator.free(extension);
    const ext_filename = try std.fmt.allocPrint(allocator, "{s}.gdextension", .{project_name});
    defer allocator.free(ext_filename);
    try dir.writeFile(init.io, .{ .sub_path = ext_filename, .data = extension });

    // Without this there is no Godot project to open, and the `.gdextension`
    // beside it has nothing to be found by: Godot reads
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
        \\
    , .{project_name});
    defer allocator.free(project_godot);
    try dir.writeFile(init.io, .{ .sub_path = "project.godot", .data = project_godot });

    const entry_src = try std.fmt.allocPrint(allocator,
        \\const godot = @import("godot");
        \\
        \\pub fn register(r: *godot.extension.Registry) void {{
        \\    _ = r; // Register classes here
        \\}}
        \\
        \\pub fn unregister(r: *godot.extension.Registry) void {{
        \\    _ = r;
        \\}}
        \\
    , .{});
    defer allocator.free(entry_src);
    const src_filename = try std.fmt.allocPrint(allocator, "src/{s}.zig", .{project_name});
    defer allocator.free(src_filename);
    try dir.writeFile(init.io, .{ .sub_path = src_filename, .data = entry_src });

    _ = runCmd(init.io, actual_out_path, &.{ "zig", "fetch", "--save=gdzig", "git+https://github.com/moohaad/gdzig.git" }) catch |err| {
        std.debug.print("Failed to run zig fetch (gdzig won't be added to dependencies): {}\n", .{err});
    };

    std.debug.print("Successfully scaffolded gdzig project '{s}' in {s}/\n", .{ project_name, actual_out_path });

    // What is scaffolded does not run yet, and neither missing piece announces
    // itself. Without a build there is no library for the `.gdextension` to
    // point at; without an import pass Godot has no `.godot/extension_list.cfg`
    // to read and so loads no extension at all -- silently, every class simply
    // absent. Both are one command, and a reader who is told them here never
    // meets either failure.
    std.debug.print(
        \\
        \\Next:
        \\  cd {s}
        \\  zig build                             # compile the extension into lib/
        \\  godot --path . --headless --import    # once; without this Godot loads nothing
        \\  godot --path .                        # run it
        \\
        \\The import step is not optional and skipping it fails quietly: Godot reads
        \\.godot/extension_list.cfg to decide what to load, an unimported project has no
        \\such file, and your classes are then missing with nothing logged anywhere.
        \\Opening project.godot in the editor once does the same job.
        \\
    , .{actual_out_path});
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
