//! A build step that dumps GDExtension headers from a Godot executable.
//! Can use a known version or detect it at build time.

const std = @import("std");
const Step = std.Build.Step;
const Io = std.Io;
const HeadersStep = @This();

step: Step,
godot_exe: std.Build.LazyPath,
generated_directory: std.Build.GeneratedFile,
/// If set, use these flags directly. If null, detect version at build time.
known_flags: ?Flags,

pub const Flags = struct {
    use_docs: bool,
    has_json: bool,
};

pub const base_id: Step.Id = .custom;

/// Create a HeadersStep that detects version at build time
pub fn create(owner: *std.Build, godot_exe: std.Build.LazyPath) *HeadersStep {
    return createWithFlags(owner, godot_exe, null);
}

/// Create a HeadersStep with known version flags
pub fn createWithFlags(owner: *std.Build, godot_exe: std.Build.LazyPath, flags: ?Flags) *HeadersStep {
    const headers = owner.allocator.create(HeadersStep) catch @panic("OOM");
    headers.* = .{
        .step = Step.init(.{
            .id = base_id,
            .name = "dump gdextension headers",
            .owner = owner,
            .makeFn = make,
        }),
        .godot_exe = godot_exe.dupe(owner),
        .generated_directory = .{ .step = &headers.step },
        .known_flags = flags,
    };
    godot_exe.addStepDependencies(&headers.step);
    return headers;
}

pub fn getDirectory(headers: *HeadersStep) std.Build.LazyPath {
    return .{ .generated = .{ .file = &headers.generated_directory } };
}

fn make(step: *Step, prog_node: Step.MakeOptions) !void {
    const b = step.owner;
    const arena = b.allocator;
    const io = b.graph.io;
    const headers: *HeadersStep = @fieldParentPtr("step", step);

    // Must be absolute: the dump runs with its cwd set to the output directory,
    // so a build-root-relative path would not resolve from there.
    //
    // `std.fs.path.resolve` is not enough. It is purely lexical -- it performs
    // no syscalls and never consults the process cwd -- so given a single
    // relative path it returns it unchanged. `pathFromRoot` anchors it to the
    // build root, which is what `getPath2` returns paths relative to.
    const godot_path_rel = headers.godot_exe.getPath2(b, step);
    const godot_path = if (std.fs.path.isAbsolute(godot_path_rel))
        godot_path_rel
    else
        b.pathFromRoot(godot_path_rel);

    // Determine the exact command shape before building the cache key. For a
    // downloaded, known version this is free; an explicitly supplied binary
    // needs one cheap `--version` call so changes to the version thresholds
    // below invalidate the dump even when the executable itself did not move.
    const use_docs, const has_json = if (headers.known_flags) |flags|
        .{ flags.use_docs, flags.has_json }
    else blk: {
        const version_str = try runGodotVersion(step, io, godot_path, prog_node);
        const version = parseVersionString(version_str);
        break :blk .{ shouldUseDocs(version), hasJsonInterface(version) };
    };

    // The path alone is not an input: users commonly replace `godot` in place
    // when upgrading. Track the executable as a file so the manifest observes
    // its contents, plus every flag that changes which files Godot writes.
    // The schema tag covers changes to the fixed arguments or output contract.
    var man = b.graph.cache.obtain();
    defer man.deinit();
    // A hit whose output files disappeared must be turned back into a writer.
    // Keep the exclusive lock so that recovery is safe and only one concurrent
    // build regenerates this digest.
    man.want_shared_lock = false;

    man.hash.addBytes("gdzig-gdextension-headers-v2");
    man.hash.addBytes(godot_path);
    man.hash.add(use_docs);
    man.hash.add(has_json);
    _ = man.addFilePath(headers.godot_exe.getPath3(b, step), null) catch |err| {
        return step.fail("failed to hash Godot executable '{s}': {s}", .{ godot_path, @errorName(err) });
    };

    // A manifest hit records a successful older run, but its output directory
    // can be removed independently or an interrupted cleanup can leave only
    // some files. Regenerate instead of returning a dead LazyPath.
    if (try step.cacheHitAndWatch(&man)) hit: {
        const digest = man.final();
        const cache_path = try std.fs.path.join(arena, &.{ "o", &digest });
        if (!headersExist(io, b.cache_root.handle, cache_path, has_json)) break :hit;

        headers.generated_directory.path = try b.cache_root.join(arena, &.{cache_path});
        step.result_cached = true;
        return;
    }
    step.result_cached = false;

    const digest = man.final();
    const cache_path = "o" ++ std.fs.path.sep_str ++ digest;

    // Create output directory
    var cache_dir = b.cache_root.handle.createDirPathOpen(io, cache_path, .{}) catch |err| {
        return step.fail("unable to make cache path '{s}': {s}", .{
            cache_path, @errorName(err),
        });
    };
    defer cache_dir.close(io);

    headers.generated_directory.path = try b.cache_root.join(arena, &.{ "o", &digest });

    // Build arguments array (max 6 args)
    var args: [6][]const u8 = undefined;
    var arg_count: usize = 0;

    args[arg_count] = godot_path;
    arg_count += 1;

    args[arg_count] = if (use_docs) "--dump-extension-api-with-docs" else "--dump-extension-api";
    arg_count += 1;

    args[arg_count] = "--dump-gdextension-interface";
    arg_count += 1;

    if (has_json) {
        args[arg_count] = "--dump-gdextension-interface-json";
        arg_count += 1;
    }

    args[arg_count] = "--headless";
    arg_count += 1;

    args[arg_count] = "--quit";
    arg_count += 1;

    // Run Godot quietly on success, but retain both output streams so a failed
    // dump reports the engine's real diagnostic instead of only its exit code.
    const cwd_path = headers.generated_directory.path orelse
        return step.fail("generated directory path not set", .{});
    const output = std.process.run(arena, io, .{
        .argv = args[0..arg_count],
        .cwd = .{ .path = cwd_path },
        .stdout_limit = .limited(diagnostic_limit),
        .stderr_limit = .limited(diagnostic_limit),
    }) catch |err| {
        return step.fail("failed to run Godot header dump with '{s}' in '{s}': {s}", .{ godot_path, cwd_path, @errorName(err) });
    };

    if (output.term != .exited or output.term.exited != 0) {
        return failGodot(step, "header dump", output.term, output.stdout, output.stderr);
    }
    if (!headersExist(io, b.cache_root.handle, cache_path, has_json)) {
        return step.fail("Godot exited successfully but did not produce every requested GDExtension header", .{});
    }

    // Write the manifest to finalize the cache entry and watch the executable
    // for in-place replacement during a long-lived `zig build --watch` run.
    try step.writeManifestAndWatch(&man);
}

fn headersExist(io: Io, cache_root: Io.Dir, cache_path: []const u8, has_json: bool) bool {
    const required = [_][]const u8{
        "extension_api.json",
        "gdextension_interface.h",
        "gdextension_interface.json",
    };
    const count: usize = if (has_json) required.len else required.len - 1;

    for (required[0..count]) |name| {
        const path = std.fs.path.join(std.heap.page_allocator, &.{ cache_path, name }) catch return false;
        defer std.heap.page_allocator.free(path);
        cache_root.access(io, path, .{}) catch return false;
    }
    return true;
}

fn runGodotVersion(step: *Step, io: Io, godot_path: []const u8, prog_node: Step.MakeOptions) ![]const u8 {
    _ = prog_node;
    const arena = step.owner.allocator;

    const output = std.process.run(arena, io, .{
        .argv = &.{ godot_path, "--version" },
        .stdout_limit = .limited(diagnostic_limit),
        .stderr_limit = .limited(diagnostic_limit),
    }) catch |err| {
        return step.fail("failed to run Godot --version with '{s}': {s}", .{ godot_path, @errorName(err) });
    };

    if (output.term != .exited or output.term.exited != 0) {
        return failGodot(step, "--version", output.term, output.stdout, output.stderr);
    }

    // Return first line, trimmed.
    const first_line = std.mem.sliceTo(output.stdout, '\n');
    return std.mem.trim(u8, first_line, "\r ");
}

fn failGodot(
    step: *Step,
    operation: []const u8,
    term: std.process.Child.Term,
    stdout: []const u8,
    stderr: []const u8,
) error{ OutOfMemory, MakeFailed } {
    return switch (term) {
        .exited => |code| step.fail(
            "Godot {s} exited with status {d}\n--- stdout ---\n{s}\n--- stderr ---\n{s}",
            .{ operation, code, stdout, stderr },
        ),
        .signal => |signal| step.fail(
            "Godot {s} terminated by signal {t}\n--- stdout ---\n{s}\n--- stderr ---\n{s}",
            .{ operation, signal, stdout, stderr },
        ),
        .stopped => |signal| step.fail(
            "Godot {s} stopped by signal {t}\n--- stdout ---\n{s}\n--- stderr ---\n{s}",
            .{ operation, signal, stdout, stderr },
        ),
        .unknown => |status| step.fail(
            "Godot {s} ended with unknown status {d}\n--- stdout ---\n{s}\n--- stderr ---\n{s}",
            .{ operation, status, stdout, stderr },
        ),
    };
}

const diagnostic_limit = 16 << 20;

/// Parsed version info for determining flags
const ParsedVersion = struct {
    major: u8,
    minor: u8,
    patch: u8,
    prerelease: ?[]const u8,
};

/// Parse version string like "4.6.beta2.official.abc123"
fn parseVersionString(version_str: []const u8) ParsedVersion {
    var result: ParsedVersion = .{
        .major = 4,
        .minor = 0,
        .patch = 0,
        .prerelease = null,
    };

    var parts = std.mem.splitScalar(u8, version_str, '.');

    // Parse major
    if (parts.next()) |major_str| {
        result.major = std.fmt.parseInt(u8, major_str, 10) catch 4;
    }

    // Parse minor
    if (parts.next()) |minor_str| {
        result.minor = std.fmt.parseInt(u8, minor_str, 10) catch 0;
    }

    // Parse patch or prerelease
    if (parts.next()) |third| {
        // Could be patch number or prerelease (e.g., "0" or "beta2")
        if (std.fmt.parseInt(u8, third, 10)) |patch| {
            result.patch = patch;
            // Next part would be prerelease
            if (parts.next()) |pre| {
                result.prerelease = pre;
            }
        } else |_| {
            // Not a number, it's a prerelease
            result.prerelease = third;
            result.patch = 0;
        }
    }

    return result;
}

/// Check if this version should use --dump-extension-api-with-docs
fn shouldUseDocs(version: ParsedVersion) bool {
    // 4.1.x: no docs
    if (version.major == 4 and version.minor == 1) return false;

    // 4.2.0-dev[1-5]: no docs
    if (version.major == 4 and version.minor == 2 and version.patch == 0) {
        if (version.prerelease) |pre| {
            if (std.mem.startsWith(u8, pre, "dev")) {
                const num = std.fmt.parseInt(u8, pre[3..], 10) catch return true;
                return num >= 6;
            }
        }
    }

    // Everything else 4.2+ has docs
    return version.major > 4 or (version.major == 4 and version.minor >= 2);
}

/// Check if this version has --dump-gdextension-interface-json
fn hasJsonInterface(version: ParsedVersion) bool {
    // Only 4.6.0-dev5 and later
    if (version.major > 4) return true;
    if (version.major < 4) return false;

    // major == 4
    if (version.minor > 6) return true;
    if (version.minor < 6) return false;

    // major == 4, minor == 6
    if (version.prerelease) |pre| {
        if (std.mem.startsWith(u8, pre, "dev")) {
            const num = std.fmt.parseInt(u8, pre[3..], 10) catch return true;
            return num >= 5;
        }
        // beta, rc, stable all have it
        if (std.mem.startsWith(u8, pre, "beta") or
            std.mem.startsWith(u8, pre, "rc") or
            std.mem.startsWith(u8, pre, "stable"))
        {
            return true;
        }
    }

    // If patch > 0, it's post-4.6.0 so it has JSON interface
    return version.patch > 0;
}
