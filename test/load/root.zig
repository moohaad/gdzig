//! `godot.load(T, path)` — load a resource and narrow it in one step.
//!
//! The interesting part is ownership. `ResourceLoader.load` hands back a handle
//! that already owns a reference; `load` must pass that same reference on rather
//! than taking a second and dropping the first.

const std = @import("std");
const testing = std.testing;

/// Writes a Gradient to `user://` so there is something real to load back.
fn stage(comptime path: [:0]const u8) !void {
    var gradient = Gradient.init();
    defer gradient.deinit();

    var text: String = .fromLatin1(path);
    defer text.deinit();

    const err = ResourceSaver.save(Resource.upcast(gradient.get()), .{ .path = text });
    if (err != .ok) return error.SaveFailed;
}

test "loads and narrows to the requested type" {
    try stage("user://gdzig_load_test.tres");

    var loaded = godot.load(Gradient, "user://gdzig_load_test.tres") orelse
        return error.LoadFailed;
    defer loaded.deinit();

    // Sole owner. Failing to release the loader's own reference reads 2 here --
    // checked by breaking it on purpose. Note this does *not* distinguish the
    // `release`/`adopt` hand-over from a `borrow` followed by releasing the
    // original: both net to one. The first is preferred for not touching the
    // count at all, not because the second is wrong.
    try testing.expectEqual(@as(i32, 1), RefCounted.upcast(loaded.get()).getReferenceCount());
}

test "a wrong type is null, and does not leak the resource" {
    try stage("user://gdzig_load_type.tres");

    // A Gradient is not a PackedScene. `load` has to release what it loaded
    // before returning null.
    try testing.expectEqual(
        @as(?Gd(PackedScene), null),
        godot.load(PackedScene, "user://gdzig_load_type.tres"),
    );

    // Still loadable as its real type, and owned exactly once -- so the failed
    // attempt released what it loaded rather than leaking or over-releasing it.
    var again = godot.load(Gradient, "user://gdzig_load_type.tres") orelse
        return error.LoadFailed;
    defer again.deinit();
    try testing.expectEqual(@as(i32, 1), RefCounted.upcast(again.get()).getReferenceCount());
}

test "instantiateAs narrows the scene root" {
    // A PackedScene built in memory rather than loaded, so the test needs no
    // asset: pack a Node2d and instantiate it back.
    const source = Node2d.init();
    defer source.destroy();
    source.setName(.fromComptimeLatin1("Root"));

    var scene = PackedScene.init();
    defer scene.deinit();
    if (scene.get().pack(Node.upcast(source)) != .ok) return error.PackFailed;

    const root = scene.get().instantiateAs(Node2d) orelse return error.InstantiateFailed;
    defer root.destroy();

    var name = Node.upcast(root).getName();
    defer name.deinit();
    var text: String = .fromStringName(name);
    defer text.deinit();
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("Root", text.toUtf8Buf(&buf));
}

test "instantiateAs returns null for the wrong type" {
    const source = Node2d.init();
    defer source.destroy();

    var scene = PackedScene.init();
    defer scene.deinit();
    if (scene.get().pack(Node.upcast(source)) != .ok) return error.PackFailed;

    // A Node2d root is not a Timer.
    try testing.expectEqual(@as(?*Timer, null), scene.get().instantiateAs(Timer));
}

// Not covered: that the mismatched root is *freed* rather than leaked. Two
// attempts failed to observe it -- `Performance.getMonitor` does not move in a
// headless test, and a packed root of a class defined here never reached its
// `destroy` -- so the cleanup in `instantiateAs` rests on reading the code.

const godot = @import("gdzig");
const Gd = godot.Gd;
const Gradient = godot.class.Gradient;
const PackedScene = godot.class.PackedScene;
const RefCounted = godot.class.RefCounted;
const Node = godot.class.Node;
const Node2d = godot.class.Node2d;
const Resource = godot.class.Resource;
const Timer = godot.class.Timer;
const ResourceSaver = godot.class.ResourceSaver;
const String = godot.builtin.String;
