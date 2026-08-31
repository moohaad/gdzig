//! `{f}` on Godot's string types.
//!
//! Zig's `{f}` compiles to `value.format(writer)`. Godot's own `String.format`
//! is string interpolation and takes `(values, placeholder)`, so for as long as
//! the binding carried that name, every `{f}` on a `String` was a compile error
//! raised inside `std.Io.Writer` -- a trace into std, from a format string in
//! the caller's own file, saying "member function expected 2 argument(s)".
//!
//! The engine method is generated as `formatValues` now, which leaves the name
//! free for a formatter that means what Zig means by it.

pub fn register(_: *gdzig.extension.Registry) void {}

test "{f} writes a String's contents" {
    var s = String.fromLatin1("hello");
    defer s.deinit();

    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("hello", try std.fmt.bufPrint(&buf, "{f}", .{s}));
}

test "{f} writes a StringName's contents" {
    var n = StringName.fromLatin1("Marker", false);
    defer n.deinit();

    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("Marker", try std.fmt.bufPrint(&buf, "{f}", .{n}));
}

test "{f} does not stop at the chunk size" {
    // `format` takes 256 characters per pass. A formatter that fills one stack
    // buffer and returns looks correct on every short string and silently cuts
    // this one, which is the failure worth pinning.
    const long = "x" ** 1000;
    var s = String.fromLatin1(long);
    defer s.deinit();

    var buf: [2048]u8 = undefined;
    const written = try std.fmt.bufPrint(&buf, "{f}", .{s});
    try testing.expectEqual(@as(usize, 1000), written.len);
    try testing.expectEqualStrings(long, written);
}

test "Godot's own interpolation survives the rename" {
    // Renaming it out of the way must not drop it.
    _ = &String.formatValues;
    _ = &StringName.formatValues;
}

const std = @import("std");
const testing = std.testing;

const gdzig = @import("gdzig");
const String = gdzig.builtin.String;
const StringName = gdzig.builtin.StringName;
