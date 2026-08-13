//! Groups class methods by *marshalling shape* and reports which shapes the
//! tests exercise.
//!
//! `coverage` counts method names, and by that measure the suite touches 0.2%
//! of the surface. That number is true and useless: there are 16,822 class
//! methods and nobody is going to test them one at a time.
//!
//! The useful observation is that marshalling bugs cluster by signature shape
//! rather than by method. `getChildCount` returning `i32` and `getIndex`
//! returning `i32` walk the same generated code; if one is right, both are. So
//! the unit worth covering is the distinct shape, of which there are a few
//! hundred rather than tens of thousands, and they are skewed heavily enough
//! that a few dozen tests reach most of the surface.
//!
//! ## What a shape is
//!
//! The return type's kind, plus the *set* of `(kind, has_default)` pairs over
//! the arguments, plus whether the method is vararg. Kinds are coarse --
//! `int`, `float`, `bool`, `enum`, `flag`, `String`, `StringName`, `NodePath`,
//! `Variant`, `Array`, `Dictionary`, `typedarray`, `pointer`, `object/builtin`,
//! `void` -- because that is the granularity at which the generated marshalling
//! code actually differs.
//!
//! Three parts of that earn their place, each because a bug has already hidden
//! there:
//!
//! * **Return kind is kept separate from argument kinds.** Pooling them into
//!   one set is tempting and wrong: it merges a method returning an object with
//!   one taking an object, so a return-side defect can hide behind an
//!   argument-side test. The sub-8-byte ptrcall bug was return-only.
//! * **`has_default` is per argument, not per method.** Omitted-argument
//!   materialisation is its own code path, and the worst instance of it --
//!   `FileAccess.get_csv_line(delim = ",")`, whose non-empty `String` default
//!   was silently replaced with `""` -- lands in a shape of its own here.
//! * **Argument order and arity are dropped.** Two `Vector2` arguments marshal
//!   the same way one does; keeping the sequence inflates the shape count by
//!   half again and buys nothing.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const casez = @import("casez");
const common = @import("common");
const gdzig_case = common.gdzig_case;

const Json = std.json.Value;

/// One marshalling shape and the methods that share it.
const Shape = struct {
    /// Rendered form, e.g. `int <- (String, enum?)`. Doubles as the map key.
    text: []const u8,
    count: usize = 0,
    /// First method seen with this shape, as `Class.zigName`. Used as the
    /// suggested test subject, since any member exercises the whole shape.
    example: []const u8,
    /// Zig-cased method names in this shape, for the source scan.
    names: std.StringArrayHashMapUnmanaged(void) = .empty,
    /// A test calls a method that can only belong to this shape.
    exercised: bool = false,
    /// A test calls a method of this shape's, but the name also occurs in other
    /// shapes, so the call proves one of them ran and not which.
    ambiguous: bool = false,
};

pub fn run(arena: Allocator, io: Io, out: *Io.Writer, api_path: []const u8, test_dirs: []const [:0]const u8) !void {
    const main = @import("main.zig");
    const coverage = @import("coverage.zig");
    const doc = try std.json.parseFromSlice(Json, arena, try main.readFile(arena, io, api_path), .{});

    var shapes: std.StringArrayHashMapUnmanaged(Shape) = .empty;
    const methods = try collect(arena, doc.value, &shapes);

    if (methods == 0) {
        try out.writeAll("no class methods found; is this an extension_api.json?\n");
        return error.NoSources;
    }

    // Rank by method count, descending. Ties break on the shape text so the
    // report is stable across runs and diffable between Godot versions.
    const ranked = try arena.alloc(*Shape, shapes.count());
    for (shapes.values(), 0..) |*shape, i| ranked[i] = shape;
    std.mem.sort(*Shape, ranked, {}, byCountDesc);

    var scanned: usize = 0;
    if (test_dirs.len > 0) {
        var sources: std.ArrayList(u8) = .empty;
        for (test_dirs) |dir| try coverage.appendZigSources(arena, io, dir, &sources);
        scanned = sources.items.len;

        // The scan is textual and cannot tell `Node.getName` from
        // `Translation.getName`, so a called name only pins down a shape when it
        // occurs in exactly one. Counting a shape as exercised on an ambiguous
        // name would drop it off the worklist while it is still untested, which
        // is the one error worth avoiding here; an ambiguous hit is reported
        // separately instead.
        var shapes_per_name: std.StringHashMapUnmanaged(usize) = .empty;
        for (ranked) |shape| {
            for (shape.names.keys()) |name| {
                const seen = try shapes_per_name.getOrPutValue(arena, name, 0);
                seen.value_ptr.* += 1;
            }
        }

        for (ranked) |shape| {
            for (shape.names.keys()) |name| {
                if (!isCalled(sources.items, name)) continue;
                if (shapes_per_name.get(name).? == 1) {
                    shape.exercised = true;
                    break;
                }
                shape.ambiguous = true;
            }
        }
    }

    try out.print("{s}\n", .{versionOf(doc.value)});
    try out.print("{d} class methods across {d} marshalling shapes\n", .{ methods, shapes.count() });
    if (test_dirs.len > 0) {
        try out.print("scanned {d} bytes of test source across {d} director{s}\n", .{
            scanned, test_dirs.len, if (test_dirs.len == 1) @as([]const u8, "y") else "ies",
        });
    }

    try writeCurve(out, ranked, methods);
    if (test_dirs.len > 0) try writeCoverage(out, ranked, methods);
    try writeWorklist(out, ranked, methods, test_dirs.len > 0);
}

/// How much of the method surface the top N shapes account for. This is the
/// argument for doing the work at all: it says where to stop.
fn writeCurve(out: *Io.Writer, ranked: []const *Shape, methods: usize) !void {
    const thresholds = [_]usize{ 10, 25, 50, 100, 200 };
    if (ranked.len < thresholds[0]) return;

    try out.writeAll("\nreach of the top N shapes:\n");
    try out.writeAll("  shapes    methods   percent\n");
    for (thresholds) |n| {
        if (n > ranked.len) break;
        var sum: usize = 0;
        for (ranked[0..n]) |shape| sum += shape.count;
        try out.print("  {d: >6} {d: >10} {d: >8.1}%\n", .{ n, sum, pct(sum, methods) });
    }
}

fn writeCoverage(out: *Io.Writer, ranked: []const *Shape, methods: usize) !void {
    var hit_shapes: usize = 0;
    var hit_methods: usize = 0;
    var maybe_shapes: usize = 0;
    var maybe_methods: usize = 0;
    for (ranked) |shape| {
        if (shape.exercised) {
            hit_shapes += 1;
            hit_methods += shape.count;
        } else if (shape.ambiguous) {
            maybe_shapes += 1;
            maybe_methods += shape.count;
        }
    }
    try out.print("\n{d} of {d} shapes exercised, covering {d} of {d} methods ({d:.1}%)\n", .{
        hit_shapes, ranked.len, hit_methods, methods, pct(hit_methods, methods),
    });
    if (maybe_shapes > 0) {
        try out.print("{d} more ({d} methods, {d:.1}%) contain a called name that also occurs in\n", .{
            maybe_shapes, maybe_methods, pct(maybe_methods, methods),
        });
        try out.writeAll("another shape, so the call does not say which of them ran. Counted as uncovered.\n");
    }
}

/// The ranked list, which is the point of the subcommand: with a test scan it
/// is a worklist of what to cover next, and without one it is just the ranking.
fn writeWorklist(out: *Io.Writer, ranked: []const *Shape, methods: usize, scanned: bool) !void {
    if (scanned) {
        try out.writeAll("\nhighest-value shapes nothing covers yet:\n");
    } else {
        try out.writeAll("\nshapes by method count:\n");
    }
    try out.print("  {s: >8}  {s: <52}  {s}\n", .{ "methods", "shape", "example" });
    try out.splatByteAll('-', 8 + 52 + 8 + 20);
    try out.writeAll("\n");

    var shown: usize = 0;
    var skipped_methods: usize = 0;
    var skipped: usize = 0;
    for (ranked) |shape| {
        if (scanned and shape.exercised) continue;
        if (shown == 25) {
            skipped += 1;
            skipped_methods += shape.count;
            continue;
        }
        try out.print("  {d: >8}  {s: <52}  {s}\n", .{ shape.count, shape.text, shape.example });
        shown += 1;
    }
    if (shown == 0) try out.writeAll("  (none)\n");
    if (skipped > 0) {
        try out.print("  ... and {d} more, {d} methods ({d:.1}% of the surface)\n", .{
            skipped, skipped_methods, pct(skipped_methods, methods),
        });
    }
}

/// Buckets every class method by shape. Returns the method count.
fn collect(arena: Allocator, doc: Json, shapes: *std.StringArrayHashMapUnmanaged(Shape)) !usize {
    const list = doc.object.get("classes") orelse return 0;
    var methods: usize = 0;

    for (list.array.items) |class| {
        const class_name = class.object.get("name").?.string;
        const class_methods = class.object.get("methods") orelse continue;

        for (class_methods.array.items) |method| {
            methods += 1;
            const api_name = method.object.get("name").?.string;
            const zig_name = try casez.allocConvert(arena, gdzig_case.func, api_name);
            const text = try render(arena, method);

            const entry = try shapes.getOrPut(arena, text);
            if (!entry.found_existing) {
                entry.value_ptr.* = .{
                    .text = text,
                    .example = try std.fmt.allocPrint(arena, "{s}.{s}", .{ class_name, zig_name }),
                };
            }
            entry.value_ptr.count += 1;
            try entry.value_ptr.names.put(arena, zig_name, {});
        }
    }
    return methods;
}

/// Renders a method's shape, e.g. `int <- (String, enum?)`, where `?` marks an
/// argument that has a default and `...` a vararg tail. Also the map key, so it
/// has to be canonical: arguments are deduplicated and sorted.
fn render(arena: Allocator, method: Json) ![]const u8 {
    const Arg = struct { kind: []const u8, default: bool };

    var args: std.ArrayList(Arg) = .empty;
    if (method.object.get("arguments")) |list| {
        for (list.array.items) |arg| {
            const k = kindOf(arg.object.get("type").?.string);
            const has_default = arg.object.contains("default_value");
            for (args.items) |seen| {
                if (seen.default == has_default and std.mem.eql(u8, seen.kind, k)) break;
            } else try args.append(arena, .{ .kind = k, .default = has_default });
        }
    }

    std.mem.sort(Arg, args.items, {}, struct {
        fn lt(_: void, a: Arg, b: Arg) bool {
            return switch (std.mem.order(u8, a.kind, b.kind)) {
                .lt => true,
                .gt => false,
                // A kind appearing both with and without a default sorts the
                // plain one first, so the rendering reads consistently.
                .eq => @intFromBool(a.default) < @intFromBool(b.default),
            };
        }
    }.lt);

    const ret = if (method.object.get("return_value")) |rv|
        kindOf(rv.object.get("type").?.string)
    else
        "void";

    var text: std.ArrayList(u8) = .empty;
    const w = &text;
    try w.appendSlice(arena, ret);
    try w.appendSlice(arena, " <- (");
    for (args.items, 0..) |arg, i| {
        if (i > 0) try w.appendSlice(arena, ", ");
        try w.appendSlice(arena, arg.kind);
        if (arg.default) try w.append(arena, '?');
    }
    if (method.object.get("is_vararg")) |v| if (v.bool) {
        if (args.items.len > 0) try w.appendSlice(arena, ", ");
        try w.appendSlice(arena, "...");
    };
    try w.append(arena, ')');
    return text.items;
}

/// Coarsens an API type name to the granularity at which generated marshalling
/// code differs. Anything unrecognised is a class or builtin passed by pointer,
/// which all marshal alike.
fn kindOf(api_type: []const u8) []const u8 {
    const passthrough = [_][]const u8{
        "void",  "int",        "float",    "bool",    "String",
        "Array", "StringName", "NodePath", "Variant", "Dictionary",
    };
    for (passthrough) |name| {
        if (std.mem.eql(u8, api_type, name)) return name;
    }
    if (std.mem.startsWith(u8, api_type, "typedarray::")) return "typedarray";
    if (std.mem.startsWith(u8, api_type, "bitfield::")) return "flag";
    if (std.mem.startsWith(u8, api_type, "enum::")) return "enum";
    // Native-structure and raw-buffer parameters, e.g. `const uint8_t*`. These
    // bypass the usual conversion entirely, so they are their own kind.
    if (std.mem.endsWith(u8, api_type, "*")) return "pointer";
    return "object/builtin";
}

/// Whether `name` appears in the sources as a call. Matches coverage.zig's
/// `.call` rule: bounded on the left, followed by `(`.
fn isCalled(sources: []const u8, name: []const u8) bool {
    if (name.len == 0) return false;
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, sources, search, name)) |at| {
        search = at + name.len;

        const before: u8 = if (at == 0) ' ' else sources[at - 1];
        if (std.ascii.isAlphanumeric(before) or before == '_') continue;

        const after: u8 = if (search >= sources.len) ' ' else sources[search];
        if (after == '(') return true;
    }
    return false;
}

fn byCountDesc(_: void, a: *Shape, b: *Shape) bool {
    if (a.count != b.count) return a.count > b.count;
    return std.mem.order(u8, a.text, b.text) == .lt;
}

fn pct(part: usize, whole: usize) f64 {
    if (whole == 0) return 0;
    return @as(f64, @floatFromInt(part)) * 100.0 / @as(f64, @floatFromInt(whole));
}

fn versionOf(doc: Json) []const u8 {
    const header = doc.object.get("header") orelse return "unknown";
    const version = header.object.get("version_full_name") orelse return "unknown";
    return version.string;
}
