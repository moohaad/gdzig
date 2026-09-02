const latest_version = "4.7";

pub fn build(b: *Build) !void {
    //
    // Options
    //

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const precision = b.option([]const u8, "precision", "Floating point precision, either `float` or `double` [default: `float`]") orelse "float";
    const architecture = b.option([]const u8, "arch", "32") orelse "64";
    const godot_version = b.option([]const u8, "godot-version", "Download and use this Godot version (e.g. `latest` or `4.5`)");
    const godot_path = b.option([]const u8, "godot-path", "Path to a Godot executable");
    // Off by default, on in CI. The sweep forces analysis of every generated
    // declaration, which is work the default build should not repeat on every
    // invocation; CI runs it as its own step so regressions still gate.
    const surface_audit = b.option(bool, "surface-audit", "Type-check every generated declaration") orelse false;
    const godot_project = b.option([]const u8, "godot_project", "Path to the Godot project");

    //
    // Steps
    //

    const check_step = b.step("check", "Check the build without installing artifacts");
    const test_step = b.step("test", "Run unit tests");
    const audit_step = b.step("audit", "Build the extension_api.json auditing tool");

    //
    // Dependencies
    //

    const casez = b.dependency("casez", .{});
    const oopz = b.dependency("oopz", .{});

    //
    // Godot
    //

    // Godot executable for the host (used for bindgen, running editor, etc.)
    const godot_exe_host: ?Build.LazyPath = blk: {
        if (godot_path) |p| {
            break :blk .{ .cwd_relative = p };
        }
        if (godot_version) |v| {
            break :blk godot.executable(b, b.graph.host, v);
        }
        if (b.findProgram(&.{"godot"}, &.{}) catch null) |p| {
            break :blk .{ .cwd_relative = p };
        }
        break :blk godot.executable(b, b.graph.host, latest_version);
    };

    // Godot executable for the target (used for running tests)
    // This enables cross-platform testing with -fwine
    const godot_exe_target: ?Build.LazyPath = blk: {
        if (godot_path) |p| {
            // If user specifies a path, assume it's for the target
            break :blk .{ .cwd_relative = p };
        }
        const tgt = if (target.result.cpu.arch.isWasm()) b.graph.host else target;
        if (godot_version) |v| {
            break :blk godot.executable(b, tgt, v);
        }
        break :blk godot.executable(b, tgt, latest_version);
    };

    const headers = blk: {
        const api_header_source: godot.HeaderSource = if (godot_path != null) .{ .exe = godot_exe_host.? } else if (godot_version) |v| .{ .version = v } else .{ .version = latest_version };
        const gdextension_interface_h = godot.headers(b, b.graph.host, api_header_source).path(b, "gdextension_interface.h");
        const extension_api_json = godot.headers(b, b.graph.host, api_header_source).path(b, "extension_api.json");

        const write = b.addWriteFiles();
        _ = write.addCopyFile(gdextension_interface_h, "gdextension_interface.h");
        _ = write.addCopyFile(extension_api_json, "extension_api.json");
        break :blk write.getDirectory();
    };

    if (godot_exe_target) |exe| {
        b.addNamedLazyPath("godot", exe);
    }
    b.addNamedLazyPath("gdextension_interface.h", headers.path(b, "gdextension_interface.h"));
    b.addNamedLazyPath("extension_api.json", headers.path(b, "extension_api.json"));

    //
    // GDExtension
    //

    const gdextension_mod = gdextension.build(b, .{
        .headers = headers,
        .target = target,
        .optimize = optimize,
    });

    //
    // Common
    //

    const common_mod = common.build(b, .{
        .target = target,
        .optimize = optimize,
        .casez = casez.module("casez"),
    });

    //
    // Bindgen
    //

    const bindgen_exe = bindgen.build(b, .{
        .headers = headers,
        .target = b.graph.host,
        .optimize = .Debug,
        .precision = precision,
        .architecture = architecture,
    });
    const bindings = bindgen.run(b, bindgen_exe, .{
        .headers = headers,
        .precision = precision,
        .architecture = architecture,
    });

    // Generated documentation links encode Zig autodoc declaration paths.
    // Check the entire generated surface so a renamed or skipped declaration
    // cannot silently leave thousands of "Declaration not found" links.
    const doc_links_test_exe = b.addExecutable(.{
        .name = "doc-links-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("build/doc_links_test.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const run_doc_links_test = b.addRunArtifact(doc_links_test_exe);
    run_doc_links_test.addDirectoryArg(bindings);
    run_doc_links_test.addDirectoryArg(b.path("src"));
    const doc_links_test_step = b.step("test-doc-links", "Check that generated documentation links resolve");
    doc_links_test_step.dependOn(&run_doc_links_test.step);

    //
    // API audit tool
    //

    const apiaudit_exe = apiaudit.build(b, .{
        .target = b.graph.host,
        .optimize = .Debug,
    });
    audit_step.dependOn(&b.addInstallArtifact(apiaudit_exe, .{}).step);

    //
    // Scaffolding tool
    //

    const init_exe = b.addExecutable(.{
        // Named for what it is on a PATH, not for what the step is called:
        // `init.exe` sitting in a bin directory says nothing about whose it is.
        .name = "init-gdzig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("build/init.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const run_init = b.addRunArtifact(init_exe);
    if (b.args) |args| {
        run_init.addArgs(args);
    }
    const init_step = b.step("init-gdzig", "Scaffold a new gdzig project");
    init_step.dependOn(&run_init.step);

    // Installed alongside the bindgen, so scaffolding a *second* project does
    // not mean going back to this checkout. Without it the only way to reach the
    // scaffolder is a build step here, and every new project starts with a `cd`
    // into a clone that has nothing else to do with it.
    b.installArtifact(init_exe);

    // Scaffolds a throwaway project and builds it. The scaffolder writes four
    // interlocking files and is the first thing a newcomer runs, so "does its
    // output compile" is the assertion worth having.
    const init_test_exe = b.addExecutable(.{
        .name = "init-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("build/init_test.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const run_init_test = b.addRunArtifact(init_test_exe);
    run_init_test.addArtifactArg(init_exe);
    run_init_test.addArg(".zig-cache/init-test/initprobe");
    // How the scaffolded project reaches this checkout: three levels up from
    // where it is written. A path dependency rather than the GitHub fetch the
    // scaffolder ends with, so the test needs no network and checks the tree it
    // is running in.
    run_init_test.addArg("../../..");
    // Spawns processes and writes outside the cache, so it must not be elided.
    run_init_test.has_side_effects = true;
    const init_test_step = b.step("test-init", "Scaffold a project with init-gdzig and build it");
    init_test_step.dependOn(&run_init_test.step);

    // `res` earns its keep by *rejecting* a bad path at comptime, which cannot
    // be asserted from a normal test: a test that triggers it stops compiling.
    // This drives a build that is expected to fail and reads the message back.
    const res_test_exe = b.addExecutable(.{
        .name = "res-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("build/res_test.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const run_res_test = b.addRunArtifact(res_test_exe);
    run_res_test.addArtifactArg(init_exe);
    run_res_test.addArg(".zig-cache/res-test/resprobe");
    run_res_test.addArg("../../..");
    run_res_test.has_side_effects = true;
    const res_test_step = b.step("test-res", "Check that res:// paths are verified at comptime");
    res_test_step.dependOn(&run_res_test.step);

    // Same shape as test-res: `assertSignalSignature`'s job is to fail, so
    // proving it works means building code that must not compile.
    const signal_test_exe = b.addExecutable(.{
        .name = "signal-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("build/signal_test.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const run_signal_test = b.addRunArtifact(signal_test_exe);
    run_signal_test.addArtifactArg(init_exe);
    run_signal_test.addArg(".zig-cache/signal-test/sigprobe");
    run_signal_test.addArg("../../..");
    run_signal_test.has_side_effects = true;
    const signal_test_step = b.step("test-signals", "Check that signal handler signatures are verified at comptime");
    signal_test_step.dependOn(&run_signal_test.step);

    // A misspelled virtual used to compile cleanly and then never run. Like
    // test-signals, proving the guard means building code that must fail and
    // checking the compile error names the correction.
    const virtual_test_exe = b.addExecutable(.{
        .name = "virtual-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("build/virtual_test.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const run_virtual_test = b.addRunArtifact(virtual_test_exe);
    run_virtual_test.addArtifactArg(init_exe);
    run_virtual_test.addArg(".zig-cache/virtual-test/virtualprobe");
    run_virtual_test.addArg("../../..");
    run_virtual_test.has_side_effects = true;
    const virtual_test_step = b.step("test-virtuals", "Check that unknown virtual callback names are rejected at comptime");
    virtual_test_step.dependOn(&run_virtual_test.step);

    // Headers are cached by the Godot executable that produced them. Exercise
    // replacement at one stable path, a flag-only change, and a failed dump
    // with tiny fake executables, so this gate needs neither a download nor a
    // real engine.
    const header_fake_v1_options = b.addOptions();
    header_fake_v1_options.addOption([]const u8, "marker", "v1");
    header_fake_v1_options.addOption(bool, "fail", false);
    const header_fake_v1 = b.addExecutable(.{
        .name = "header-cache-fake-v1",
        .root_module = b.createModule(.{
            .root_source_file = b.path("build/godot/headers_cache_fake.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
            .imports = &.{.{ .name = "fixture_options", .module = header_fake_v1_options.createModule() }},
        }),
    });
    const header_fake_v2_options = b.addOptions();
    header_fake_v2_options.addOption([]const u8, "marker", "v2");
    header_fake_v2_options.addOption(bool, "fail", false);
    const header_fake_v2 = b.addExecutable(.{
        .name = "header-cache-fake-v2",
        .root_module = b.createModule(.{
            .root_source_file = b.path("build/godot/headers_cache_fake.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
            .imports = &.{.{ .name = "fixture_options", .module = header_fake_v2_options.createModule() }},
        }),
    });
    const header_fake_fail_options = b.addOptions();
    header_fake_fail_options.addOption([]const u8, "marker", "xx");
    header_fake_fail_options.addOption(bool, "fail", true);
    const header_fake_fail = b.addExecutable(.{
        .name = "header-cache-fake-fail",
        .root_module = b.createModule(.{
            .root_source_file = b.path("build/godot/headers_cache_fake.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
            .imports = &.{.{ .name = "fixture_options", .module = header_fake_fail_options.createModule() }},
        }),
    });
    const header_cache_test_exe = b.addExecutable(.{
        .name = "header-cache-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("build/godot/headers_cache_test.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const run_header_cache_test = b.addRunArtifact(header_cache_test_exe);
    run_header_cache_test.addArtifactArg(header_fake_v1);
    run_header_cache_test.addArtifactArg(header_fake_v2);
    run_header_cache_test.addArtifactArg(header_fake_fail);
    run_header_cache_test.addFileArg(b.path("build/godot/HeadersStep.zig"));
    run_header_cache_test.addArg(".zig-cache/header-cache-test/probe");
    run_header_cache_test.has_side_effects = true;
    const header_cache_test_step = b.step("test-headers-cache", "Check Godot header caching and failure diagnostics");
    header_cache_test_step.dependOn(&run_header_cache_test.step);

    // The watcher is a loop that never returns, so this observes it from
    // outside -- through files it deletes, never through its output, which
    // would turn a failure into a hung job -- and kills it when done.
    const watch_exe = b.addExecutable(.{
        .name = "watch",
        .root_module = b.createModule(.{
            .root_source_file = b.path("build/watch.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const watch_test_exe = b.addExecutable(.{
        .name = "watch-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("build/watch_test.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const run_watch_test = b.addRunArtifact(watch_test_exe);
    run_watch_test.addArtifactArg(init_exe);
    run_watch_test.addArtifactArg(watch_exe);
    run_watch_test.addArg(".zig-cache/watch-test/watchprobe");
    run_watch_test.addArg("../../..");
    // The watcher's path arrives relative to this build root, and the test
    // spawns it with the scratch project as its working directory -- where a
    // relative path does not resolve. The root is passed so it can be joined.
    run_watch_test.addArg(b.pathFromRoot("."));
    run_watch_test.has_side_effects = true;
    const watch_test_step = b.step("test-watch", "Check that the watcher cleans artifacts and reacts to changes");
    watch_test_step.dependOn(&run_watch_test.step);

    // The six gates above are separate steps because each scaffolds a project
    // and runs nested builds, which is minutes rather than seconds -- too slow
    // to put on the command everyone runs constantly. But being reachable only
    // from CI is how the features they cover went untested to begin with, so
    // there is one command that runs everything.
    // Builds a project against gdzig as a package rather than as this
    // checkout. Everything else here reaches gdzig by path, and a path to this
    // tree has a .zig-cache with Godot in it -- which is what hid a build that
    // no fetched consumer could complete.
    const package_test_exe = b.addExecutable(.{
        .name = "package-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("build/package_test.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const run_package_test = b.addRunArtifact(package_test_exe);
    run_package_test.addArtifactArg(init_exe);
    run_package_test.addArg(".zig-cache/package-test");
    run_package_test.addArg(b.pathFromRoot("."));
    run_package_test.has_side_effects = true;
    const package_test_step = b.step("test-package", "Build a project against gdzig as a fetched package");
    package_test_step.dependOn(&run_package_test.step);
    // Every gate scaffolds a project whose nested build fetches Godot, and they
    // run in parallel: five processes asking for the same 179 MB archive at once,
    // where one loses and takes the suite with it --
    //
    //     error: failed reading resource: ReadFailed
    //     error: 'zig fetch .../Godot_v4.7.1-stable_win64.exe.zip' failed 3 times
    //
    // Retrying does not help when all five keep colliding. Waiting on the
    // download this build already does means the archive is in the global cache
    // before any gate starts, so every nested fetch is a hit and none of them
    // touch the network. Free where a Godot was already resolved from a path or
    // from PATH: there is no fetch step to wait for.
    if (godot_exe_host) |exe| {
        exe.addStepDependencies(&run_init_test.step);
        exe.addStepDependencies(&run_res_test.step);
        exe.addStepDependencies(&run_signal_test.step);
        exe.addStepDependencies(&run_virtual_test.step);
        exe.addStepDependencies(&run_watch_test.step);
        exe.addStepDependencies(&run_package_test.step);
    }
    const test_all_step = b.step("test-all", "Run the unit tests and every integration gate");
    test_all_step.dependOn(test_step);
    test_all_step.dependOn(init_test_step);
    test_all_step.dependOn(res_test_step);
    test_all_step.dependOn(signal_test_step);
    test_all_step.dependOn(virtual_test_step);
    test_all_step.dependOn(header_cache_test_step);
    test_all_step.dependOn(doc_links_test_step);
    test_all_step.dependOn(watch_test_step);
    test_all_step.dependOn(package_test_step);

    //
    // Library
    //

    const gdzig_files = b.addWriteFiles();
    const gdzig_combined = gdzig_files.addCopyDirectory(b.path("src"), "gdzig", .{
        .exclude_extensions = &.{".mixin.zig"},
    });
    _ = gdzig_files.addCopyDirectory(bindings, "gdzig", .{});

    const gdzig_options = b.addOptions();
    gdzig_options.addOption([]const u8, "architecture", architecture);
    gdzig_options.addOption([]const u8, "precision", precision);
    gdzig_options.addOption(bool, "surface_audit", surface_audit);

    var valid_res: std.ArrayList([]const u8) = .empty;
    if (godot_project) |project_path| {
        gdzig_options.addOption(?[]const u8, "godot_project", project_path);

        const io = b.graph.io;
        var dir = b.build_root.handle.openDir(io, project_path, .{ .iterate = true }) catch null;
        if (dir) |*d| {
            defer d.close(io);
            var walker = d.walk(b.allocator) catch @panic("OOM");
            defer walker.deinit();
            while (walker.next(io) catch null) |entry| {
                if (entry.kind != .file) continue;
                if (std.mem.startsWith(u8, entry.path, ".godot")) continue;
                if (std.mem.startsWith(u8, entry.path, ".git")) continue;

                const path = b.dupe(entry.path);
                std.mem.replaceScalar(u8, path, '\\', '/');
                const res_path = b.fmt("res://{s}", .{path});
                valid_res.append(b.allocator, res_path) catch @panic("OOM");
            }
        }
        gdzig_options.addOption([]const []const u8, "res_paths", valid_res.items);
    } else {
        gdzig_options.addOption(?[]const u8, "godot_project", null);
        gdzig_options.addOption([]const []const u8, "res_paths", &.{});
    }

    const gdzig_mod = b.addModule("gdzig", .{
        .root_source_file = gdzig_combined.path(b, "gdzig.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "build_options", .module = gdzig_options.createModule() },
            .{ .name = "casez", .module = casez.module("casez") },
            .{ .name = "gdextension", .module = gdextension_mod },
            .{ .name = "common", .module = common_mod },
            .{ .name = "oopz", .module = oopz.module("oopz") },
        },
    });
    gdzig_mod.addImport("gdzig", gdzig_mod);

    const gdzig_lib = b.addLibrary(.{
        .name = "gdzig",
        .root_module = gdzig_mod,
        .linkage = .static,
        .use_llvm = true,
    });

    //
    // Tests
    //
    var tests_gdzig_run: ?*Build.Step.Run = null;
    var tests_common_run: ?*Build.Step.Run = null;

    if (!target.result.cpu.arch.isWasm()) { // Do not add test for web targets.
        const tests_gdzig = b.addTest(.{ .root_module = gdzig_mod });
        const tests_common = b.addTest(.{ .root_module = common_mod });
        tests_gdzig_run = b.addRunArtifact(tests_gdzig);
        tests_common_run = b.addRunArtifact(tests_common);

        const io = b.graph.io;
        var tests_dir = try b.build_root.handle.openDir(io, "test", .{ .iterate = true });
        defer tests_dir.close(io);

        var iter = tests_dir.iterate();
        while (iter.next(io) catch null) |entry| {
            if (entry.kind != .directory) continue;

            const test_mod = b.createModule(.{
                .root_source_file = b.path(b.fmt("test/{s}/root.zig", .{entry.name})),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "gdzig", .module = gdzig_mod },
                },
            });

            const run_test = api.addTestImpl(b, .{ .b = b, .dep = null }, .{
                .name = b.dupe(entry.name),
                .root_module = test_mod,
                .target = target,
                .optimize = optimize,
            });
            test_step.dependOn(&run_test.step);
        }
    }

    //
    // Step dependencies
    //

    check_step.dependOn(&gdzig_lib.step);
    if (tests_gdzig_run) |r| test_step.dependOn(&r.step);
    if (tests_common_run) |r| test_step.dependOn(&r.step);

    //
    // Default step
    //

    // The generated bindings are installed back into `src/` so they can be read
    // and browsed, which makes that directory both an output of this step and an
    // input to the `gdzig_files` copy above. Nothing connects the two, so they
    // are free to run at the same time, and intermittently did: the install
    // writes each file as a hex-named temporary and renames it into place, while
    // the copy walks the same directory and fails with `FileNotFound` on a name
    // that has just been renamed away.
    //
    // Neither step needs the other's result, so ordering the write after the
    // read costs nothing and removes the overlap. `zig build test` never hit
    // this because it does not run the install step at all.
    const install_bindings = b.addInstallDirectory(.{
        .source_dir = bindings,
        .install_dir = .{ .custom = "../" },
        .install_subdir = "src",
    });
    install_bindings.step.dependOn(&gdzig_files.step);
    b.getInstallStep().dependOn(&install_bindings.step);

    b.installArtifact(bindgen_exe);

    // Autodoc. Emitting it needs the library analysed and therefore bindgen
    // run, so this is not free -- but it is also the only way to see the
    // generated surface as documentation rather than as source.
    //
    // Its own step as well as the default install, because wanting the docs and
    // wanting a built extension are different errands: `zig build docs` skips
    // installing the bindings, the bindgen executable and the vendored headers.
    //
    // The output is a wasm viewer, so it wants serving rather than opening off
    // disk: `python -m http.server -d zig-out/docs`.
    const install_docs = b.addInstallDirectory(.{
        .source_dir = gdzig_lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    b.getInstallStep().dependOn(&install_docs.step);
    b.step("docs", "Build the API documentation into zig-out/docs")
        .dependOn(&install_docs.step);
    b.installDirectory(.{
        .source_dir = headers,
        .install_dir = .prefix,
        .install_subdir = "vendor",
    });
}

fn getGodotVersion(b: *Build, p: Build.LazyPath) []const u8 {
    const result = std.process.Child.run(.{
        .allocator = b.allocator,
        .argv = &.{ p.getPath2(b, null), "--version" },
    }) catch @panic("Failed to run godot --version");
    const output = std.mem.trim(u8, result.stdout, &std.ascii.whitespace);

    var parts = std.mem.splitScalar(u8, output, '.');
    const major = parts.next() orelse @panic("Failed to parse major version");
    const minor = parts.next() orelse @panic("Failed to parse minor version");
    const patch = parts.next() orelse @panic("Failed to parse patch version");

    return b.fmt("{s}.{s}.{s}", .{ major, minor, patch });
}

const std = @import("std");
const Build = std.Build;

// Vendored rather than a package dependency; see build/godot/README.md.
const godot = @import("build/godot/build.zig");

const api = @import("build/api.zig");
pub const addExtension = api.addExtension;
pub const addTest = api.addTest;
pub const addWatchStep = api.addWatchStep;
pub const Extension = api.Extension;
pub const ExtensionOptions = api.ExtensionOptions;
pub const WatchOptions = api.WatchOptions;
pub const TestOptions = api.TestOptions;
pub const InitializationLevel = api.InitializationLevel;
const apiaudit = @import("build/apiaudit.zig");
const bindgen = @import("build/bindgen.zig");
const common = @import("build/common.zig");
const gdextension = @import("build/gdextension.zig");
