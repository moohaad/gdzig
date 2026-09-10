const std = @import("std");
const godot = @import("godot");
const Game = @This();
const Vector2 = godot.builtin.Vector2;
const Color = godot.builtin.Color;
const Action = godot.input.Action;

allocator: std.mem.Allocator,
base: *godot.class.Node2d,
children: godot.Scene(@embedFile("Main.tscn")) = .{},
palette: ?godot.Gd(godot.class.Gradient) = null,
player: Vector2 = .{ .x = 320, .y = 240 },
star: Vector2 = .{ .x = 100, .y = 120 },
score: i64 = 0,
remaining: i64 = 20,
round_seconds: i64 = 20,
round_id: i64 = 0,
playing: bool = false,

pub const Scored = struct { total: i64 };
pub const signals = .{Scored};

pub fn _ready(self: *Game) void {
    self.palette = godot.load(godot.class.Gradient, "res://palette.tres");
    self.base.connect(Scored, self, &Game.onScore);
    self.resetRound();
}

pub fn resetRound(self: *Game) void {
    self.round_id += 1;
    self.player = .{ .x = 320, .y = 240 };
    self.star = .{ .x = 100, .y = 120 };
    self.score = 0;
    self.remaining = self.round_seconds;
    self.playing = true;
    self.updateHud();
    godot.coro.spawn(self.allocator, countdown, .{ self, self.round_id }) catch {
        self.playing = false;
        godot.print("Could not start countdown", .{});
    };
}

fn countdown(self: *Game, id: i64) void {
    while (self.playing and self.round_id == id and self.remaining > 0) {
        godot.coro.wait(self.base, 1.0, .{});
        if (self.round_id != id or !self.playing) return;
        self.remaining -= 1;
        if (self.remaining == 0) self.playing = false;
        self.updateHud();
    }
}

pub fn _physics_process(self: *Game, delta: f64) void {
    if (godot.input.isActionJustPressed(Action.restart)) self.resetRound();
    if (self.playing) {
        const direction = godot.input.getVector(Action.left, Action.right, Action.up, Action.down, .{});
        const step: f32 = @floatCast(delta * 230.0);
        self.player.x = std.math.clamp(self.player.x + direction.x * step, 16, 624);
        self.player.y = std.math.clamp(self.player.y + direction.y * step, 70, 464);
        const dx = self.player.x - self.star.x;
        const dy = self.player.y - self.star.y;
        if (dx * dx + dy * dy < 28 * 28) {
            self.score += 1;
            self.star = .{
                .x = @floatFromInt(70 + @mod(self.score * 173, 500)),
                .y = @floatFromInt(100 + @mod(self.score * 97, 330)),
            };
            if (self.score == 5) self.playing = false;
            self.base.emit(Scored, .{ .total = self.score }) catch {};
        }
    }
    self.base.queueRedraw();
}

pub fn onScore(self: *Game, total: i64) void {
    _ = total;
    self.updateHud();
}

fn updateHud(self: *Game) void {
    var buffer: [160]u8 = undefined;
    const status = if (self.score >= 5) "YOU WIN!" else if (!self.playing) "TIME UP!" else "Collect five stars";
    const text = std.fmt.bufPrint(&buffer, "{s}   {d}/5   {d}s\nWASD to move | R to restart", .{ status, self.score, self.remaining }) catch return;
    if (self.children.Hud.get()) |hud| hud.setText(text);
}

pub fn _draw(self: *Game) void {
    const player_color: Color = if (self.palette) |palette| palette.get().getColor(0) else .{ .r = 0.2, .g = 0.8, .b = 1, .a = 1 };
    self.base.drawCircle(self.player, 14, player_color, .{});
    if (self.playing) {
        self.base.drawCircle(self.star, 10, .{ .r = 1, .g = 0.8, .b = 0.2, .a = 1 }, .{});
    }
}

pub fn _exit_tree(self: *Game) void {
    self.playing = false;
    self.round_id += 1;
    if (self.palette) |*palette| palette.deinit();
    self.palette = null;
}
