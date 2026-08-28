const GuiNode = @This();

allocator: Allocator,

base: *Control,
sprite: *Sprite2D = undefined,
state: PlayerState = .idle,
clicks: i32 = 0,

pub const PlayerState = enum(i32) {
    idle = 0,
    running = 10,
    jumping = 20,
};

pub fn recreate(allocator: *Allocator, obj: *Object) *GuiNode {
    const self = allocator.create(GuiNode) catch @panic("OOM");
    self.* = .{
        .allocator = allocator.*,
        .base = @ptrCast(obj),
    };
    self.base.setInstance(GuiNode, self);
    godot.autoRestore(self);
    return self;
}

pub fn create(allocator: *Allocator) !*GuiNode {
    const self = try allocator.create(GuiNode);
    self.* = .{
        .allocator = allocator.*,
        .base = Control.init(),
    };
    self.base.setInstance(GuiNode, self);
    return self;
}

pub fn destroy(self: *GuiNode, allocator: *Allocator) void {
    godot.autoPersist(self);
    self.base.destroy();
    allocator.destroy(self);
}

pub fn _enterTree(self: *GuiNode) void {
    if (Engine.isEditorHint()) return;

    var normal_btn = Button.init();
    self.base.addChild(normal_btn, .{});
    normal_btn.setPosition(Vector2.initXY(100, 20), .{});

    // Test collection macros!
    var test_array = godot.array(.{ 42, 100, "hello" });
    defer test_array.deinit();
    var test_dict = godot.dict(.{ .name = "Player", .health = 100 });
    defer test_dict.deinit();
    godot.print("Array size: {d}, Dict size: {d}", .{ test_array.size(), test_dict.size() });
    normal_btn.setSize(Vector2.initXY(100, 50), .{});
    normal_btn.setText("Press Me");

    var free_btn = Button.init();
    self.base.addChild(free_btn, .{});
    free_btn.setPosition(Vector2.initXY(100, 100), .{});
    free_btn.setSize(Vector2.initXY(100, 50), .{});
    free_btn.setText("Free Func");

    // Connect to a free function using godot.callable
    const callb = godot.callable(self.allocator, self, onFreeFunction);
    free_btn.connectCallable(Button.Pressed, callb);

    var toggle_btn = CheckBox.init();
    self.base.addChild(toggle_btn, .{});
    toggle_btn.setPosition(.initXY(320, 20), .{});
    toggle_btn.setSize(.initXY(100, 50), .{});
    toggle_btn.setText("Toggle Me");

    toggle_btn.connect(Button.Toggled, self, &onToggled);
    normal_btn.connect(Button.Pressed, self, &onPressed);

    var texture = godot.res(Texture2D, "res://textures/logo.png").?;
    defer texture.deinit();
    self.sprite = Sprite2D.init();
    self.sprite.setTexture(texture);
    self.sprite.setPosition(.initXY(400, 300));
    // Test godot.path macro
    var my_path = godot.path("PlayerSprite");
    defer my_path.deinit();

    self.sprite.setScale(.initXY(0.6, 0.6));
    self.base.addChild(self.sprite, .{});
}

pub fn _exitTree(self: *GuiNode) void {
    _ = self;
}

pub fn onPressed(self: *GuiNode) void {
    self.clicks += 1;
    godot.print("onPressed, clicks: {d}", .{self.clicks});
}

pub fn onToggled(self: *GuiNode, toggled_on: ?bool) void {
    _ = self;
    godot.print("on_toggled {any}", .{toggled_on});
}

fn onFreeFunction(self: *GuiNode) void {
    godot.print("Free function called via godot.callable!", .{});
    self.clicks += 10;
}

const std = @import("std");
const Allocator = std.mem.Allocator;

const godot = @import("godot");
const Registry = godot.extension.Registry;
const Button = godot.class.Button;
const CheckBox = godot.class.CheckBox;
const Control = godot.class.Control;
const Engine = godot.class.Engine;
const Object = godot.class.Object;
const Resource = godot.class.Resource;
const Sprite2D = godot.class.Sprite2d;
const StringName = godot.builtin.StringName;
const Texture2D = godot.class.Texture2d;
const Vector2 = godot.builtin.Vector2;
