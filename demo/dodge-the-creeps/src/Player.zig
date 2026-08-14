//! The player: eight-way movement, clamped to the screen, hides on contact.
//!
//! Ported from `demo-projects/dodge-the-creeps/rust/src/player.rs`.

const Player = @This();

/// Emitted when a mob touches the player. `Main` listens for it.
pub const Hit = struct {};

pub fn register(r: *Registry) void {
    const class = r.createClass(Player, r.allocator, .auto);
    class.addSignal(Hit);

    // `on_player_body_entered` is wired in Player.tscn (body_entered -> self),
    // so unlike the Rust demo there is nothing to connect in `_ready`.
    class.addMethod("on_player_body_entered", .auto);
    class.addMethod("start", .auto);
}

pub fn unregister(r: *Registry) void {
    r.removeClass(Player);
}

allocator: Allocator,
base: *Area2d,
speed: f32 = 400.0,
screen_size: Vector2 = .{ .x = 0, .y = 0 },

pub fn create(allocator: *Allocator) !*Player {
    const self = try allocator.create(Player);
    self.* = .{ .allocator = allocator.*, .base = Area2d.init() };
    self.base.setInstance(Player, self);
    return self;
}

pub fn recreate(allocator: *Allocator, obj: *Object) *Player {
    const self = allocator.create(Player) catch @panic("OOM");
    self.* = .{ .allocator = allocator.*, .base = @ptrCast(obj) };
    self.base.setInstance(Player, self);
    return self;
}

pub fn destroy(self: *Player, allocator: *Allocator) void {
    self.base.destroy();
    allocator.destroy(self);
}

pub fn _ready(self: *Player) void {
    self.screen_size = self.base.getViewportRect().size;
    self.base.hide();
}

pub fn _process(self: *Player, delta: f64) void {
    const sprite = nodeAs(AnimatedSprite2d, self.base, "AnimatedSprite2D") orelse return;

    var velocity: Vector2 = .{ .x = 0, .y = 0 };
    if (pressed("move_right")) velocity.x += 1;
    if (pressed("move_left")) velocity.x -= 1;
    if (pressed("move_down")) velocity.y += 1;
    if (pressed("move_up")) velocity.y -= 1;

    if (velocity.length() > 0) {
        const normalized = velocity.normalized();
        velocity = .{ .x = normalized.x * self.speed, .y = normalized.y * self.speed };

        // `fromComptimeLatin1` returns a cached *static* StringName. It must
        // not be deinited -- doing so drops a shared refcount and Godot reports
        // "Unreferenced static string to 0" once per frame.
        const animation: StringName = if (velocity.x != 0) blk: {
            sprite.setFlipV(false);
            sprite.setFlipH(velocity.x < 0);
            break :blk .fromComptimeLatin1("right");
        } else blk: {
            sprite.setFlipV(velocity.y > 0);
            break :blk .fromComptimeLatin1("up");
        };
        sprite.play(.{ .name = animation });
    } else {
        sprite.stop();
    }

    const d: f32 = @floatCast(delta);
    const at = self.base.getGlobalPosition();
    self.base.setGlobalPosition(.{
        .x = std.math.clamp(at.x + velocity.x * d, 0, self.screen_size.x),
        .y = std.math.clamp(at.y + velocity.y * d, 0, self.screen_size.y),
    });
}

pub fn onPlayerBodyEntered(self: *Player, _: *Node2d) void {
    self.base.hide();
    self.base.emit(Hit, .{}) catch {};

    const shape = nodeAs(CollisionShape2d, self.base, "CollisionShape2D") orelse return;

    // Deferred: the body is mid-collision-response, and Godot refuses to change
    // shape state during physics resolution.
    const property: StringName = .fromComptimeLatin1("disabled");
    var value: Variant = .init(bool, true);
    defer value.deinit();
    shape.setDeferred(property, value);
}

pub fn start(self: *Player, pos: Vector2) void {
    self.base.setGlobalPosition(pos);
    self.base.show();

    if (nodeAs(CollisionShape2d, self.base, "CollisionShape2D")) |shape| {
        shape.setDisabled(false);
    }
}

fn pressed(comptime action: [:0]const u8) bool {
    return Input.isActionPressed(.fromComptimeLatin1(action), .{});
}

const std = @import("std");
const Allocator = std.mem.Allocator;

const godot = @import("godot");
const Registry = godot.extension.Registry;
const AnimatedSprite2d = godot.class.AnimatedSprite2d;
const Area2d = godot.class.Area2d;
const CollisionShape2d = godot.class.CollisionShape2d;
const Input = godot.class.Input;
const Node2d = godot.class.Node2d;
const Object = godot.class.Object;
const StringName = godot.builtin.StringName;
const Variant = godot.builtin.Variant;
const Vector2 = godot.builtin.Vector2;

const nodeAs = @import("nodes.zig").nodeAs;
