//! GDExtension registration types and utilities.
//!
//! This module provides the types needed for registering classes, methods,
//! properties, and signals with Godot.

pub const InitializationLevel = enum(c_int) {
    core = 0,
    servers = 1,
    scene = 2,
    editor = 3,
};

pub const Registry = @import("extension/Registry.zig");

const class = @import("extension/class.zig");
pub const DestroyInstanceBinding = class.DestroyInstanceBinding;
pub const DispatchGuard = class.DispatchGuard;

const c = @import("gdextension");
