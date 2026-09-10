const godot = @import("godot");
const classes = .{@import("Game.zig")};
pub fn register(r: *godot.extension.Registry) void {
    r.registerAll(classes);
}
pub fn unregister(r: *godot.extension.Registry) void {
    r.unregisterAll(classes);
}
