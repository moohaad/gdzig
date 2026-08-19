const SpriteNode = @This();

allocator: Allocator,
base: *Control,
prng: std.Random.DefaultPrng = undefined,
rng: std.Random = undefined,
sprites: ArrayList(Sprite) = .empty,

const Sprite = struct {
    pos: Vector2,
    vel: Vector2,
    scale: Vector2,
    size: Vector2,
    gd_sprite: *Sprite2D,
};

pub fn create(allocator: *Allocator) !*SpriteNode {
    const self = try allocator.create(SpriteNode);
    self.* = .{
        .allocator = allocator.*,
        .base = Control.init(),
    };
    self.base.setInstance(SpriteNode, self);
    return self;
}

pub fn recreate(allocator: *Allocator, obj: *Object) *SpriteNode {
    const self = allocator.create(SpriteNode) catch @panic("OOM");
    self.* = .{
        .allocator = allocator.*,
        .base = @ptrCast(obj),
    };
    self.base.setInstance(SpriteNode, self);
    return self;
}

pub fn destroy(self: *SpriteNode, allocator: *Allocator) void {
    self.base.destroy();
    allocator.destroy(self);
}

pub fn randfRange(self: SpriteNode, comptime T: type, min: T, max: T) T {
    const u: T = self.rng.float(T);
    return u * (max - min) + min;
}

pub fn _ready(self: *SpriteNode) void {
    if (Engine.isEditorHint()) return;

    // `prng` must live in the node, not on the stack: `random()` hands out a
    // pointer to it that `randfRange` dereferences long after `_ready` returns.
    self.prng = .init(Time.getTicksUsec());
    self.rng = self.prng.random();

    // `godot.load` narrows to the type asked for, so there is no `String` to
    // build and no downcast to check. It also releases the resource if the file
    // turns out not to be a `Texture2d`, which `ResourceLoader.load` followed by
    // a hand-written downcast does not.
    var tex = godot.load(Texture2D, "res://textures/logo.png").?;
    defer tex.deinit();

    const sz = self.base.getParentAreaSize();

    for (0..10000) |_| {
        const s: f32 = self.randfRange(f32, 0.1, 0.2);
        var spr = Sprite{
            .pos = Vector2.initXY(self.randfRange(f32, 0, sz.x), self.randfRange(f32, 0, sz.y)),
            .vel = Vector2.initXY(self.randfRange(f32, -1000, 1000), self.randfRange(f32, -1000, 1000)),
            .scale = Vector2.initXY(s, s),
            .size = .zero,
            .gd_sprite = Sprite2D.init(),
        };
        spr.gd_sprite.setTexture(tex.get());
        spr.gd_sprite.setRotation(self.randfRange(f32, 0, std.math.pi));
        spr.gd_sprite.setScale(spr.scale);
        spr.size = spr.gd_sprite.getRect().size;
        self.base.addChild(spr.gd_sprite, .{});
        self.sprites.append(godot.engine_allocator, spr) catch |err| {
            std.log.err("Failed to append sprite: {}", .{err});
        };
    }
}

pub fn _exitTree(self: *SpriteNode) void {
    self.sprites.deinit(godot.engine_allocator);
}

pub fn _physicsProcess(self: *SpriteNode, delta: f64) void {
    const sz = self.base.getParentAreaSize(); //get_size();

    for (self.sprites.items) |*spr| {
        const pos = spr.pos.add(spr.vel.mulFloat(@floatCast(delta)));
        const spr_size = spr.size.mul(spr.scale);

        if (pos.x <= spr_size.x / 2) {
            spr.vel.x = @abs(spr.vel.x);
        } else if (pos.x >= sz.x - spr_size.x / 2) {
            spr.vel.x = -@abs(spr.vel.x);
        }
        if (pos.y <= spr_size.y / 2) {
            spr.vel.y = @abs(spr.vel.y);
        } else if (pos.y >= sz.y - spr_size.y / 2) {
            spr.vel.y = -@abs(spr.vel.y);
        }
        spr.pos = pos;
        spr.gd_sprite.setPosition(spr.pos);
    }
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const godot = @import("godot");

const Control = godot.class.Control;
const Engine = godot.class.Engine;
const Object = godot.class.Object;
const Time = godot.class.Time;
const Sprite2D = godot.class.Sprite2d;
const Resource = godot.class.Resource;
const Texture2D = godot.class.Texture2d;
const Vector2 = godot.builtin.Vector2;
const Rect2 = godot.builtin.Rect2;
const String = godot.builtin.String;
