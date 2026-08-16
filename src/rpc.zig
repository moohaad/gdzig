//! RPC configuration declared next to the method it applies to.
//!
//! GDScript writes the config as an annotation on the function:
//!
//! ```gdscript
//! @rpc("any_peer", "call_local")
//! func shoot(): ...
//! ```
//!
//! Zig has no annotations, so it goes on the registration instead, which is the
//! nearest thing to the same place:
//!
//! ```zig
//! class.addMethod("shoot", .{ .rpc = .{ .mode = .any_peer, .call_local = true } });
//! ```
//!
//! ## Why this is not simply comptime
//!
//! `Node.rpcConfig` is an *instance* method -- it configures one node, not a
//! class -- so the config has to be applied per instance, from `_ready`. The
//! `_ready` wrapper is chosen by `VTable(T, ...)`, which only ever sees the
//! type, while `addMethod` is a call on a runtime `Registry`. Neither can see
//! the other.
//!
//! `Table(T)` bridges them: both sides are generic over `T`, so both reach the
//! same per-type slice by name. Registration fills it; the wrapper reads it.
//! The memory belongs to the registry's arena, so it lives exactly as long as
//! the class registration does.

const std = @import("std");

const oopz = @import("oopz");

const gdzig = @import("gdzig");
const class = @import("class.zig");
const Dictionary = gdzig.builtin.Dictionary;
const Node = class.Node;
const String = gdzig.builtin.String;
const StringName = gdzig.builtin.StringName;
const Variant = gdzig.builtin.Variant;

/// Who may call the method, matching `@rpc("any_peer")` and friends.
pub const Mode = enum {
    /// Callable by nobody. Godot's default, and what a method without an `rpc`
    /// option keeps.
    disabled,
    /// Callable by any peer, whether or not it owns the node.
    any_peer,
    /// Callable only by the node's multiplayer authority, the server by
    /// default. GDScript's default when `@rpc` is given no mode.
    authority,
};

/// Delivery guarantee, matching `@rpc("reliable")` and friends.
pub const Transfer = enum {
    unreliable,
    unreliable_ordered,
    reliable,
};

/// What `@rpc(...)` carries. Defaults match GDScript's bare `@rpc`.
pub const Config = struct {
    mode: Mode = .authority,
    transfer: Transfer = .reliable,
    /// Whether calling it also runs it on the caller.
    call_local: bool = false,
    channel: i32 = 0,
};

pub const Entry = struct {
    /// The name Godot knows the method by, as passed to `addMethod`.
    name: [:0]const u8,
    config: Config,
};

/// Per-type storage, reachable from both the registry and the vtable because
/// both are generic over `T`.
pub fn Table(comptime T: type) type {
    return struct {
        // `T` is what makes each instantiation a distinct type, and so a
        // distinct `entries`. It is otherwise unused.
        comptime {
            _ = T;
        }
        pub var entries: []const Entry = &.{};
    };
}

/// Whether `T` has any RPCs registered. Runtime, unlike `child.hasAny`, which
/// is why `_ready` cannot be synthesized conditionally on it.
pub fn hasAny(comptime T: type) bool {
    return Table(T).entries.len > 0;
}

/// Applies every registered config to `instance`. Called from the `_ready`
/// wrapper, before the user's own `_ready`.
pub fn configureAll(comptime T: type, instance: *T) void {
    // The call sits inside the branch, not after an early return: a
    // comptime-false `if (cond) return;` still analyses what follows, and
    // `configure` does not compile for the plain structs the vtable's own unit
    // tests use as `T`.
    if (comptime oopz.isA(Node, T)) configure(T, instance);
}

fn configure(comptime T: type, instance: *T) void {
    const list = Table(T).entries;
    if (list.len == 0) return;

    const node = oopz.upcast(*Node, instance);
    for (list) |entry| {
        var config: Dictionary = .init();
        defer config.deinit();

        put(&config, "rpc_mode", @intFromEnum(switch (entry.config.mode) {
            .disabled => gdzig.class.MultiplayerApi.RpcMode.rpc_mode_disabled,
            .any_peer => .rpc_mode_any_peer,
            .authority => .rpc_mode_authority,
        }));
        put(&config, "transfer_mode", @intFromEnum(switch (entry.config.transfer) {
            .unreliable => gdzig.class.MultiplayerPeer.TransferMode.transfer_mode_unreliable,
            .unreliable_ordered => .transfer_mode_unreliable_ordered,
            .reliable => .transfer_mode_reliable,
        }));
        put(&config, "channel", entry.config.channel);

        var call_local_key: String = .fromLatin1("call_local");
        defer call_local_key.deinit();
        _ = config.set(.init(String, call_local_key), .init(bool, entry.config.call_local));

        var name: StringName = .fromLatin1(entry.name, false);
        defer name.deinit();
        node.rpcConfig(name, .init(Dictionary, config));
    }
}

fn put(config: *Dictionary, comptime key: [:0]const u8, value: i64) void {
    var k: String = .fromLatin1(key);
    defer k.deinit();
    _ = config.set(.init(String, k), .init(i64, value));
}
