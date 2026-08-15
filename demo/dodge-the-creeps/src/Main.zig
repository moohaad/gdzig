//! Game loop: spawns mobs on a timer, tracks the score, ends on a hit.
//!
//! Ported from `demo-projects/dodge-the-creeps/rust/src/main_scene.rs`.
//!
//! The four children are declared as `Child(T, path)` fields, gdzig's answer to
//! godot-rust's `OnReady<Gd<T>>`: the path sits next to the field and gdzig
//! resolves it just before `_ready`. Each holds a `Weak` handle underneath, so
//! `get` stays honest if the scene tree frees the node later.

const Main = @This();

pub fn register(r: *Registry) void {
    const class = r.createClass(Main, r.allocator, .auto);
    // Wired in Main.tscn from StartTimer.timeout.
    class.addMethod("on_start_timer_timeout", .auto);

    // The rest are connected from `_ready` with `connect(S, self, &method)`,
    // which matches the handler against *public* decls and then checks Godot
    // knows the method. So unlike godot-rust -- where `connect_other` needs no
    // `#[func]` -- a code-connected handler has to be pub and registered here.
    // Both mistakes now fail the build rather than at the connection.
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
/// Everything Main.tscn declares with a type of its own.
children: Scene(@embedFile("Main.tscn")) = .{},
/// `Player` and `Hud` are instanced sub-scenes, so the file gives them no type
/// -- it lives in the other scene. `Scene` can only offer those as `Node`;
/// `Child` names the type this code actually needs.
player: Child(Player, "Player") = .pending,
hud: Child(Hud, "Hud") = .pending,

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
    self.mob_scene = godot.load(PackedScene, "res://Mob.tscn");

    if (self.player.get()) |live| {
        live.base.connect(Player.Hit, self, &gameOver) catch |e| std.log.err("connect Player.Hit: {s}", .{@errorName(e)});
    }
    if (self.hud.get()) |live| {
        live.base.connect(Hud.StartGame, self, &newGame) catch |e| std.log.err("connect Hud.StartGame: {s}", .{@errorName(e)});
    }
    if (self.children.ScoreTimer.get()) |t| {
        t.connect(Timer.Timeout, self, &onScoreTimerTimeout) catch |e| std.log.err("connect ScoreTimer: {s}", .{@errorName(e)});
    }
    if (self.children.MobTimer.get()) |t| {
        t.connect(Timer.Timeout, self, &onMobTimerTimeout) catch |e| std.log.err("connect MobTimer: {s}", .{@errorName(e)});
    }
}

pub fn gameOver(self: *Main) void {
    if (self.children.ScoreTimer.get()) |t| t.stop();
    if (self.children.MobTimer.get()) |t| t.stop();

    if (self.hud.get()) |live| live.showGameOver();
    if (self.children.Music.get()) |live| live.stop();
    if (self.children.DeathSound.get()) |live| live.play(.{});
}

pub fn newGame(self: *Main) void {
    self.score = 0;

    if (self.children.StartPosition.get()) |start| {
        if (self.player.get()) |live| live.start(start.getPosition());
    }
    if (self.children.StartTimer.get()) |t| t.start(.{});

    if (self.hud.get()) |live| {
        live.updateScore(self.score);
        var text: String = .fromLatin1("Get Ready");
        defer text.deinit();
        live.showMessage(text);
    }

    if (self.children.Music.get()) |live| live.play(.{});
}

pub fn onStartTimerTimeout(self: *Main) void {
    if (self.children.MobTimer.get()) |t| t.start(.{});
    if (self.children.ScoreTimer.get()) |t| t.start(.{});
}

pub fn onScoreTimerTimeout(self: *Main) void {
    self.score += 1;
    if (self.hud.get()) |live| live.updateScore(self.score);
}

pub fn onMobTimerTimeout(self: *Main) void {
    const spawn = self.children.MobSpawnLocation.get() orelse return;
    var scene = self.mob_scene orelse return;

    const mob = scene.get().instantiateAs(Mob) orelse return;

    spawn.setProgress(random.randfRange(0, std.math.maxInt(u32)));
    mob.base.setPosition(spawn.getPosition());

    const quarter_turn = std.math.pi / 2.0;
    const spread = std.math.pi / 4.0;
    const direction = spawn.getRotation() + quarter_turn +
        random.randfRange(-spread, spread);
    mob.base.setRotation(direction);

    self.base.addChild(mob.base, .{});

    const speed = random.randfRange(mob.min_speed, mob.max_speed);
    const velocity: Vector2 = .{ .x = @floatCast(speed), .y = 0 };
    mob.base.setLinearVelocity(velocity.rotated(direction));
}

const std = @import("std");
const Allocator = std.mem.Allocator;

const godot = @import("godot");
const Scene = godot.Scene;
const random = godot.random;
const Gd = godot.Gd;
const Child = godot.Child;
const Registry = godot.extension.Registry;
const Node = godot.class.Node;
const Object = godot.class.Object;
const PackedScene = godot.class.PackedScene;
const String = godot.builtin.String;
const Timer = godot.class.Timer;
const Vector2 = godot.builtin.Vector2;

const Hud = @import("Hud.zig");
const Mob = @import("Mob.zig");
const Player = @import("Player.zig");