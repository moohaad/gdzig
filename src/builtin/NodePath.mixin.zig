

/// Interns a comptime Latin-1 string once and borrows the cached result.
/// The NodePath is created static, so the engine keeps it for the life of the
/// process and the cache holds its single reference.
pub fn fromComptimeLatin1(comptime str: [:0]const u8) *const NodePath {
    const S = struct {
        var cached: ?NodePath = null;
        var init_done: bool = false;
    };
    
    // Very simple lazy initialization without threadsafety for now, 
    // assuming it's mostly used in single-threaded contexts like _ready.
    if (!S.init_done) {
        var gd_str = String.fromNullTerminatedUtf8(str);
        defer gd_str.deinit();
        S.cached = NodePath.fromString(gd_str);
        S.init_done = true;
    }
    
    return &S.cached.?;
}

/// The same interned NodePath by value, borrowing the underlying string.
pub fn interned(comptime str: [:0]const u8) NodePath {
    return fromComptimeLatin1(str).*;
}

// @mixin stop

const std = @import("std");
const gdzig = @import("gdzig");
const NodePath = gdzig.builtin.NodePath;
const String = gdzig.builtin.String;
