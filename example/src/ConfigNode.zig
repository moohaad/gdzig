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
    const class = r.createClass(ConfigNode, r.allocator, .auto);
    class.addProperty("startup_delay", .auto);
}

pub fn unregister(r: *Registry) void {
    r.removeClass(ConfigNode);
}

allocator: Allocator,
base: *Node,

/// Seconds `ExampleNode` waits before its first tick. Exported, so the
/// inspector can change it without a rebuild.
startup_delay: f64 = 1.0,

pub fn create(allocator: *Allocator) !*ConfigNode {
    const self = try allocator.create(ConfigNode);
    self.* = .{ .allocator = allocator.*, .base = Node.init() };
    self.base.setInstance(ConfigNode, self);
    return self;
}

pub fn recreate(allocator: *Allocator, obj: *Object) *ConfigNode {
    const self = allocator.create(ConfigNode) catch @panic("OOM");
    self.* = .{ .allocator = allocator.*, .base = @ptrCast(obj) };
    self.base.setInstance(ConfigNode, self);
    return self;
}

pub fn destroy(self: *ConfigNode, allocator: *Allocator) void {
    self.base.destroy();
    allocator.destroy(self);
}

const std = @import("std");
const Allocator = std.mem.Allocator;

const godot = @import("godot");
const Registry = godot.extension.Registry;
const Node = godot.class.Node;
const Object = godot.class.Object;
