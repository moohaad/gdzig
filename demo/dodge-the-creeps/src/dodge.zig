//! Dodge the Creeps, ported from the godot-rust demo of the same name.
//!
//! The Godot project under `godot/` is the original, unchanged apart from
//! swapping `rust.gdextension` for `dodge.gdextension`. The scenes name their
//! root types `Main`, `Player`, `Mob` and `Hud`, so the classes registered here
//! have to match those names exactly.

pub fn register(r: *Registry) void {
    r.addModule(Main);
    r.addModule(Player);
    r.addModule(Mob);
    r.addModule(Hud);
}

pub fn unregister(r: *Registry) void {
    r.removeModule(Hud);
    r.removeModule(Mob);
    r.removeModule(Player);
    r.removeModule(Main);
}

const godot = @import("godot");
const Registry = godot.extension.Registry;

const Hud = @import("Hud.zig");
const Main = @import("Main.zig");
const Mob = @import("Mob.zig");
const Player = @import("Player.zig");
