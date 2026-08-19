pub const empty: StringName = std.mem.zeroes(StringName);

/// Creates a StringName from a Latin-1 encoded C string.
///
/// If `is_static` is true, then:
/// - The StringName will reuse the `str` buffer instead of copying it.
///   You must guarantee that the buffer remains valid for the duration of the application (e.g. string literal).
/// - You must not call a destructor for this StringName. Incrementing the initial reference once should achieve this.
///
/// On Godot 4.1, falls back to creating via String (ignores `is_static`).
pub inline fn fromLatin1(str: [:0]const u8, is_static: bool) StringName {
    if (raw.stringNameNewWithLatin1Chars) |func| {
        var result: StringName = undefined;
        func(result.ptr(), @ptrCast(str.ptr), @intFromBool(is_static));
        return result;
    }
    return viaString(str);
}

/// Interns a comptime Latin-1 string once and borrows the cached result.
///
/// The name is created static, so the engine keeps it for the life of the
/// process and the cache holds its single reference. You get a `*const` to that
/// reference rather than a copy of it, which is the whole point: the pointer
/// cannot be passed to `deinit`, so the reference cannot be released by anyone
/// who does not own it.
///
/// It used to return a value. A copy shares the cache's `_data` without
/// incrementing, so destroying one released a reference the caller never took;
/// Godot answers that with `BUG: Unreferenced static string to 0`, frees the
/// entry, and lets the next intern take the vacated slot -- after which the
/// cache hands back a name that is some other string. `Callable.fromClosure`
/// did exactly that. Now it will not compile.
///
/// Pass it straight to anything wanting a `*const StringName`. Where a value is
/// wanted, `.*` copies one out; that copy is a borrow too, so still do not
/// destroy it.
///
/// Not interned static, though the engine offers it. A static `StringName`
/// reuses the caller's buffer rather than copying, and `str` lives in this
/// library's rodata -- which a hot reload unmaps while the engine goes on
/// pointing at it. The header calls the flag "purely an optimization" that "can
/// easily introduce undefined behavior if used wrong", and a reload is exactly
/// wrong. Copying costs one short memcpy per literal, once.
///
/// The copy is also what makes the cache releasable: a static name must never
/// be destroyed, so `releaseInterned` would have been the very bug described
/// above.
pub fn fromComptimeLatin1(comptime str: [:0]const u8) *const StringName {
    const S = struct {
        const key = str;
        var entry: Interned = .{};
    };

    if (S.entry.state.load(.acquire) == 2) return &S.entry.value;

    if (S.entry.state.cmpxchgStrong(0, 1, .acquire, .monotonic) == null) {
        // This thread owns the initialisation.
        if (raw.stringNameNewWithLatin1Chars) |func| {
            func(@ptrCast(&S.entry.value), @ptrCast(str.ptr), 0);
        } else {
            S.entry.value = viaString(str);
        }
        link(&S.entry);
        S.entry.state.store(2, .release);
        return &S.entry.value;
    }

    // Another thread got there first; wait for it to publish. Construction is a
    // single engine call, so spinning beats any machinery to sleep on.
    while (S.entry.state.load(.acquire) != 2) std.atomic.spinLoopHint();
    return &S.entry.value;
}

/// The same interned name as [`fromComptimeLatin1`](#fromComptimeLatin1), by
/// value, so a decl literal can stand in wherever a `StringName` is wanted:
///
/// ```zig
/// sprite.play(.{ .name = .interned("walk") });
/// if (Input.isActionJustPressed(.interned("jump"), .{})) self.jump();
/// ```
///
/// This is the spelling to reach for. `fromLatin1` builds a fresh name that has
/// to be released, which inline at a call site means either a leak or a
/// temporary to hang a `defer` on; interning costs one memcpy the first time
/// each literal is used and nothing afterwards.
///
/// A decl literal is what makes it work in *both* positions. A parameter could
/// have been widened to `anytype` to take a `[]const u8` directly, but a struct
/// field cannot be `anytype`, so every defaulted argument -- which is where
/// names most often appear -- would have been left out.
///
/// The value is a borrow of the cached one, exactly as `.*` on the pointer form
/// is. Do not `deinit` it: that would destroy the entry every later use shares.
pub fn interned(comptime str: [:0]const u8) StringName {
    return fromComptimeLatin1(str).*;
}

/// One interned literal, and the link that makes it reachable again.
///
/// The node lives inside the per-literal static, so interning allocates
/// nothing: the cost of being releasable is one pointer of static per literal
/// and one push the first time each is used.
const Interned = struct {
    value: StringName = undefined,
    /// 0 = untouched, 1 = a thread is building it, 2 = published.
    ///
    /// A plain `bool` raced: a second thread could see it set beside a
    /// half-written `StringName`, since nothing ordered the two stores. The
    /// release/acquire pair is what makes the value visible only after it is
    /// complete.
    state: std.atomic.Value(u8) = .init(0),
    /// Written only by the thread that built this entry, before it publishes.
    next: ?*Interned = null,
};

var interned_list: std.atomic.Value(?*Interned) = .init(null);

fn link(entry: *Interned) void {
    var head = interned_list.load(.monotonic);
    while (true) {
        entry.next = head;
        head = interned_list.cmpxchgWeak(head, entry, .release, .monotonic) orelse return;
    }
}

/// Releases every interned literal and empties the cache.
///
/// For the extension's exit path. Without it a reload leaks one `StringName`
/// per literal per cycle, because the statics holding them are either reset by
/// the unload or -- where the library stays mapped, which is the usual case on
/// Windows -- still holding names nothing will ever release.
///
/// Entries return to the untouched state rather than being unlinked and
/// forgotten, so a library that is still mapped re-interns correctly on the
/// next use.
pub fn releaseInterned() void {
    var node = interned_list.swap(null, .acquire);
    while (node) |entry| {
        const next = entry.next;
        entry.value.deinit();
        entry.next = null;
        entry.state.store(0, .release);
        node = next;
    }
}

/// Creates a StringName from a UTF-8 encoded string.
///
/// On Godot 4.1, falls back to creating via String.
pub inline fn fromUtf8(str: []const u8) StringName {
    if (raw.stringNameNewWithUtf8CharsAndLen) |func| {
        var result: StringName = undefined;
        func(result.ptr(), @ptrCast(str.ptr), @intCast(str.len));
        return result;
    }

    var gd_string: String = undefined;
    raw.stringNewWithUtf8CharsAndLen(gd_string.ptr(), @ptrCast(str.ptr), @intCast(str.len));
    defer gd_string.deinit();
    return StringName.fromString(gd_string);
}

/// Creates a StringName from a null-terminated UTF-8 C string.
///
/// On Godot 4.1, falls back to creating via String.
pub inline fn fromNullTerminatedUtf8(str: [:0]const u8) StringName {
    if (raw.stringNameNewWithUtf8Chars) |func| {
        var result: StringName = undefined;
        func(result.ptr(), @ptrCast(str.ptr));
        return result;
    }

    return viaString(str);
}

pub fn fromType(comptime T: type) *const StringName {
    return fromTypeName(typeShortName(T));
}

pub fn fromSignal(comptime S: type) *const StringName {
    return fromSignalName(typeShortName(S));
}

pub fn fromTypeName(comptime name: []const u8) *const StringName {
    const converted = comptime casez.comptimeConvert(godot_case.type, name);
    return fromComptimeLatin1(converted);
}

pub fn fromConstantName(comptime name: []const u8) *const StringName {
    const converted = comptime casez.comptimeConvert(godot_case.constant, name);
    return fromComptimeLatin1(converted);
}

pub fn fromFunctionName(comptime name: []const u8) *const StringName {
    const converted = comptime casez.comptimeConvert(godot_case.func, name);
    return fromComptimeLatin1(converted);
}

pub fn fromMethodName(comptime name: []const u8) *const StringName {
    const converted = comptime casez.comptimeConvert(godot_case.method, name);
    return fromComptimeLatin1(converted);
}

pub fn fromPropertyName(comptime name: []const u8) *const StringName {
    const converted = comptime casez.comptimeConvert(godot_case.field, name);
    return fromComptimeLatin1(converted);
}

pub fn fromSignalName(comptime name: []const u8) *const StringName {
    const converted = comptime casez.comptimeConvert(godot_case.signal, name);
    return fromComptimeLatin1(converted);
}

pub fn fromVirtualMethodName(comptime name: []const u8) *const StringName {
    const converted = comptime casez.comptimeConvert(godot_case.virtual_method, name);
    return fromComptimeLatin1(converted);
}

/// Creates a StringName via an intermediate String (4.1 fallback).
fn viaString(str: [:0]const u8) StringName {
    var gd_string: String = undefined;
    raw.stringNewWithUtf8Chars(gd_string.ptr(), @ptrCast(str.ptr));
    defer gd_string.deinit();
    return StringName.fromString(gd_string);
}

fn typeShortName(comptime T: type) [:0]const u8 {
    const full = @typeName(T);
    const pos = std.mem.lastIndexOfScalar(u8, full, '.') orelse return full;
    return full[pos + 1 ..];
}

const casez = @import("casez");
const common = @import("common");
const godot_case = common.godot_case;

// @mixin stop

const std = @import("std");
const DeclEnum = std.meta.DeclEnum;

const gdzig = @import("gdzig");
const raw = &gdzig.raw;
const String = gdzig.builtin.String;
const StringName = gdzig.builtin.StringName;
