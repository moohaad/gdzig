const std = @import("std");

const codegen = @import("codegen.zig");
const Config = @import("Config.zig");
const Context = @import("Context.zig");
const GodotApi = @import("GodotApi.zig");

var verbose: bool = false;

pub const std_options: std.Options = .{
    .logFn = logFn,
};

fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (!verbose and level != .err) return;
    if (!verbose and scope == .markdown_formatter) return;
    std.log.defaultLog(level, scope, format, args);
}

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(allocator);

    if (args.len < 8) {
        std.debug.print("Usage: bindgen <gdextension_interface.h> <extension_api.json> <mixins_root> <output_path> <float|double> <32|64> <quiet|verbose> [class1,class2,...]\n", .{});
        return;
    }

    // Assemble the bindgen configuration
    var config = try Config.loadFromArgs(io, args);
    defer config.deinit();

    verbose = config.verbosity == .verbose;

    var buf: [4096]u8 = undefined;
    var reader = config.extension_api.reader(io, &buf);

    // Parse the extension_api.json
    const parser_start: std.Io.Timestamp = .now(io, .awake);
    const godot_api = try GodotApi.parseFromReader(&arena, &reader.interface);
    defer godot_api.deinit();
    const parser_time = parser_start.untilNow(io, .awake).toNanoseconds();

    // Build the codegen context
    const context_start: std.Io.Timestamp = .now(io, .awake);
    var ctx = try Context.build(&arena, godot_api.value, config);
    const context_time = context_start.untilNow(io, .awake).toNanoseconds();

    // Generate the code
    const codegen_start: std.Io.Timestamp = .now(io, .awake);
    try codegen.generate(&ctx);
    const codegen_time = codegen_start.untilNow(io, .awake).toNanoseconds();

    // Format the code
    const format_start: std.Io.Timestamp = .now(io, .awake);
    _ = try std.process.run(allocator, io, .{
        .cwd = .{ .dir = config.output },
        .argv = &.{ "zig", "fmt" },
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
    const format_time = format_start.untilNow(io, .awake).toNanoseconds();

    if (config.verbosity == .verbose) {
        if (config.verbosity == .verbose) {
            const total_time = parser_time + context_time + codegen_time + format_time;
            std.debug.print("Parser time: {d:.2}ms\n", .{@as(f64, @floatFromInt(parser_time)) / 1_000_000.0});
            std.debug.print("Context time: {d:.2}ms\n", .{@as(f64, @floatFromInt(context_time)) / 1_000_000.0});
            std.debug.print("Codegen time: {d:.2}ms\n", .{@as(f64, @floatFromInt(codegen_time)) / 1_000_000.0});
            std.debug.print("Format time: {d:.2}ms\n", .{@as(f64, @floatFromInt(format_time)) / 1_000_000.0});
            std.debug.print("Total time: {d:.2}ms\n", .{@as(f64, @floatFromInt(total_time)) / 1_000_000.0});
        }
        std.debug.print("Output path: {s}\n", .{args[4]});
        std.debug.print("Interface: {s}\n", .{args[1]});
        std.debug.print("API JSON: {s}\n", .{args[2]});
        if (config.classes.len > 0) std.debug.print("Selected classes: {s}\n", .{config.classes});
    }
}

test {
    std.testing.log_level = .err;
    std.testing.refAllDecls(@This());
}
