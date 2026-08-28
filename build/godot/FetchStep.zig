//! A build step that fetches and extracts a zip file from a URL.
//! Uses `zig fetch` subprocess for TLS support, then extracts the archive.

const std = @import("std");
const Step = std.Build.Step;
const Io = std.Io;

const FetchStep = @This();

step: Step,
url: []const u8,
expected_hash: []const u8,
generated_directory: std.Build.GeneratedFile,
generated_executable: std.Build.GeneratedFile,

pub const base_id: Step.Id = .custom;

pub fn create(owner: *std.Build, name: []const u8, url: []const u8, expected_hash: []const u8) *FetchStep {
    const fetch = owner.allocator.create(FetchStep) catch @panic("OOM");
    fetch.* = .{
        .step = Step.init(.{
            .id = base_id,
            .name = name,
            .owner = owner,
            .makeFn = make,
        }),
        .url = owner.dupe(url),
        .expected_hash = owner.dupe(expected_hash),
        .generated_directory = .{ .step = &fetch.step },
        .generated_executable = .{ .step = &fetch.step },
    };
    return fetch;
}

pub fn getDirectory(fetch: *FetchStep) std.Build.LazyPath {
    return .{ .generated = .{ .file = &fetch.generated_directory } };
}

pub fn getExecutable(fetch: *FetchStep) std.Build.LazyPath {
    return .{ .generated = .{ .file = &fetch.generated_executable } };
}

fn make(step: *Step, _: Step.MakeOptions) !void {
    const b = step.owner;
    const arena = b.allocator;
    const io = b.graph.io;
    const fetch: *FetchStep = @fieldParentPtr("step", step);

    // Use the expected hash as the cache key
    var man = b.graph.cache.obtain();
    defer man.deinit();

    man.hash.addBytes(fetch.url);
    man.hash.addBytes(fetch.expected_hash);

    // Check cache
    if (try step.cacheHitAndWatch(&man)) {
        const digest = man.final();
        fetch.generated_directory.path = try b.cache_root.join(arena, &.{ "o", &digest });
        // Read the executable name from the marker file
        const exe_name = readExeName(arena, io, b.cache_root.handle, "o" ++ std.fs.path.sep_str ++ digest) catch |err| {
            return step.fail("failed to read cached executable name: {s}", .{@errorName(err)});
        };
        fetch.generated_executable.path = try b.cache_root.join(arena, &.{ "o", &digest, exe_name });
        step.result_cached = true;
        return;
    }

    const digest = man.final();
    const cache_path = "o" ++ std.fs.path.sep_str ++ digest;

    // Create output directory
    var cache_dir = b.cache_root.handle.createDirPathOpen(io, cache_path, .{ .open_options = .{ .iterate = true } }) catch |err| {
        return step.fail("unable to make cache path '{s}': {s}", .{
            cache_path, @errorName(err),
        });
    };
    defer cache_dir.close(io);

    fetch.generated_directory.path = try b.cache_root.join(arena, &.{ "o", &digest });

    // Use `zig fetch` to download the archive - it has TLS support
    // zig fetch outputs the hash of the fetched package
    const global_cache_path = b.graph.global_cache_root.path orelse {
        return step.fail("global cache root path is not available", .{});
    };

    // stderr is inherited rather than ignored: when the fetch fails, the reason
    // is the only useful thing there is, and discarding it left nothing but
    // "'zig fetch' failed" to work from.
    var zig_fetch = try std.process.spawn(io, .{
        .argv = &.{ "zig", "fetch", "--global-cache-dir", global_cache_path, fetch.url },
        .stderr = .inherit,
        .stdout = .pipe,
    });

    var read_buf: [4096]u8 = undefined;
    var stdout_reader = zig_fetch.stdout.?.readerStreaming(io, &read_buf);
    const stdout = try stdout_reader.interface.allocRemaining(arena, .limited(1024 * 1024));

    const result = try zig_fetch.wait(io);

    if (result != .exited or result.exited != 0) {
        return step.fail("'zig fetch {s}' failed (see stderr above)", .{fetch.url});
    }

    // zig fetch outputs the hash (with trailing newline)
    const pkg_hash = std.mem.trim(u8, stdout, "\n\r ");

    // Verify the hash matches what we expected
    if (!std.mem.eql(u8, pkg_hash, fetch.expected_hash)) {
        return step.fail("hash mismatch: expected '{s}', got '{s}'", .{ fetch.expected_hash, pkg_hash });
    }

    // The package lands in the global cache as <global_cache>/p/<hash>.tar.gz.
    //
    // Zig 0.15 and earlier left an extracted directory at p/<hash>, which this
    // step used to copy out of. Zig 0.16's `zig fetch` stores the compressed
    // tarball instead and offers no flag to extract it, so unpack it here.
    // Only when the directory is not already holding one. `std.tar.extract`
    // refuses to write over an existing entry, so a run that left the output in
    // place but not the cache manifest -- an interrupted build, a deleted
    // `.zig-cache/h`, two build roots racing on the same digest -- made every
    // later build fail with `PathAlreadyExists` until someone deleted the
    // directory by hand. An extracted Godot sitting there is a cache hit, not a
    // conflict, and skipping the work also spares re-reading 84 MB.
    if (extractedExecutable(step, io, cache_dir) == null) {
        const pkg_subpath = try std.fmt.allocPrint(arena, "p{c}{s}.tar.gz", .{ std.fs.path.sep, pkg_hash });

        var tarball = b.graph.global_cache_root.handle.openFile(io, pkg_subpath, .{}) catch |err| {
            return step.fail("failed to open fetched tarball '{s}': {s}", .{ pkg_subpath, @errorName(err) });
        };
        defer tarball.close(io);

        var file_buf: [64 * 1024]u8 = undefined;
        var tarball_reader = tarball.reader(io, &file_buf);

        var window: [std.compress.flate.max_window_len]u8 = undefined;
        var decompress: std.compress.flate.Decompress = .init(&tarball_reader.interface, .gzip, &window);

        std.tar.extract(io, cache_dir, &decompress.reader, .{
            // The archive wraps its contents in a single <hash>/ directory.
            .strip_components = 1,
            // Keeps the +x bit on the Godot binary, which matters off Windows.
            .mode_mode = .executable_bit_only,
        }) catch |err| {
            return step.fail("failed to extract '{s}': {s}", .{ pkg_subpath, @errorName(err) });
        };
    }

    // Find the Godot executable and store its path
    const exe_name = try findGodotExecutable(step, io, cache_dir);
    fetch.generated_executable.path = try b.cache_root.join(arena, &.{ "o", &digest, exe_name });

    // Write the executable name to a marker file for cache hits
    cache_dir.writeFile(io, .{ .sub_path = ".godot_exe", .data = exe_name }) catch |err| {
        return step.fail("failed to write executable marker: {s}", .{@errorName(err)});
    };

    // Write the manifest to finalize the cache entry
    try man.writeManifest();
}

fn readExeName(arena: std.mem.Allocator, io: Io, cache_root: Io.Dir, cache_path: []const u8) ![]const u8 {
    var dir = try cache_root.openDir(io, cache_path, .{});
    defer dir.close(io);
    const file = try dir.openFile(io, ".godot_exe", .{});
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var reader = file.readerStreaming(io, &buf);
    return reader.interface.allocRemaining(arena, .limited(std.fs.max_path_bytes));
}

/// Find the Godot executable in the directory
fn findGodotExecutable(step: *Step, io: Io, dir: Io.Dir) ![]const u8 {
    return extractedExecutable(step, io, dir) orelse
        step.fail("could not find Godot executable in extracted archive", .{});
}

/// The Godot executable in `dir`, or null if it does not hold one. Answers
/// rather than fails, so it can double as "has this already been extracted?".
fn extractedExecutable(step: *Step, io: Io, dir: Io.Dir) ?[]const u8 {
    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        const name = entry.name;

        // macOS app bundle - return path to executable inside
        if (entry.kind == .directory and std.mem.eql(u8, name, "Godot.app")) {
            return "Godot.app/Contents/MacOS/Godot";
        }

        // macOS app bundle extracted by zig fetch (strips .app wrapper, leaving just Contents/)
        if (entry.kind == .directory and std.mem.eql(u8, name, "Contents")) {
            return "Contents/MacOS/Godot";
        }

        if (entry.kind != .file) continue;

        // Match Godot executable: Godot_v* or Godot.* (but skip console versions)
        if (std.mem.startsWith(u8, name, "Godot_v") or std.mem.startsWith(u8, name, "Godot.")) {
            if (std.mem.indexOf(u8, name, "_console") != null) continue;
            return step.owner.dupe(name);
        }
    }

    return null;
}
