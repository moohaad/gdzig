const std = @import("std");

/// Run steps hash the executable contents and flags and track each output.
/// Keep the child process wrapper local so engine diagnostics survive failures.
pub fn create(b: *std.Build, executable: std.Build.LazyPath, use_docs: bool) std.Build.LazyPath {
    const tool = b.addExecutable(.{
        .name = "gdzig-dump-headers",
        .root_module = b.createModule(.{
            .root_source_file = b.path("build/header_dump.zig"),
            .target = b.graph.host,
            .optimize = .debug,
        }),
    });
    const run = b.addRunArtifact(tool);
    // Zig 0.17's Run cache can report a hit after an output was removed.
    // Validate outputs in the helper on every invocation before reusing a dump.
    run.has_side_effects = true;
    run.addFileArg(executable);
    run.addArg(if (use_docs) "docs" else "nodocs");
    const api = run.addOutputFileArg("extension_api.json");
    _ = run.addOutputFileArg("gdextension_interface.h");
    return api.dirname();
}
