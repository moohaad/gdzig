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
        \\    const gdzig_dep = b.dependency("gdzig", .{{ .target = target, .optimize = optimize }});
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
