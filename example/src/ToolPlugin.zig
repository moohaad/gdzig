//! An editor plugin, which is a class the *editor* runs rather than the game.
//!
//! Registered with `addEditorPlugin` rather than `addClass`. Descending from
//! `EditorPlugin` is not enough on its own: Godot has to be told by name, once
//! the class is in ClassDB, and that is what the registry now does. It also
//! forces the editor initialization level, since a plugin registered at any
//! other level is one the editor never sees.
//!
//! No `create`, `recreate` or `destroy`: an `allocator` and a `base` field are
//! all gdzig needs to write them.

const ToolPlugin = @This();

pub fn register(r: *Registry) void {
    r.addEditorPlugin(ToolPlugin, r.allocator, .auto);
}

pub fn unregister(r: *Registry) void {
    r.removeClass(ToolPlugin);
}

allocator: Allocator,
base: *EditorPlugin,

/// Runs when the editor loads the plugin, which is the point of the exercise.
pub fn _enterTree(self: *ToolPlugin) void {
    _ = self;
    std.log.info("example: editor plugin loaded", .{});
}

const std = @import("std");
const Allocator = std.mem.Allocator;

const godot = @import("godot");
const Registry = godot.extension.Registry;
const EditorPlugin = godot.class.EditorPlugin;
