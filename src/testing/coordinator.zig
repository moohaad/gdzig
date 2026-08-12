//! Test coordinator that bridges the Zig build system and Godot processes.
//!
//! This executable:
//! 1. Speaks the std.zig.Server protocol with the build system (via stdin/stdout)
//! 2. Spawns Godot processes for each test folder
//! 3. Communicates with test harnesses via JSON IPC over stdin/stdout pipes
//!
//! The coordinator maintains a mapping from global test indices to (folder, local_index) pairs.

const std = @import("std");
const builtin = @import("builtin");
const protocol = @import("protocol.zig");
const options = @import("runner_options");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const ZigServer = std.zig.Server;

/// Mapping from global test index to folder and local index
const TestMapping = struct {
    folder_index: u32,
    local_index: u32,
};

/// Collects a spawned Godot's stderr on a task of its own.
///
/// `readResponse` blocks reading the child's stdout. If stderr were piped and
/// nobody read it, the child would block the first time it wrote enough to fill
/// that pipe, while we block waiting for stdout it can no longer produce -- a
/// deadlock, and one these tests provoke readily, since several deliberately
/// trigger engine errors.
///
/// The drain therefore has to make progress while this thread is blocked, which
/// is `concurrent` rather than `async`: `async` only promises the task runs by
/// the time it is awaited, and awaiting happens after the blocking read.
const StderrCapture = struct {
    buf: std.ArrayList(u8) = .empty,
    task: ?Io.Future(void) = null,

    fn start(self: *StderrCapture, io: Io, gpa: Allocator, file: Io.File) !void {
        self.task = try io.concurrent(drain, .{ io, file, gpa, &self.buf });
    }

    /// Waits for the drain to finish, which happens when the child exits and
    /// closes its end of the pipe. Idempotent.
    ///
    /// Must run before `Child.wait`, which closes the parent's handles as part
    /// of cleaning up and would pull the file out from under the drain.
    fn finish(self: *StderrCapture, io: Io) void {
        if (self.task) |*task| {
            task.await(io);
            self.task = null;
        }
    }

    fn deinit(self: *StderrCapture, gpa: Allocator) void {
        self.buf.deinit(gpa);
    }

    fn drain(io: Io, file: Io.File, gpa: Allocator, out: *std.ArrayList(u8)) void {
        var buf: [4096]u8 = undefined;
        while (true) {
            // Ends on error.EndOfStream when the child closes the pipe. A zero
            // read is not end-of-stream and is retried.
            const n = file.readStreaming(io, &.{&buf}) catch return;
            if (n == 0) continue;
            out.appendSlice(gpa, buf[0..n]) catch return;
        }
    }
};

/// State for the test runner
const Runner = struct {
    allocator: Allocator,
    io: Io,
    /// Parent environment, inherited by each spawned Godot process.
    environ: std.process.Environ,
    server: ZigServer,
    test_mappings: std.ArrayList(TestMapping),
    string_bytes: std.ArrayList(u8),
    test_name_indices: std.ArrayList(u32),

    fn init(allocator: Allocator, io: Io, environ: std.process.Environ, in: *Io.Reader, out: *Io.Writer) !Runner {
        const server = try ZigServer.init(.{
            .in = in,
            .out = out,
            .zig_version = builtin.zig_version_string,
        });

        return .{
            .allocator = allocator,
            .io = io,
            .environ = environ,
            .server = server,
            .test_mappings = .empty,
            .string_bytes = .empty,
            .test_name_indices = .empty,
        };
    }

    fn deinit(self: *Runner) void {
        self.test_mappings.deinit(self.allocator);
        self.string_bytes.deinit(self.allocator);
        self.test_name_indices.deinit(self.allocator);
    }

    fn run(self: *Runner) !void {
        while (true) {
            const header = self.server.receiveMessage() catch |err| {
                if (err == error.EndOfStream) break;
                return err;
            };

            switch (header.tag) {
                .exit => break,
                .query_test_metadata => try self.handleQueryTestMetadata(),
                .run_test => {
                    const index = try self.server.receiveBody_u32();
                    try self.handleRunTest(index);
                },
                else => {
                    _ = try self.server.in.discard(Io.Limit.limited(header.bytes_len));
                },
            }
        }
    }

    fn handleQueryTestMetadata(self: *Runner) !void {
        // Clear previous state
        self.test_mappings.clearRetainingCapacity();
        self.string_bytes.clearRetainingCapacity();
        self.test_name_indices.clearRetainingCapacity();

        // Collect metadata from each test folder
        for (options.test_folders, 0..) |folder, folder_idx| {
            try self.collectFolderMetadata(folder, @intCast(folder_idx));
        }

        // Build expected_panic_msgs (all zeros - we don't use panic expectations)
        const expected_panic_msgs = try self.allocator.alloc(u32, self.test_name_indices.items.len);
        defer self.allocator.free(expected_panic_msgs);
        @memset(expected_panic_msgs, 0);

        // Send metadata to build system
        try self.server.serveTestMetadata(.{
            .names = self.test_name_indices.items,
            .expected_panic_msgs = expected_panic_msgs,
            .string_bytes = self.string_bytes.items,
        });
    }

    /// Collects the stderr drain and reaps the child, in that order. Safe to
    /// call more than once, so an explicit call can precede the `defer`.
    fn reap(self: *Runner, child: *std.process.Child, stderr: *StderrCapture) void {
        stderr.finish(self.io);
        // `wait` asserts the child has not already been reaped.
        if (child.id != null) _ = child.wait(self.io) catch {};
    }

    fn collectFolderMetadata(self: *Runner, folder: []const u8, folder_idx: u32) !void {
        const folder_name = std.fs.path.basename(folder);

        // Spawn Godot with stdin/stdout/stderr piped
        var child = try self.spawnGodot(folder);
        var child_stderr: StderrCapture = .{};
        defer child_stderr.deinit(self.allocator);
        try child_stderr.start(self.io, self.allocator, child.stderr.?);
        defer self.reap(&child, &child_stderr);

        // Send query_metadata command
        try self.sendCommand(&child, .query_metadata);

        // Read response from stdout, filtering out Godot noise
        var godot_output: std.ArrayList(u8) = .empty;
        defer godot_output.deinit(self.allocator);

        const response = try self.readResponse(&child, &godot_output);
        if (response) |resp| {
            defer {
                var r = resp;
                protocol.freeResponse(self.allocator, &r);
            }

            switch (resp) {
                .metadata => |tests| {
                    for (tests, 0..) |name, i| {
                        // Record the string index before adding the prefixed name
                        const string_idx: u32 = @intCast(self.string_bytes.items.len);
                        try self.test_name_indices.append(self.allocator, string_idx);

                        // Add prefixed name: "folder.test name\0"
                        try self.string_bytes.appendSlice(self.allocator, folder_name);
                        try self.string_bytes.append(self.allocator, '.');
                        try self.string_bytes.appendSlice(self.allocator, name);
                        try self.string_bytes.append(self.allocator, 0);

                        // Record mapping
                        try self.test_mappings.append(self.allocator, .{
                            .folder_index = folder_idx,
                            .local_index = @intCast(i),
                        });
                    }
                },
                .result => return error.UnexpectedResponse,
            }
        } else {
            // Metadata collection failed. Reap first so the drain has finished
            // and its buffer can be reported alongside the stdout we captured.
            self.reap(&child, &child_stderr);
            if (godot_output.items.len > 0) {
                std.debug.print("Godot output:\n{s}\n", .{godot_output.items});
            }
            if (child_stderr.buf.items.len > 0) {
                std.debug.print("Godot stderr:\n{s}\n", .{child_stderr.buf.items});
            }
            return error.NoResponse;
        }

        // Send exit command
        try self.sendCommand(&child, .exit);
    }

    fn handleRunTest(self: *Runner, global_index: u32) !void {
        // The build runner tracks which test is in flight via `test_started`, and
        // asserts that the index in `test_results` matches it, so it must precede
        // every result -- including the out-of-range failure below.
        //
        // Send it before spawning Godot, not after: until it arrives the runner
        // holds us to a 60s "failed to respond" deadline, and only an in-flight
        // test lifts that. Spawning a headless Godot can exceed 60s when several
        // test binaries run concurrently.
        try self.server.serveStringMessage(.test_started, &.{});

        if (global_index >= self.test_mappings.items.len) {
            try self.server.serveTestResults(.{
                .index = global_index,
                .flags = .{ .status = .fail, .fuzz = false, .log_err_count = 0, .leak_count = 0 },
            });
            return;
        }

        const mapping = self.test_mappings.items[global_index];
        const folder = options.test_folders[mapping.folder_index];

        // Spawn Godot
        var child = try self.spawnGodot(folder);
        var child_stderr: StderrCapture = .{};
        defer child_stderr.deinit(self.allocator);
        try child_stderr.start(self.io, self.allocator, child.stderr.?);
        defer self.reap(&child, &child_stderr);

        // Send run_test command
        try self.sendCommand(&child, .{ .run_test = mapping.local_index });

        // Read response, collecting Godot output
        var godot_output: std.ArrayList(u8) = .empty;
        defer godot_output.deinit(self.allocator);

        var failed = true;
        const response = try self.readResponse(&child, &godot_output);
        if (response) |resp| {
            defer {
                var r = resp;
                protocol.freeResponse(self.allocator, &r);
            }

            switch (resp) {
                .result => |result| {
                    failed = !result.passed;
                },
                .metadata => {},
            }
        }

        self.sendCommand(&child, .exit) catch {};

        // Reap here rather than leaving it to the `defer`: the child's stderr is
        // only complete once the drain has finished, and it is wanted below.
        // `reap` is idempotent, so the `defer` remains correct for early exits.
        self.reap(&child, &child_stderr);

        // On failure, surface what Godot said. The build runner captures this
        // process's stderr per-test and prints it when a test fails, so it
        // reaches the user attributed to the right test -- and stays hidden
        // when the test passes, which is why the engine errors these tests
        // deliberately provoke no longer clutter a green run.
        if (failed) {
            const err = Io.File.stderr();
            if (godot_output.items.len > 0) {
                err.writeStreamingAll(self.io, godot_output.items) catch {};
            }
            if (child_stderr.buf.items.len > 0) {
                err.writeStreamingAll(self.io, child_stderr.buf.items) catch {};
            }
        }

        // Send result to build system
        try self.server.serveTestResults(.{
            .index = global_index,
            .flags = .{
                .status = if (failed) .fail else .pass,
                .fuzz = false,
                .log_err_count = 0,
                .leak_count = 0,
            },
        });
    }

    /// Send a command to the child process stdin
    fn sendCommand(self: *Runner, child: *std.process.Child, cmd: protocol.Command) !void {
        const stdin = child.stdin orelse return error.NoStdin;
        var buf: [4096]u8 = undefined;
        var writer = stdin.writerStreaming(self.io, &buf);
        try protocol.writeCommand(&writer.interface, cmd);
        try writer.interface.flush();
    }

    /// Read lines from Godot's stdout until we get an IPC response.
    /// Non-IPC lines are collected in godot_output for error display.
    /// Uses direct read() to avoid Windows pipe issues with pread/overlapped I/O.
    /// See: https://github.com/ziglang/zig/issues/25291
    fn readResponse(self: *Runner, child: *std.process.Child, godot_output: *std.ArrayList(u8)) !?protocol.Response {
        const stdout = child.stdout orelse return null;
        var line_buf: std.ArrayList(u8) = .empty;
        defer line_buf.deinit(self.allocator);

        var read_buf: [4096]u8 = undefined;
        var buf_start: usize = 0;
        var buf_end: usize = 0;

        while (true) {
            // Read bytes until we find a newline
            line_buf.clearRetainingCapacity();
            while (true) {
                // Refill buffer if empty
                if (buf_start >= buf_end) {
                    const n = stdout.readStreaming(self.io, &.{&read_buf}) catch return null;
                    if (n == 0) return null; // EOF
                    buf_start = 0;
                    buf_end = n;
                }

                const byte = read_buf[buf_start];
                buf_start += 1;

                if (byte == '\n') break;
                try line_buf.append(self.allocator, byte);
            }

            const line = line_buf.items;

            // Check if this is an IPC message
            if (protocol.isIpcMessage(line)) {
                if (try protocol.parseResponse(self.allocator, line)) |resp| {
                    return resp;
                }
            } else {
                // Collect non-IPC output
                try godot_output.appendSlice(self.allocator, line);
                try godot_output.append(self.allocator, '\n');
            }
        }
    }

    fn spawnGodot(self: *Runner, folder: []const u8) !std.process.Child {
        // Copy existing environment and add test mode flag
        var env_map = self.environ.createMap(self.allocator) catch return error.EnvironmentError;
        defer env_map.deinit();

        try env_map.put("GDZIG_TEST_MODE", "1");

        return try std.process.spawn(self.io, .{
            .argv = &.{ options.godot_exe, "--headless", "--path", folder, "--quit-after", "60" },
            .environ_map = &env_map,
            .stdin = .pipe,
            .stdout = .pipe,
            // Piped, and drained by a `StderrCapture` the caller starts right
            // after this returns. Piping without that drain deadlocks the child.
            .stderr = .pipe,
        });
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var stdin_buf: [4096]u8 = undefined;
    var stdout_buf: [4096]u8 = undefined;

    var stdin_reader = Io.File.stdin().readerStreaming(io, &stdin_buf);
    var stdout_writer = Io.File.stdout().writerStreaming(io, &stdout_buf);

    var runner = try Runner.init(allocator, io, init.minimal.environ, &stdin_reader.interface, &stdout_writer.interface);
    defer runner.deinit();

    try runner.run();
}
