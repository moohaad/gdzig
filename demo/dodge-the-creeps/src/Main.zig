//! Game loop: spawns mobs on a timer, tracks the score, ends on a hit.
//!
//! Ported from `demo-projects/dodge-the-creeps/rust/src/main_scene.rs`.
//!
//! godot-rust uses `OnReady<Gd<T>>` fields, which defer their lookup until the
//! node is in the tree. gdzig has no equivalent, so the children are resolved in
//! `_ready` and held as `Weak` handles -- they are owned by the scene tree, and
//! a plain pointer would say nothing about that.

const Main = @This();

pub fn register(r: *Registry) void {
    const class = r.createClass(Main, r.allocator, .auto);
    // Wired in Main.tscn from StartTimer.timeout.
    class.addMethod("on_start_timer_timeout", .auto);

    // The rest are connected from `_ready` with `Callable.fromClosure`, which
    // resolves the handler by scanning *public* decls and then checks Godot
    // knows the method. So unlike godot-rust -- where `connect_other` needs no
    // `#[func]` -- a closure-connected handler still has to be pub and
    // registered here.
    class.addMethod("game_over", .auto);
    class.addMethod("new_game", .auto);
    class.addMethod("on_score_timer_timeout", .auto);
    class.addMethod("on_mob_timer_timeout", .auto);
}

pub fn unregister(r: *Registry) void {
    r.removeClass(Main);
}

allocator: Allocator,
base: *Node,
score: i64 = 0,
mob_scene: ?Gd(PackedScene) = null,
player: ?Weak(Player) = null,
hud: ?Weak(Hud) = null,
music: ?Weak(AudioStreamPlayer) = null,
death_sound: ?Weak(AudioStreamPlayer) = null,

pub fn create(allocator: *Allocator) !*Main {
    const self = try allocator.create(Main);
    self.* = .{ .allocator = allocator.*, .base = Node.init() };
    self.base.setInstance(Main, self);
    return self;
}

pub fn recreate(allocator: *Allocator, obj: *Object) *Main {
    const self = allocator.create(Main) catch @panic("OOM");
    self.* = .{ .allocator = allocator.*, .base = @ptrCast(obj) };
    self.base.setInstance(Main, self);
    return self;
}

pub fn destroy(self: *Main, allocator: *Allocator) void {
    if (self.mob_scene) |*scene| scene.deinit();
    self.base.destroy();
    allocator.destroy(self);
}

pub fn _ready(self: *Main) void {
    var path: String = .fromLatin1("res://Mob.tscn");
    defer path.deinit();
    if (ResourceLoader.load(path, .{})) |resource| {
        var owned = resource;
        // `load` hands back an owned `Gd(Resource)`; narrow it to the scene type
        // and keep ownership, releasing the original handle either way.
        if (PackedScene.downcast(owned.get())) |scene| {
            self.mob_scene = Gd(PackedScene).borrow(scene);
        }
        owned.deinit();
    }

    if (nodeAs(Player, self.base, "Player")) |p| self.player = .init(p);
    if (nodeAs(Hud, self.base, "Hud")) |h| self.hud = .init(h);
    if (nodeAs(AudioStreamPlayer, self.base, "Music")) |m| self.music = .init(m);
    if (nodeAs(AudioStreamPlayer, self.base, "DeathSound")) |d| self.death_sound = .init(d);

    if (self.player) |p| if (p.get()) |live| {
        live.base.connect(Player.Hit, .fromClosure(self, &gameOver)) catch |e| std.log.err("connect Player.Hit: {s}", .{@errorName(e)});
    };
    if (self.hud) |h| if (h.get()) |live| {
        live.base.connect(Hud.StartGame, .fromClosure(self, &newGame)) catch |e| std.log.err("connect Hud.StartGame: {s}", .{@errorName(e)});
    };
    if (self.timer("ScoreTimer")) |t| {
        t.connect(Timer.Timeout, .fromClosure(self, &onScoreTimerTimeout)) catch |e| std.log.err("connect ScoreTimer: {s}", .{@errorName(e)});
    }
    if (self.timer("MobTimer")) |t| {
        t.connect(Timer.Timeout, .fromClosure(self, &onMobTimerTimeout)) catch |e| std.log.err("connect MobTimer: {s}", .{@errorName(e)});
    }
}

pub fn gameOver(self: *Main) void {
    if (self.timer("ScoreTimer")) |t| t.stop();
    if (self.timer("MobTimer")) |t| t.stop();

    if (self.hud) |h| if (h.get()) |live| live.showGameOver();
    if (self.music) |m| if (m.get()) |live| live.stop();
    if (self.death_sound) |d| if (d.get()) |live| live.play(.{});
}

pub fn newGame(self: *Main) void {
    self.score = 0;

    if (nodeAs(Marker2d, self.base, "StartPosition")) |start| {
        if (self.player) |p| if (p.get()) |live| live.start(start.getPosition());
    }
    if (self.timer("StartTimer")) |t| t.start(.{});

    if (self.hud) |h| if (h.get()) |live| {
        live.updateScore(self.score);
        var text: String = .fromLatin1("Get Ready");
        defer text.deinit();
        live.showMessage(text);
    };

    if (self.music) |m| if (m.get()) |live| live.play(.{});
}

pub fn onStartTimerTimeout(self: *Main) void {
    if (self.timer("MobTimer")) |t| t.start(.{});
    if (self.timer("ScoreTimer")) |t| t.start(.{});
}

pub fn onScoreTimerTimeout(self: *Main) void {
    self.score += 1;
    if (self.hud) |h| if (h.get()) |live| live.updateScore(self.score);
}

pub fn onMobTimerTimeout(self: *Main) void {
    const spawn = nodeAs(PathFollow2d, self.base, "MobPath/MobSpawnLocation") orelse return;
    var scene = self.mob_scene orelse return;

    const instance = scene.get().instantiate(.{}) orelse return;
    const mob = (Node.downcast(instance) orelse {
        instance.destroy();
        return;
    }).asInstance(Mob) orelse {
        instance.destroy();
        return;
    };

    spawn.setProgress(random.randfRange(0, std.math.maxInt(u32)));
    mob.base.setPosition(spawn.getPosition());

    const quarter_turn = std.math.pi / 2.0;
    const spread = std.math.pi / 4.0;
    const direction = spawn.getRotation() + quarter_turn +
        random.randfRange(-spread, spread);
    mob.base.setRotation(direction);

    self.base.addChild(Node.upcast(mob.base), .{});

    const speed = random.randfRange(mob.min_speed, mob.max_speed);
    const velocity: Vector2 = .{ .x = @floatCast(speed), .y = 0 };
    mob.base.setLinearVelocity(velocity.rotated(direction));
}

/// The three timers are looked up on demand rather than cached, matching the
/// Rust demo, which keeps them as functions "for demonstration purposes".
fn timer(self: *Main, comptime name: [:0]const u8) ?*Timer {
    return nodeAs(Timer, self.base, name);
}

const std = @import("std");
const Allocator = std.mem.Allocator;

const godot = @import("godot");
const random = godot.random;
const Gd = godot.Gd;
const Weak = godot.Weak;
const Registry = godot.extension.Registry;
const AudioStreamPlayer = godot.class.AudioStreamPlayer;
const Marker2d = godot.class.Marker2d;
const Node = godot.class.Node;
const Object = godot.class.Object;
const PackedScene = godot.class.PackedScene;
const PathFollow2d = godot.class.PathFollow2d;
const ResourceLoader = godot.class.ResourceLoader;
const String = godot.builtin.String;
const Timer = godot.class.Timer;
const Vector2 = godot.builtin.Vector2;

const Hud = @import("Hud.zig");
const Mob = @import("Mob.zig");
const Player = @import("Player.zig");
const nodeAs = @import("nodes.zig").nodeAs;
