//! An enemy that drifts across the screen and frees itself once it leaves.
//!
//! Ported from `demo-projects/dodge-the-creeps/rust/src/mob.rs`.

const Mob = @This();

pub fn register(r: *Registry) void {
    const class = r.createClass(Mob, r.allocator, .auto);
    // Wired in Mob.tscn from VisibleOnScreenNotifier2D.screen_exited, so the
    // name Godot looks up has to match the scene exactly.
    class.addMethod("on_visibility_screen_exited", .auto);
    class.addMethod("on_start_game", .auto);
}

pub fn unregister(r: *Registry) void {
    r.removeClass(Mob);
}

allocator: Allocator,
base: *RigidBody2d,
children: Scene(@embedFile("Mob.tscn")) = .{},
min_speed: f32 = 150.0,
max_speed: f32 = 250.0,

pub fn create(allocator: *Allocator) !*Mob {
    const self = try allocator.create(Mob);
    self.* = .{ .allocator = allocator.*, .base = RigidBody2d.init() };
    self.base.setInstance(Mob, self);
    return self;
}

pub fn recreate(allocator: *Allocator, obj: *Object) *Mob {
    const self = allocator.create(Mob) catch @panic("OOM");
    self.* = .{ .allocator = allocator.*, .base = @ptrCast(obj) };
    self.base.setInstance(Mob, self);
    return self;
}

pub fn destroy(self: *Mob, allocator: *Allocator) void {
    self.base.destroy();
    allocator.destroy(self);
}

pub fn _ready(self: *Mob) void {
    const sprite = self.children.AnimatedSprite2D.get() orelse return;
    sprite.play(.{});

    // `getSpriteFrames` returns an owning handle, so it needs releasing; the
    // names array is a builtin and needs its own deinit.
    var frames = sprite.getSpriteFrames() orelse return;
    defer frames.deinit();

    var names = frames.get().getAnimationNames();
    defer names.deinit();

    const count = names.size();
    if (count == 0) return;

    var name = names.get(random.randiRange(0, count - 1));
    defer name.deinit();

    var animation: StringName = .fromString(name);
    defer animation.deinit();
    sprite.setAnimation(animation);
}

pub fn onVisibilityScreenExited(self: *Mob) void {
    self.base.queueFree();
}

pub fn onStartGame(self: *Mob) void {
    self.base.queueFree();
}

const std = @import("std");
const Allocator = std.mem.Allocator;

const godot = @import("godot");
const Scene = godot.Scene;
const random = godot.random;
const Registry = godot.extension.Registry;
const Object = godot.class.Object;
const RigidBody2d = godot.class.RigidBody2d;
const StringName = godot.builtin.StringName;
