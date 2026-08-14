//! Loading resources by path.
//!
//! `ResourceLoader.load` returns a `?Gd(Resource)` -- the base type, because
//! that is what the engine method is declared to return. Getting a `PackedScene`
//! out of it meant unwrapping the handle, narrowing the pointer, wrapping it
//! again, and releasing the original:
//!
//! ```zig
//! var path: String = .fromLatin1("res://Mob.tscn");
//! defer path.deinit();
//! if (ResourceLoader.load(path, .{})) |resource| {
//!     var owned = resource;
//!     if (PackedScene.downcast(owned.get())) |scene| {
//!         self.mob_scene = Gd(PackedScene).borrow(scene);
//!     }
//!     owned.deinit();
//! }
//! ```
//!
//! Ten lines, and the `borrow`/`deinit` pair takes a reference only to drop the
//! original -- correct, but churn to express a hand-over. `load` says it once:
//!
//! ```zig
//! self.mob_scene = godot.load(PackedScene, "res://Mob.tscn");
//! ```

const std = @import("std");

const oopz = @import("oopz");

const gdzig = @import("gdzig");
const class = @import("class.zig");
const Resource = class.Resource;
const ResourceLoader = class.ResourceLoader;
const String = gdzig.builtin.String;
const Gd = @import("gd.zig").Gd;

/// Loads the resource at `path` and narrows it to `T`.
///
/// Null if nothing is there or it is not a `T`; in the latter case the resource
/// is released rather than leaked. The returned handle owns a reference and
/// needs a `deinit`.
pub fn load(comptime T: type, comptime path: [:0]const u8) ?Gd(T) {
    comptime oopz.assertIsA(Resource, T);

    var text: String = .fromLatin1(path);
    defer text.deinit();

    var loaded = ResourceLoader.load(text, .{}) orelse return null;

    if (class.castTo(T, loaded.get())) |narrowed| {
        // Hand the same reference over rather than taking a second and dropping
        // the first: `release` gives up ownership without touching the count,
        // and `adopt` picks it up.
        _ = loaded.release();
        return .adopt(narrowed);
    }

    loaded.deinit();
    return null;
}

test {
    // Behaviour needs a live engine and a project to load from; see test/load.
    std.testing.refAllDecls(@This());
}
