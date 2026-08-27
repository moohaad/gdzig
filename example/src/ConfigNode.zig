//! A singleton, so `Autoload` has something real to reach.
//!
//! `project.godot` loads `res://demo/config.tscn` as `Config` before the main
//! scene, and that scene's root node is this class. Anything in the tree can
//! then declare a field for it:
//!
//! ```zig
//! config: Autoload(ConfigNode, "Config") = .pending,
//! ```
//!
//! Deliberately dull -- one setting, no behaviour. An autoload's job is to be
//! findable, and the interesting part is the field that finds it.

const ConfigNode = @This();

pub fn register(r: *Registry) void {
    r.autoRegister(ConfigNode);
}

/// A value the *code* decides, unlike `startup_delay`, which Godot serialises
/// across a reload and replays. A property surviving proves the instance
/// survived; only something like this proves the new library is the one
/// answering.
pub fn buildTag(_: *ConfigNode) i64 {
    return 1;
}

/// Counts calls in a module-level `var`, which is the same storage class as the
/// `_ptr` caches in `general.zig` and behind every generated method bind. If
/// those survive a reload this keeps counting; if the library is unloaded and
/// its statics start over, it reads 1 again. Either answer settles what the
/// caches do, because it is the same storage.
var epoch: i64 = 0;

pub fn cacheEpoch(_: *ConfigNode) i64 {
    epoch += 1;
    return epoch;
}

/// Goes through one of the cached utility pointers named as hazard 3 in the
/// reload plan. A stale pointer there is the failure that hazard describes; a
/// correct answer after a reload is what says there is not one.
pub fn typeofProbe(_: *ConfigNode) i64 {
    return godot.general.typeof(.init(i64, 7));
}

pub fn unregister(r: *Registry) void {
    r.removeClass(ConfigNode);
}

allocator: Allocator,
base: *Node,

/// Seconds `ExampleNode` waits before its first tick. Exported, so the
/// inspector can change it without a rebuild.
startup_delay: f64 = 1.0,

const std = @import("std");
const Allocator = std.mem.Allocator;

const godot = @import("godot");
const Registry = godot.extension.Registry;
const Node = godot.class.Node;
const Object = godot.class.Object;
