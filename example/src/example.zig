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

pub const GlobalBus = godot.EventBus(.{struct { player_died: bool }});

pub fn register(r: *Registry) void {
    comptime assertDemoSceneTypes();
    r.registerAll(nodes);
}

pub fn unregister(r: *Registry) void {
    r.unregisterAll(nodes);
}

test "godot version is 4.x" {
    // Tests run inside Godot via `zig build test`
    try std.testing.expectEqual(4, godot.version.major);
}

/// `demo.tscn` stores only the Godot class name for this extension type. The
/// map gives SceneWith the Zig side once; every generated field then stays
/// concrete, including when the class is reached through another scene.
fn assertDemoSceneTypes() void {
    const Types = struct {
        pub const ExampleNode = @import("ExampleNode.zig");
    };
    const Children = godot.SceneWith(@embedFile("demo/demo.tscn"), Types);
    for (@typeInfo(Children).@"struct".fields) |field| {
        if (std.mem.eql(u8, field.name, "ExampleNode")) {
            if (field.type.Resolves != ExampleNode)
                @compileError("demo ExampleNode lost its Zig scene type");
            return;
        }
    }
    @compileError("demo.tscn no longer contains ExampleNode");
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
