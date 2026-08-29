const nodes = .{
    SpriteNode,
    ConfigNode,
    ToolPlugin,
    ExampleNode,
    GuiNode,
    SignalNode,
    TreeNode,
    GlobalBus,
};

pub const GlobalBus = godot.EventBus(.{ struct { player_died: bool } });

pub fn register(r: *Registry) void {
    r.registerAll(nodes);
}

pub fn unregister(r: *Registry) void {
    r.unregisterAll(nodes);
}

test "godot version is 4.x" {
    // Tests run inside Godot via `zig build test`
    try std.testing.expectEqual(4, godot.version.major);
}



const std = @import("std");
const godot = @import("godot");
const Registry = godot.extension.Registry;

const ConfigNode = @import("ConfigNode.zig");
const ToolPlugin = @import("ToolPlugin.zig");
const ExampleNode = @import("ExampleNode.zig");
const GuiNode = @import("GuiNode.zig");
const SignalNode = @import("SignalNode.zig");
const TreeNode = @import("TreeNode.zig");
const SpriteNode = @import("SpriteNode.zig");
