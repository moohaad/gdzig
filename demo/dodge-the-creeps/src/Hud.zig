//! Score, messages and the start button.
//!
//! Ported from `demo-projects/dodge-the-creeps/rust/src/hud.rs`.

const Hud = @This();

/// Emitted when the player presses Start. `Main` listens for it.
pub const StartGame = struct {};

pub fn register(r: *Registry) void {
    const class = r.createClass(Hud, r.allocator, .auto);
    class.addSignal(StartGame);

    // Wired in Hud.tscn.
    class.addMethod("on_start_button_pressed", .auto);
    class.addMethod("on_message_timer_timeout", .auto);
    // Connected from `showGameOver` via `fromClosure`, which requires the
    // handler to be registered even though it is never named as a string.
    class.addMethod("show_start_button", .auto);
}

pub fn unregister(r: *Registry) void {
    r.removeClass(Hud);
}

allocator: Allocator,
base: *CanvasLayer,

pub fn create(allocator: *Allocator) !*Hud {
    const self = try allocator.create(Hud);
    self.* = .{ .allocator = allocator.*, .base = CanvasLayer.init() };
    self.base.setInstance(Hud, self);
    return self;
}

pub fn recreate(allocator: *Allocator, obj: *Object) *Hud {
    const self = allocator.create(Hud) catch @panic("OOM");
    self.* = .{ .allocator = allocator.*, .base = @ptrCast(obj) };
    self.base.setInstance(Hud, self);
    return self;
}

pub fn destroy(self: *Hud, allocator: *Allocator) void {
    self.base.destroy();
    allocator.destroy(self);
}

pub fn showMessage(self: *Hud, text: String) void {
    if (nodeAs(Label, Node.upcast(self.base), "MessageLabel")) |label| {
        label.setText(text);
        CanvasItem.upcast(label).show();
    }
    if (nodeAs(Timer, Node.upcast(self.base), "MessageTimer")) |timer| {
        timer.start(.{});
    }
}

pub fn showGameOver(self: *Hud) void {
    var text: String = .fromLatin1("Game Over");
    defer text.deinit();
    self.showMessage(text);

    const tree = self.base.getTree() orelse return;
    var timer = tree.createTimer(2.0, .{}) orelse return;
    defer timer.deinit();

    // The Rust demo connects this by method name; gdzig's typed `connect` takes
    // the signal type and a closure, which needs no string and is checked.
    timer.get().connect(SceneTreeTimer.Timeout, .fromClosure(self, &showStartButton)) catch {};
}

pub fn showStartButton(self: *Hud) void {
    if (nodeAs(Label, Node.upcast(self.base), "MessageLabel")) |label| {
        var text: String = .fromLatin1("Dodge the\nCreeps!");
        defer text.deinit();
        label.setText(text);
        CanvasItem.upcast(label).show();
    }
    if (nodeAs(Button, Node.upcast(self.base), "StartButton")) |button| {
        CanvasItem.upcast(button).show();
    }
}

pub fn updateScore(self: *Hud, score: i64) void {
    const label = nodeAs(Label, Node.upcast(self.base), "ScoreLabel") orelse return;

    var buf: [32]u8 = undefined;
    const digits = std.fmt.bufPrint(&buf, "{d}", .{score}) catch return;

    var text: String = .fromLatin1(digits);
    defer text.deinit();
    label.setText(text);
}

pub fn onStartButtonPressed(self: *Hud) void {
    if (nodeAs(Button, Node.upcast(self.base), "StartButton")) |button| {
        CanvasItem.upcast(button).hide();
    }
    self.base.emit(StartGame, .{}) catch {};
}

pub fn onMessageTimerTimeout(self: *Hud) void {
    if (nodeAs(Label, Node.upcast(self.base), "MessageLabel")) |label| {
        CanvasItem.upcast(label).hide();
    }
}

const std = @import("std");
const Allocator = std.mem.Allocator;

const godot = @import("godot");
const Registry = godot.extension.Registry;
const Button = godot.class.Button;
const CanvasItem = godot.class.CanvasItem;
const CanvasLayer = godot.class.CanvasLayer;
const Label = godot.class.Label;
const Node = godot.class.Node;
const Object = godot.class.Object;
const SceneTreeTimer = godot.class.SceneTreeTimer;
const String = godot.builtin.String;
const StringName = godot.builtin.StringName;
const Timer = godot.class.Timer;

const nodeAs = @import("nodes.zig").nodeAs;
