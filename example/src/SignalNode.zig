const SignalNode = @This();

pub const signals = .{ Signal1, Signal2, Signal3 };

pub const groups = .{
    .{ "Colors", .{}, .{ "colors_signal2", "colors_signal3" } },
};



pub const bind_nodes = .{
    .{ "bound_button", "signal1_btn" },
};

allocator: Allocator,
base: *Control, //this makes @Self a valid gdextension class
color_rect: *ColorRect = undefined,
button_pool: godot.Pool(Button) = undefined,
bound_button: ?*Button = null,
my_enum: TestEnum = .OptionA,

// Colors group
colors_signal2: Color = Color.initRGBA(0, 1, 0, 1),
colors_signal3: Color = Color.initRGBA(1, 0, 0, 1),

pub const Signal1 = struct {
    name: String,
    position: Vector3,
};
pub const Signal2 = struct {};
pub const Signal3 = struct {};

pub const TestEnum = enum(i64) {
    OptionA = 0,
    OptionB = 1,
    OptionC = 2,
};

pub fn recreate(allocator: *Allocator, obj: *Object) *SignalNode {
    const self = allocator.create(SignalNode) catch @panic("OOM");
    self.* = .{
        .allocator = allocator.*,
        .base = @ptrCast(obj),
        .button_pool = godot.Pool(Button).init(allocator.*, 10) catch @panic("OOM"),
    };
    self.base.setInstance(SignalNode, self);
    return self;
}

pub fn create(allocator: *Allocator) !*SignalNode {
    const self = try allocator.create(SignalNode);
    self.* = .{
        .allocator = allocator.*,
        .base = Control.init(),
        .button_pool = godot.Pool(Button).init(allocator.*, 10) catch @panic("OOM"),
    };
    self.base.setInstance(SignalNode, self);
    return self;
}

pub fn destroy(self: *SignalNode, allocator: *Allocator) void {
    self.base.destroy();
    allocator.destroy(self);
}

pub fn _enterTree(self: *SignalNode) void {
    if (godot.inEditor()) return;

    var signal1_btn = Button.init();
    signal1_btn.setName("signal1_btn");
    signal1_btn.setPosition(.initXY(100, 20), .{});
    signal1_btn.setSize(.initXY(100, 50), .{});
    signal1_btn.setText("Signal1");
    self.base.addChild(signal1_btn, .{});

    var signal2_btn = Button.init();
    signal2_btn.setPosition(.initXY(250, 20), .{});
    signal2_btn.setSize(.initXY(100, 50), .{});
    signal2_btn.setText("Signal2");
    self.base.addChild(signal2_btn, .{});

    var signal3_btn = Button.init();
    signal3_btn.setPosition(.initXY(400, 20), .{});
    signal3_btn.setSize(.initXY(100, 50), .{});
    signal3_btn.setText("Signal3");
    self.base.addChild(signal3_btn, .{});

    self.color_rect = ColorRect.init();
    self.color_rect.setPosition(.initXY(400, 400), .{});
    self.color_rect.setSize(.initXY(100, 100), .{});
    self.color_rect.setColor(.initRGBA(1, 0, 0, 1));
    self.base.addChild(self.color_rect, .{});

    signal1_btn.connect(Button.Pressed, self, &emitSignal1);
    signal2_btn.connect(Button.Pressed, self, &emitSignal2);
    signal3_btn.connect(Button.Pressed, self, &emitSignal3);
    self.base.connect(Signal1, self, &onSignal1);
    self.base.connect(Signal2, self, &onSignal2);
    self.base.connect(Signal3, self, &onSignal3);

    self.base.addToGroup("test_group", .{});
    if (self.base.getTree()) |tree| {
        if (godot.getNodesInGroupAs(tree, SignalNode, "test_group", self.allocator)) |n| {
            var nodes = n;
            defer nodes.deinit(self.allocator);
            godot.print("Found {d} SignalNodes in 'test_group'!", .{nodes.items.len});
        } else |_| {}
    }

    if (self.base.getNodeAs(Button, "signal1_btn")) |btn| {
        godot.print("Found signal1_btn via getNodeAs!", .{});
        _ = btn;
    }
}

pub fn _ready(self: *SignalNode) void {
    if (godot.inEditor()) return;

    // Nothing assigns `bound_button`. The `bind_nodes` declaration at the top
    // of the file names the field and the path, and the class machinery fills
    // it before `_ready` runs -- the same moment a `Child` field resolves.
    //
    // Why here and not in `_enterTree`, where the button is built: at that
    // point nothing has bound it yet. A class that needs the field earlier has
    // to call `godot.bindNodes(self)` for itself.
    if (self.bound_button) |_| {
        godot.print("Bound button is working!", .{});
    } else {
        godot.print("bind_nodes did not fill bound_button", .{});
    }
}

pub fn _exitTree(self: *SignalNode) void {
    _ = self;
}

pub fn onSignal1(_: *SignalNode, name: String, position: Vector3) void {
    var buf: [256]u8 = undefined;
    const n = name.toLatin1Buf(&buf);
    std.debug.print("signal1 received : name = {s} position={any}\n", .{ n, position });
}

pub fn onSignal2(self: *SignalNode) void {
    std.debug.print("{} {}\n", .{ self.color_rect, self.colors_signal2 });
    self.color_rect.setColor(self.colors_signal2);
}

pub fn onSignal3(self: *SignalNode) void {
    self.color_rect.setColor(self.colors_signal3);
}

pub fn emitSignal1(self: *SignalNode) void {
    self.base.emit(Signal1, .{
        .name = String.fromLatin1("test_signal_name"),
        .position = .initXYZ(123, 321, 333),
    }) catch {};

    if (godot.tween(self.base)) |tw| {
        _ = tw.property(self.color_rect, "position", godot.builtin.Vector2.initXY(100, 100), 1.0)
              .interval(0.5)
              .callback(self, &onTweenFinished);
    }
}

pub fn onTweenFinished(self: *SignalNode) void {
    godot.print("Tween finished!", .{});
    _ = self;
}
pub fn emitSignal2(self: *SignalNode) void {
    self.base.emit(Signal2, .{}) catch {};
}
pub fn emitSignal3(self: *SignalNode) void {
    self.base.emit(Signal3, .{}) catch {};
}

const std = @import("std");
const Allocator = std.mem.Allocator;

const godot = @import("godot");
const Registry = godot.extension.Registry;
const Button = godot.class.Button;
const Color = godot.builtin.Color;
const ColorRect = godot.class.ColorRect;
const Control = godot.class.Control;
const Engine = godot.class.Engine;
const Object = godot.class.Object;
const StringName = godot.builtin.StringName;
const String = godot.builtin.String;
const Vector3 = godot.builtin.Vector3;
